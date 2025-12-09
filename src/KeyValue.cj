// KeyValue.cj — SwissTable (ctrl pointer version) + shards + seqlock
// + strict production key semantics (no mode switch)
// + old-value returns + stdlib-like facade
// + O(N) serialize/deserialize
//
// 原始 SwissTable（ctrl 指针版本）+ 分片 + seqlock
// + 生产环境严格 key 语义（无模式开关）
// + 返回旧值 + 标准库风格 facade
// + O(N) 序列化/反序列化
package techarena

import std.sync.*
// 如果你的环境需要显式导入这些符号，再取消注释：
// import std.collection.*
// import std.base.*

/* ---------------- FFI / C interop ---------------- */
foreign func malloc(size: Int64): CPointer<UInt8>
foreign func free(ptr: CPointer<UInt8>): Unit

/* ---------------- constants ---------------- */
private let GROUP_WIDTH: Int32 = 16i32
private let K_EMPTY:    UInt8  = 0x80u8
private let K_DELETED:  UInt8  = 0xfeu8
private let K_SENTINEL: UInt8  = 0xffu8
private let PRE_RESERVE_NKEYS: Int32 = 1000000i32

@OverflowWrapping
private func H1_(h: UInt64): UInt64 { return (h >> 7u64) }
@OverflowWrapping
private func H2_(h: UInt64): UInt8  { return UInt8(h & 0x7fu64) }

// lightweight hash (can be swapped)
@OverflowWrapping
private func hash64_(s: String): UInt64 { return UInt64(s.hashCode()) }

// trailing-zero index for UInt32 (x != 0), else -1
private func tz_u32_(x: UInt32): Int32 {
    if (x == 0u32) { return -1 }
    var i: Int32 = 0
    var v: UInt32 = x
    while ((v & 1u32) == 0u32) { v = v >> 1u32; i = i + 1 }
    return i
}

/* ---------------- slot ---------------- */
private struct Slot {
    public var key:   String
    public var value: Int64
    public var h:     UInt64
    public init() {
        this.key = ""
        this.value = 0i64
        this.h = 0u64
    }
}

/* =========================================================
 * SwissRaw — low-level Swiss table (String -> Int64)
 *  - ctrl is pointer-managed (cap + GROUP_WIDTH + 1)
 *  - strict production key semantics:
 *      compare h -> length -> string
 *  - put/erase return old value as Option
 * ========================================================= */
private class SwissRaw {
    public var groups:    Int32
    public var cap:       Int32
    public var mask:      Int32
    public var size:      Int32
    public var max_load:  Int32
    public var del_count: Int32
    public var rehashing: Bool

    public var ctrl_ptr: CPointer<UInt8>
    public var ctrl_n:   Int32

    public var slots: Array<Slot>

    public init(init_groups: Int32) {
        let g: Int32 = if (init_groups < 1i32) { 1i32 } else { init_groups }
        this.groups    = SwissRaw.pow2ceil_(g)
        this.cap       = this.groups * GROUP_WIDTH
        this.mask      = this.cap - 1i32
        this.size      = 0i32
        this.max_load  = (this.cap * 7i32) / 8i32
        this.del_count = 0
        this.rehashing = false

        let n_ctrl: Int32 = this.cap + GROUP_WIDTH + 1i32
        this.ctrl_n   = n_ctrl
        this.ctrl_ptr = unsafe { malloc(Int64(n_ctrl)) }
        SwissRaw.init_ctrl_static_(this.ctrl_ptr, this.cap)

        let n_slots: Int32 = this.cap
        this.slots = Array<Slot>(Int64(n_slots), { _ => Slot() })
    }

    /* ---------- broadword helpers ---------- */
    @OverflowWrapping
    private static unsafe func load8_(p: CPointer<UInt8>): UInt64 {
        var v: UInt64 = 0u64
        v = v |  UInt64(unsafe { (p + 0i64).read() })
        v = v | (UInt64(unsafe { (p + 1i64).read() }) << 8u64)
        v = v | (UInt64(unsafe { (p + 2i64).read() }) << 16u64)
        v = v | (UInt64(unsafe { (p + 3i64).read() }) << 24u64)
        v = v | (UInt64(unsafe { (p + 4i64).read() }) << 32u64)
        v = v | (UInt64(unsafe { (p + 5i64).read() }) << 40u64)
        v = v | (UInt64(unsafe { (p + 6i64).read() }) << 48u64)
        v = v | (UInt64(unsafe { (p + 7i64).read() }) << 56u64)
        return v
    }

    @OverflowWrapping
    private static func bytesEqMask8_(v: UInt64, target: UInt8): UInt32 {
        let t: UInt64 = UInt64(target)
        var patt: UInt64 = t
        patt = patt | (patt << 8u64)
        patt = patt | (patt << 16u64)
        patt = patt | (patt << 32u64)

        let x: UInt64 = v ^ patt

        let ones:     UInt64 = 0x0101010101010101u64
        let highBits: UInt64 = 0x8080808080808080u64
        let m: UInt64 = (x - ones) & (!x) & highBits

        var mask: UInt32 = 0u32
        var i: Int32 = 0
        while (i < 8) {
            let shift: UInt64 = UInt64(i * 8 + 7)
            let bit:   UInt64 = (m >> shift) & 1u64
            mask = mask | (UInt32(bit) << UInt32(i))
            i = i + 1
        }
        return mask
    }

    /* ---------- ctrl pointer helpers ---------- */
    private func ctrl_read_(i: Int32): UInt8 {
        return unsafe { (ctrl_ptr + Int64(i)).read() }
    }

    private func ctrl_write_clone_(i: Int32, v: UInt8): Unit {
        unsafe { (ctrl_ptr + Int64(i)).write(v) }
        if (i < GROUP_WIDTH) {
            unsafe { (ctrl_ptr + Int64(cap + 1 + i)).write(v) }
        }
    }

    private func ctrl_base_(base: Int32): CPointer<UInt8> {
        return unsafe { ctrl_ptr + Int64(base) }
    }

    public func ctrlAt(i: Int32): UInt8 {
        return unsafe { (ctrl_ptr + Int64(i)).read() }
    }

    /* ---------- capacity + destroy ---------- */
    public func ensure_capacity_groups_(new_groups: Int32): Unit {
        let g2 = SwissRaw.pow2ceil_(new_groups)
        if (g2 <= groups) { return }
        rehash_(g2)
    }

    public func destroy_(): Unit {
        if (ctrl_n > 0 && ctrl_ptr.isNotNull()) {
            unsafe { free(ctrl_ptr) }
        }
        ctrl_n = 0
        cap = 0; mask = 0; groups = 1; size = 0; max_load = 0; del_count = 0
        slots = Array<Slot>()
    }

    public func countLive_(): Int32 { return this.size }

    /* ---------- strict read probe ---------- */
    public static func ro_get_by_hash_(tab: SwissRaw, h: UInt64, k: String): Option<Int64> {
        let h1: UInt64 = H1_(h)
        let h2: UInt8  = H2_(h)

        var base: Int32 = Int32(h1 & UInt64(tab.groups - 1)) * GROUP_WIDTH
        let mask: Int32 = tab.mask
        var step: Int32 = 0

        while (true) {
            var i: Int32 = 0
            while (i < GROUP_WIDTH) {
                let c: UInt8 = tab.ctrl_read_(base + i)
                if (c == h2) {
                    let pos: Int32 = (base + i) & mask
                    let s = tab.slots[Int64(pos)]
                    if (s.h == h) {
                        if (s.key.size == k.size && s.key == k) {
                            return Some(s.value)
                        }
                    }
                }
                if (c == K_EMPTY) { return None }
                i = i + 1
            }
            step = step + GROUP_WIDTH
            base = (base + step) & mask
        }
        return None
    }

    public func get(k: String): Option<Int64> {
        let h: UInt64 = hash64_(k)
        return SwissRaw.ro_get_by_hash_(this, h, k)
    }

    /* ---------- match 16 ctrl bytes ---------- */
    private func match16_masks_ptr_(base: Int32, h2: UInt8): (UInt32, UInt32, UInt32) {
        let p = ctrl_base_(base)

        let v0: UInt64 = unsafe { SwissRaw.load8_(p) }
        let v1: UInt64 = unsafe { SwissRaw.load8_(p + 8i64) }

        let m0_h2: UInt32 = SwissRaw.bytesEqMask8_(v0, h2)
        let m0_e:  UInt32 = SwissRaw.bytesEqMask8_(v0, K_EMPTY)
        let m0_d:  UInt32 = SwissRaw.bytesEqMask8_(v0, K_DELETED)

        let m1_h2: UInt32 = SwissRaw.bytesEqMask8_(v1, h2)
        let m1_e:  UInt32 = SwissRaw.bytesEqMask8_(v1, K_EMPTY)
        let m1_d:  UInt32 = SwissRaw.bytesEqMask8_(v1, K_DELETED)

        let mh2: UInt32 = m0_h2 | (m1_h2 << 8u32)
        let me:  UInt32 = m0_e  | (m1_e  << 8u32)
        let md:  UInt32 = m0_d  | (m1_d  << 8u32)

        return (mh2, me, md)
    }

    /* ---------- public put APIs (return old) ---------- */
    public func putPrehashedNoRehash_(h: UInt64, k: String, v: Int64): Option<Int64> {
        return putKnown_(h, k, v)
    }

    public func putPrehashed_(h: UInt64, k: String, v: Int64): Option<Int64> {
        if (del_count > (cap >> 3) && (size + del_count) >= max_load) {
            rehash_(groups)
        } else if (size >= max_load) {
            rehash_(groups << 1)
        }
        return putKnown_(h, k, v)
    }

    public func put(k: String, v: Int64): Option<Int64> {
        if (del_count > (cap >> 3) && (size + del_count) >= max_load) {
            rehash_(groups)
        } else if (size >= max_load) {
            rehash_(groups << 1)
        }
        let h: UInt64 = hash64_(k)
        return putKnown_(h, k, v)
    }

    /* ---------- core insert/update (strict key) ---------- */
    private func putKnown_(h: UInt64, k: String, v: Int64): Option<Int64> {
        let h2: UInt8  = H2_(h)
        var base: Int32 = Int32(H1_(h) & UInt64(groups - 1)) * GROUP_WIDTH
        let mask_: Int32 = mask
        var first_del: Int32 = -1
        var step: Int32 = 0

        while (true) {
            let (mh2, me, md) = match16_masks_ptr_(base, h2)

            var m: UInt32 = mh2
            while (m != 0u32) {
                let bit: Int32 = tz_u32_(m)
                let pos: Int32 = (base + bit) & mask_
                let s0 = slots[Int64(pos)]

                if (s0.h == h) {
                    if (s0.key.size == k.size && s0.key == k) {
                        let oldv = s0.value
                        var s = s0
                        s.value = v
                        slots[Int64(pos)] = s
                        return Some(oldv)
                    }
                }

                m = m & (m - 1u32)
            }

            if (first_del < 0 && md != 0u32) {
                first_del = (base + tz_u32_(md)) & mask_
            }

            if (me != 0u32) {
                if (first_del >= 0) {
                    insert_at_(first_del, h, h2, k, v, ctrl_read_(first_del))
                } else {
                    let ins: Int32 = (base + tz_u32_(me)) & mask_
                    insert_at_(ins, h, h2, k, v, K_EMPTY)
                }
                return None
            }

            step = step + GROUP_WIDTH
            base = (base + step) & mask_
        }
        return None
    }

    /* ---------- erase (strict key, return old) ---------- */
    public func erasePrehashed_(h: UInt64, k: String): Option<Int64> {
        let h1: UInt64 = H1_(h)
        let h2: UInt8  = H2_(h)
        var base: Int32 = Int32(h1 & UInt64(groups - 1)) * GROUP_WIDTH
        let mask_: Int32 = this.mask
        var step: Int32 = 0

        while (true) {
            let (mh2, me, _) = match16_masks_ptr_(base, h2)
            var m: UInt32 = mh2

            while (m != 0u32) {
                let bit: Int32 = tz_u32_(m)
                let pos: Int32 = (base + bit) & mask_
                let s = slots[Int64(pos)]

                if (s.h == h) {
                    if (s.key.size == k.size && s.key == k) {
                        let oldv = s.value
                        set_ctrl_(pos, K_DELETED)
                        var sclr = slots[Int64(pos)]
                        sclr.key = ""
                        slots[Int64(pos)] = sclr
                        size = size - 1
                        del_count = del_count + 1
                        return Some(oldv)
                    }
                }

                m = m & (m - 1u32)
            }

            if (me != 0u32) { return None }
            step = step + GROUP_WIDTH
            base = (base + step) & mask_
        }
        return None
    }

    public func erase(k: String): Option<Int64> {
        let h: UInt64 = hash64_(k)
        return erasePrehashed_(h, k)
    }

    /* ---------- snapshot ---------- */
    public func snap_(): (CPointer<UInt8>, Array<Slot>, Int32, Int32, Int32) {
        return (ctrl_ptr, slots, cap, mask, groups)
    }

    /* ---------- internals ---------- */
    private static func pow2ceil_(x: Int32): Int32 {
        var v: Int32 = if (x < 1) { 1 } else { x }
        v = v - 1
        v = v | (v >> 1)
        v = v | (v >> 2)
        v = v | (v >> 4)
        v = v | (v >> 8)
        v = v | (v >> 16)
        return v + 1
    }

    private static func init_ctrl_static_(p: CPointer<UInt8>, cap: Int32): Unit {
        let n_ctrl: Int32 = cap + GROUP_WIDTH + 1
        var i: Int32 = 0
        while (i < n_ctrl) { unsafe { (p + Int64(i)).write(K_EMPTY) }; i = i + 1 }
        unsafe { (p + Int64(cap)).write(K_SENTINEL) }

        var j: Int32 = 0
        while (j < GROUP_WIDTH) {
            let v: UInt8 = unsafe { (p + Int64(j)).read() }
            unsafe { (p + Int64(cap + 1 + j)).write(v) }
            j = j + 1
        }
    }

    private func set_ctrl_(pos: Int32, c: UInt8): Unit { ctrl_write_clone_(pos, c) }

    // NOTE: removed the "insert-time rehash trigger" to reduce constant overhead.
    private func insert_at_(pos: Int32, h: UInt64, h2: UInt8, k: String, v: Int64, prev_c: UInt8): Unit {
        var s = slots[Int64(pos)]
        s.key   = k
        s.value = v
        s.h     = h
        slots[Int64(pos)] = s

        set_ctrl_(pos, h2)
        size = size + 1

        if (prev_c == K_DELETED) { del_count = del_count - 1 }
    }

    private func rehash_(new_groups: Int32): Unit {
        rehashing = true
        del_count = 0

        let old_ctrl_ptr: CPointer<UInt8> = ctrl_ptr
        let old_slots:    Array<Slot>     = slots
        let old_cap:      Int32           = cap

        groups   = SwissRaw.pow2ceil_(new_groups)
        cap      = groups * GROUP_WIDTH
        mask     = cap - 1
        max_load = (cap * 7) / 8

        let n_ctrl: Int32  = cap + GROUP_WIDTH + 1
        ctrl_n   = n_ctrl
        ctrl_ptr = unsafe { malloc(Int64(n_ctrl)) }
        SwissRaw.init_ctrl_static_(ctrl_ptr, cap)

        let n_slots: Int32 = cap
        this.slots = Array<Slot>(Int64(n_slots), { _ => Slot() })

        size = 0

        var i: Int32 = 0
        while (i < old_cap) {
            let c: UInt8 = unsafe { (old_ctrl_ptr + Int64(i)).read() }
            if (c < 0x80u8) {
                let s = old_slots[Int64(i)]
                _ = putKnown_(s.h, s.key, s.value)
            }
            i = i + 1
        }

        unsafe { free(old_ctrl_ptr) }
        rehashing = false
    }
}

/* =========================================================
 * Sharded wrapper — seqlock for reads, mutex for writes
 * ========================================================= */
private let DEFAULT_SHARDS: Int32 = 16i32

private struct Shard {
    public var ver:  AtomicUInt64
    public var w:    ReentrantMutex
    public var tab:  SwissRaw

    public init(cap_groups: Int32) {
        this.ver = AtomicUInt64(0u64)
        this.w   = ReentrantMutex()
        this.tab = SwissRaw(cap_groups)
    }
}

/* =========================================================
 * KeyValue — stdlib-like facade (strict semantics)
 *   - add/remove/replace return old value where appropriate
 *   - operator[] throws on missing key
 * ========================================================= */
public class KeyValue {
    private var shards: Array<Shard>
    var shard_mask: Int32

    public init() {
        let n: Int32 = DEFAULT_SHARDS
        shards = Array<Shard>(Int64(n), { _ => Shard(512i32) })
        shard_mask = n - 1
        this.reserve(PRE_RESERVE_NKEYS)
    }

    private init(_unreserved: Bool) {
        let n: Int32 = DEFAULT_SHARDS
        shards = Array<Shard>(Int64(n), { _ => Shard(1i32) })
        shard_mask = n - 1
    }

    public static func newUnreserved_(): KeyValue {
        return KeyValue(true)
    }

    /* ---------- reserve ---------- */
    public func reserve(total: Int32): Unit {
        let nshards: Int32 = Int32(shards.size)
        let per = KeyValue.ceilDivI32_(total, nshards)
        let per_pad: Int32 = per + ((per + 5) / 6)
        let g = KeyValue.groupsForCount_(per_pad)

        var i: Int32 = 0
        while (i < nshards) {
            shards[Int64(i)].tab.ensure_capacity_groups_(g)
            i = i + 1
        }
    }

    private func pick_(h: UInt64): Int32 { return Int32(h & UInt64(shard_mask)) }

    /* ---------- small helpers ---------- */
    @OverflowWrapping
    private static func ceilDivI32_(x: Int32, y: Int32): Int32 { return (x + y - 1) / y }

    private static func pow2ceilI32_(x: Int32): Int32 {
        var v: Int32 = if (x < 1) { 1 } else { x }
        v = v - 1
        v = v | (v >> 1)
        v = v | (v >> 2)
        v = v | (v >> 4)
        v = v | (v >> 8)
        v = v | (v >> 16)
        return v + 1
    }

    private static func groupsForCount_(cnt: Int32): Int32 {
        if (cnt <= 0) { return 1 }
        let needCap    = ceilDivI32_(cnt * 8, 7)
        let needGroups = ceilDivI32_(needCap, GROUP_WIDTH)
        return pow2ceilI32_(needGroups)
    }

    private static func parseI64_(s: String, start: Int64, end: Int64): Int64 {
        var p: Int64 = start
        var v: Int64 = 0
        var neg: Bool = false

        if (p < end && s[p] == UInt8(45)) {
            neg = true
            p = p + 1
        }

        while (p < end) {
            let c: UInt8 = s[p]
            v = v * 10 + Int64(c - 48u8)
            p = p + 1
        }

        return if (neg) { -v } else { v }
    }

    /* ---------- stdlib-like queries ---------- */
    public prop size: Int64 {
        get() {
            let nshards: Int32 = Int32(shards.size)
            var total: Int64 = 0
            var i: Int32 = 0
            while (i < nshards) {
                total = total + Int64(shards[Int64(i)].tab.countLive_())
                i = i + 1
            }
            return total
        }
    }

    public func isEmpty(): Bool { return this.size == 0 }
    public func contains(key: String): Bool {
        return match (this.get(key)) { case None => false; case _ => true }
    }

    /* ---------- seqlock read ---------- */
    public func get(k: String): Option<Int64> {
        let h  = hash64_(k)
        let si = pick_(h)
        var spins: Int32 = 0

        while (true) {
            let v1: UInt64 = shards[Int64(si)].ver.load()
            if ((v1 & 1u64) != 0u64) { continue }

            let res = SwissRaw.ro_get_by_hash_(shards[Int64(si)].tab, h, k)

            let v2: UInt64 = shards[Int64(si)].ver.load()
            if (v1 == v2 && (v2 & 1u64) == 0u64) { return res }

            spins = spins + 1
            if (spins > 32) {
                shards[Int64(si)].w.lock()
                let out = shards[Int64(si)].tab.get(k)
                shards[Int64(si)].w.unlock()
                return out
            }
        }
        return None
    }

    /* ---------- stdlib-like write APIs ---------- */
    public func add(key: String, value: Int64): Option<Int64> {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let old = shards[Int64(si)].tab.putPrehashed_(h, key, value)

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return old
    }

    // compatibility name
    public func put(k: String, v: Int64): Unit {
        _ = this.add(k, v)
    }

    public func addIfAbsent(key: String, value: Int64): Option<Int64> {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let old = SwissRaw.ro_get_by_hash_(shards[Int64(si)].tab, h, key)
        match (old) {
            case Some(v0) =>
                shards[Int64(si)].ver.fetchAdd(1u64)
                shards[Int64(si)].w.unlock()
                return Some(v0)
            case None =>
                _ = shards[Int64(si)].tab.putPrehashed_(h, key, value)
        }

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return None
    }

    public func remove(key: String): Option<Int64> {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let old = shards[Int64(si)].tab.erasePrehashed_(h, key)

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return old
    }

    public func remove(key: String, predicate: (Int64) -> Bool): Option<Int64> {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let old = shards[Int64(si)].tab.get(key)
        match (old) {
            case Some(v0) =>
                if (predicate(v0)) {
                    _ = shards[Int64(si)].tab.erasePrehashed_(h, key)
                } else {
                    shards[Int64(si)].ver.fetchAdd(1u64)
                    shards[Int64(si)].w.unlock()
                    return None
                }
            case None => ()
        }

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return old
    }

    // compatibility: old Bool erase
    public func erase(k: String): Bool {
        return match (this.remove(k)) { case Some(_) => true; case None => false }
    }

    public func replace(key: String, value: Int64): Option<Int64> {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let old = shards[Int64(si)].tab.get(key)
        match (old) {
            case Some(_) => _ = shards[Int64(si)].tab.putPrehashed_(h, key, value)
            case None => ()
        }

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return old
    }

    public func replace(key: String, oldValue: Int64, newValue: Int64): Bool {
        let h:  UInt64 = hash64_(key)
        let si: Int32  = pick_(h)

        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)

        let cur = shards[Int64(si)].tab.get(key)
        let ok =
            match (cur) {
                case Some(v0) =>
                    if (v0 == oldValue) {
                        _ = shards[Int64(si)].tab.putPrehashed_(h, key, newValue)
                        true
                    } else { false }
                case None => false
            }

        shards[Int64(si)].ver.fetchAdd(1u64)
        shards[Int64(si)].w.unlock()
        return ok
    }

    /* ---------- keys / values ---------- */
    public func getKeys(): Array<String> {
        let nshards: Int32 = Int32(shards.size)
        var total: Int32 = 0
        var si: Int32 = 0
        while (si < nshards) {
            total = total + shards[Int64(si)].tab.countLive_()
            si = si + 1
        }

        var out = Array<String>(Int64(total), { _ => "" })

        var w: Int32 = 0
        si = 0
        while (si < nshards) {
            let tab  = this.shards[Int64(si)].tab
            let cap  = tab.cap
            let ctrl = tab.ctrl_ptr
            var j: Int32 = 0
            while (j < cap) {
                let c: UInt8 = unsafe { (ctrl + Int64(j)).read() }
                if (c < 0x80u8) {
                    out[Int64(w)] = tab.slots[Int64(j)].key
                    w = w + 1
                }
                j = j + 1
            }
            si = si + 1
        }

        if (w == total) { return out }
        var out2 = Array<String>(Int64(w), { _ => "" })
        var i: Int32 = 0
        while (i < w) { out2[Int64(i)] = out[Int64(i)]; i = i + 1 }
        return out2
    }

    public func keys(): Array<String> { return this.getKeys() }

    public func values(): Array<Int64> {
        let totalI64: Int64 = this.size
        if (totalI64 <= 0i64) { return Array<Int64>() }
        let total: Int32 = Int32(totalI64)

        var out = Array<Int64>(Int64(total), { _ => 0i64 })
        var w: Int32 = 0

        let nshards: Int32 = Int32(shards.size)
        var si: Int32 = 0
        while (si < nshards) {
            let tab  = this.shards[Int64(si)].tab
            let cap  = tab.cap
            let ctrl = tab.ctrl_ptr
            var j: Int32 = 0
            while (j < cap) {
                let c: UInt8 = unsafe { (ctrl + Int64(j)).read() }
                if (c < 0x80u8) {
                    if (w < total) {
                        out[Int64(w)] = tab.slots[Int64(j)].value
                        w = w + 1
                    } else {
                        break
                    }
                }
                j = j + 1
            }
            si = si + 1
        }

        if (w == total) { return out }
        var out2 = Array<Int64>(Int64(w), { _ => 0i64 })
        var i: Int32 = 0
        while (i < w) { out2[Int64(i)] = out[Int64(i)]; i = i + 1 }
        return out2
    }

    public func iterator(): Iterator<(String, Int64)> {
        let ks = this.getKeys()
        return KeyValueIterator(this, ks)
    }

    /* ---------- clear ---------- */
    public func clear(): Unit {
        let nshards: Int32 = Int32(shards.size)
        var i: Int32 = 0

        while (i < nshards) {
            var sh = shards[Int64(i)]
            let g = sh.tab.groups

            sh.w.lock()
            sh.ver.fetchAdd(1u64)

            sh.tab.destroy_()
            sh.tab = SwissRaw(g)

            sh.ver.fetchAdd(1u64)
            sh.w.unlock()

            shards[Int64(i)] = sh
            i = i + 1
        }
    }

    /* ---------- operator [] ---------- */
    public operator func [](key: String): Int64 {
        return match (this.get(key)) {
            case None => throw NoneValueException("Value does not exist!\n")
            case Some(val) => val
        }
    }

    public operator func [](key: String, value!: Int64): Unit {
        _ = this.add(key, value)
    }

    /* ---------- O(N) serialize / deserialize ---------- */
    public func serialize(): String {
        let nshards: Int32 = Int32(this.shards.size)
        var live:    Int64 = 0
        var sumKey:  Int64 = 0

        var si: Int32 = 0
        while (si < nshards) {
            let tab = this.shards[Int64(si)].tab
            var j: Int32 = 0
            while (j < tab.cap) {
                if (tab.ctrlAt(j) < 0x80u8) {
                    live   = live + 1
                    sumKey = sumKey + Int64(tab.slots[Int64(j)].key.size)
                }
                j = j + 1
            }
            si = si + 1
        }

        let extraPer: Int64 = 14
        var sb = StringBuilder(sumKey + live * extraPer + 32)

        si = 0
        while (si < nshards) {
            let tab = this.shards[Int64(si)].tab
            var j: Int32 = 0
            while (j < tab.cap) {
                if (tab.ctrlAt(j) < 0x80u8) {
                    let s = tab.slots[Int64(j)]
                    unsafe { sb.appendFromUtf8Unchecked(s.key.rawData()) }
                    sb.append('=')
                    sb.append(s.value)
                    sb.append('\n')
                }
                j = j + 1
            }
            si = si + 1
        }

        return sb.toString()
    }

    public static func deserialize(s: String): KeyValue {
        if (s.size == 0) { return KeyValue() }

        let n: Int64 = s.size
        let EQ: UInt8 = UInt8(61)
        let NL: UInt8 = UInt8(10)

        // pass 1: count lines by '='
        var total: Int32 = 0
        var scan: Int64 = 0
        while (scan < n) {
            let optEq = s.indexOf(EQ, scan)
            match (optEq) {
                case Some(idx) =>
                    total = total + 1
                    scan = idx + 1
                case None =>
                    break
            }
        }

        let kv = KeyValue.newUnreserved_()
        kv.reserve(total)

        // pass 2: parse each line
        var pos: Int64 = 0
        while (pos < n) {
            let optEq = s.indexOf(EQ, pos)
            let peq: Int64 = match (optEq) { case Some(x) => x; case None => break }

            let optNl = s.indexOf(NL, peq + 1)
            let pnl: Int64 = match (optNl) { case Some(x) => x; case None => n }

            let key: String = s[pos..peq]
            let v: Int64 = KeyValue.parseI64_(s, peq + 1, pnl)

            let h  = hash64_(key)
            let si = kv.pick_(h)
            _ = kv.shards[Int64(si)].tab.putPrehashedNoRehash_(h, key, v)

            pos = if (pnl < n) { pnl + 1 } else { n }
        }

        return kv
    }
}

/* ---------- weakly consistent iterator ---------- */
private class KeyValueIterator <: Iterator<(String, Int64)> {
    private let kv: KeyValue
    private let keys: Array<String>
    private var i: Int32

    public init(_kv: KeyValue, _keys: Array<String>) {
        kv = _kv
        keys = _keys
        i = 0
    }

    public func next(): Option<(String, Int64)> {
        while (i < Int32(keys.size)) {
            let k = keys[Int64(i)]
            i = i + 1
            match (kv.get(k)) {
                case Some(v) => return Some((k, v))
                case None => ()
            }
        }
        return None
    }
}
