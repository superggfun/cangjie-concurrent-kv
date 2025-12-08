// KeyValue.cj — SwissTable (ctrl pointer version) + shards + seqlock + O(N) serialize/deserialize (Array-only)
// 原始 SwissTable（ctrl 指针版本）+ 分片 + seqlock + O(N) 序列化/反序列化（仅使用 Array 存储）
package techarena

import std.sync.*          // ReentrantMutex, AtomicUInt64

// --------------- FFI / C interop ---------------
// 用 C 的 malloc/free 管控 ctrl 指针缓冲区
// Use C malloc/free to manage the ctrl pointer buffer
foreign func malloc(size: Int64): CPointer<UInt8>
foreign func free(ptr: CPointer<UInt8>): Unit

// ======================= 常量/工具 =======================
// Constants & small helpers
private let GROUP_WIDTH: Int32 = 16i32
private let K_EMPTY:    UInt8  = 0x80u8   // 空位 / empty slot
private let K_DELETED:  UInt8  = 0xfeu8   // 删除墓碑 / tombstone
private let K_SENTINEL: UInt8  = 0xffu8   // 末尾哨兵 / sentinel at end
private let PRE_RESERVE_NKEYS: Int32 = 1000000i32

@OverflowWrapping
private func H1_(h: UInt64): UInt64 { return (h >> 7u64) }
@OverflowWrapping
private func H2_(h: UInt64): UInt8  { return UInt8(h & 0x7fu64) }

// 轻量级哈希；可替换为 wyhash/farmhash
// Lightweight hash; can be swapped to wyhash/farmhash
@OverflowWrapping
private func hash64_(s: String): UInt64 { return UInt64(s.hashCode()) }

// 低位 1 的索引（x != 0），否则返回 -1（写路径用）
// Index of lowest set bit when x != 0, otherwise -1 (used on write path)
private func tz_u32_(x: UInt32): Int32 {
    if (x == 0u32) { return -1 }
    var i: Int32 = 0
    var v: UInt32 = x
    while ((v & 1u32) == 0u32) { v = v >> 1u32; i = i + 1 }
    return i
}

// ======================= 结构 =======================
// Basic slot layout
private struct Slot {
    public var key:   String      // 仅用于 serialize / getKeys / only used by serialize / getKeys
    public var value: Int64
    public var h:     UInt64      // 64-bit ID（hash）/ 64-bit ID (hash)
    public init() {
        this.key = ""
        this.value = 0i64
        this.h = 0u64
    }
}

// ======================= 原始 Swiss 表（字符串->I64） =======================
// Low-level Swiss table (String -> Int64)
private class SwissRaw {
    public var groups:    Int32
    public var cap:       Int32
    public var mask:      Int32
    public var size:      Int32
    public var max_load:  Int32
    public var del_count: Int32
    public var rehashing: Bool

    // ctrl 由指针管理（cap + 1 + GROUP_WIDTH）
    // ctrl array is managed by a raw pointer (length cap + 1 + GROUP_WIDTH)
    public var ctrl_ptr: CPointer<UInt8>
    public var ctrl_n:   Int32

    public var slots: Array<Slot>

    public init(init_groups: Int32) {
        let g: Int32 = if (init_groups < 1i32) { 1i32 } else { init_groups }
        this.groups   = SwissRaw.pow2ceil_(g)
        this.cap      = this.groups * GROUP_WIDTH
        this.mask     = this.cap - 1i32
        this.size     = 0i32
        this.max_load = (this.cap * 7i32) / 8i32
        this.del_count = 0
        this.rehashing = false

        // 分配 ctrl 指针并静态初始化（避免构造期调用实例方法）
        // Allocate ctrl pointer and initialize it statically (avoid calling instance methods in constructor)
        let n_ctrl: Int32 = this.cap + GROUP_WIDTH + 1i32
        this.ctrl_n   = n_ctrl
        this.ctrl_ptr = unsafe { malloc(Int64(n_ctrl)) }
        SwissRaw.init_ctrl_static_(this.ctrl_ptr, this.cap)

        // 分配 slots / allocate slots array
        let n_slots: Int32 = this.cap
        this.slots = Array<Slot>(Int64(n_slots), { _ => Slot() })
    }

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

    /**
    * 把 8 个字节打包在 UInt64 v 里，返回一个 8-bit mask：
    *   返回值的 bit i == 1 表示 v 的第 i 个字节 == target
    * Pack 8 bytes into UInt64 v and return an 8-bit mask:
    *   bit i == 1 means the i-th byte of v is equal to target.
    */
    @OverflowWrapping
    private static func bytesEqMask8_(v: UInt64, target: UInt8): UInt32 {
        // 1) 把 target 扩展成 8 个字节的 pattern
        // 1) Broadcast target into a 8-byte pattern
        let t: UInt64 = UInt64(target)
        var patt: UInt64 = t
        patt = patt | (patt << 8u64)
        patt = patt | (patt << 16u64)
        patt = patt | (patt << 32u64)       // 现在是 8 个同样的字节 / now 8 identical bytes

        // 2) x = v ^ pattern；某个字节相等 <=> 该字节为 0
        // 2) x = v ^ pattern; equal byte <=> that byte becomes 0
        let x: UInt64 = v ^ patt

        // 3) broadword “hasZeroByte”：高位为 1 的字节就是 0 字节
        // 3) Broadword "hasZeroByte": bytes with high bit 1 are zero bytes
        let ones:     UInt64 = 0x0101010101010101u64
        let highBits: UInt64 = 0x8080808080808080u64
        var m: UInt64 = (x - ones) & (!x) & highBits

        // 4) 把每个字节的最高位压缩成 8-bit 掩码（无分支）
        // 4) Compress each byte's top bit into an 8-bit mask (branch-free)
        var mask: UInt32 = 0u32
        var i: Int32 = 0
        while (i < 8) {
            let shift: UInt64 = UInt64(i * 8 + 7)
            let bit:   UInt64 = (m >> shift) & 1u64   // 0 or 1
            mask = mask | (UInt32(bit) << UInt32(i))
            i = i + 1
        }
        return mask
    }

    // ---------- 指针版 ctrl 读/写/基址 ----------
    // Pointer-based ctrl read/write/base helpers
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
        // 直接读指针，等价于 ctrl_read_，但对类外可见
        // Direct pointer read, equivalent to ctrl_read_, but exposed to outside
        return unsafe { (ctrl_ptr + Int64(i)).read() }
    }

    public func ensure_capacity_groups_(new_groups: Int32): Unit {
        // 确保至少有 new_groups 组（向上取 2 的幂）/ ensure at least new_groups groups (rounded to power of two)
        let g2 = SwissRaw.pow2ceil_(new_groups)
        if (g2 <= groups) { return }
        rehash_(g2)
    }

    // 安全销毁（如果你需要替换对象前先释放 C 层内存）
    // Safe destroy (if you need to free C memory before dropping the object)
    public func destroy_(): Unit {
        if (ctrl_n > 0 && ctrl_ptr.isNotNull()) {
            unsafe { free(ctrl_ptr) }
        }
        ctrl_n = 0
        cap = 0; mask = 0; groups = 1; size = 0; max_load = 0; del_count = 0
        slots = Array<Slot>() // 交给 GC / let GC reclaim
    }

    // 公开“预哈希插入”（薄封装 putKnown_）
    // Public pre-hashed insert (thin wrapper around putKnown_)
    public func putPrehashedNoRehash_(h: UInt64, k: String, v: Int64): Unit {
        putKnown_(h, k, v)
    }

    // 主路径用：预哈希 + 带 rehash
    // Main path: pre-hashed insert with rehash
    public func putPrehashed_(h: UInt64, k: String, v: Int64): Unit {
        if (del_count > (cap >> 3) && (size + del_count) >= max_load) {
            rehash_(groups)          // 等组数，专门清理墓碑 / same group count, just clean tombstones
        } else if (size >= max_load) {
            rehash_(groups << 1)     // 真正满载再扩容 / double groups when really full
        }
        putKnown_(h, k, v)
    }

    // ====== 只读路径（顺扫 16B 窗口 + 先比 h 再比长度，最后才比字符串） ======
    // ====== Read-only path: scan 16B window, compare h first, then length, then string ======
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
                    let ip:  Int64 = Int64(pos)
                    let s = tab.slots[ip]
                    // 映射版：只比 h，当成 ID
                    // Mapping version: treat h as stable ID, compare h only
                    if (s.h == h) { return Some(s.value) }
                }
                if (c == K_EMPTY) { return None }
                i = i + 1
            }
            step = step + GROUP_WIDTH
            base = (base + step) & mask
        }
        return None
    }

    public func countLive_(): Int32 { return this.size }

    private func match16_masks_ptr_(base: Int32, h2: UInt8): (UInt32, UInt32, UInt32) {
        let p = ctrl_base_(base)          // 指向当前 group 的首字节 / pointer to first byte of current group

        // 1) 先各读 8 字节（调用 unsafe 函数要包一层 unsafe）
        // 1) Read two 8-byte blocks (must be wrapped in unsafe)
        let v0: UInt64 = unsafe { SwissRaw.load8_(p) }           // base+0..7
        let v1: UInt64 = unsafe { SwissRaw.load8_(p + 8i64) }    // base+8..15

        // 2) 对每个 8-byte 块算 3 个掩码
        // 2) For each 8-byte block, compute three masks
        let m0_h2: UInt32 = SwissRaw.bytesEqMask8_(v0, h2)
        let m0_e:  UInt32 = SwissRaw.bytesEqMask8_(v0, K_EMPTY)
        let m0_d:  UInt32 = SwissRaw.bytesEqMask8_(v0, K_DELETED)

        let m1_h2: UInt32 = SwissRaw.bytesEqMask8_(v1, h2)
        let m1_e:  UInt32 = SwissRaw.bytesEqMask8_(v1, K_EMPTY)
        let m1_d:  UInt32 = SwissRaw.bytesEqMask8_(v1, K_DELETED)

        // 3) 拼成 16bit 掩码 / merge into 16-bit masks
        let mh2: UInt32 = m0_h2 | (m1_h2 << 8u32)
        let me:  UInt32 = m0_e  | (m1_e  << 8u32)
        let md:  UInt32 = m0_d  | (m1_d  << 8u32)

        return (mh2, me, md)
    }

    private func putKnown_(h: UInt64, k: String, v: Int64): Unit {
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
                let ip:  Int64 = Int64(pos)
                let s0 = slots[ip]
                // 命中只看 h（ID）/ treat h as ID when updating existing entry
                if (s0.h == h && s0.key.size == k.size) {
                    var s = s0
                    s.value = v
                    slots[ip] = s
                    return
                }
                m = m & (m - 1u32)
            }
            if (first_del < 0 && md != 0u32) { first_del = (base + tz_u32_(md)) & mask }
            if (me != 0u32) {
                if (first_del >= 0) {
                    insert_at_(first_del, h, h2, k, v, ctrl_read_(first_del))
                } else {
                    let ins: Int32 = (base + tz_u32_(me)) & mask
                    insert_at_(ins, h, h2, k, v, K_EMPTY)
                }
                return
            }
            step = step + GROUP_WIDTH
            base = (base + step) & mask_
        }
    }

    public static func fillKeysNoLock_(tab: SwissRaw): Array<String> {
        let cnt = tab.size
        if (cnt <= 0) { return Array<String>() }
    
        var arr = Array<String>(Int64(cnt), { _ => "" })
        var w: Int32 = 0
        var j: Int32 = 0
    
        while (j < tab.cap) {
            if (tab.ctrlAt(j) < 0x80u8) {
                if (w < cnt) {
                    arr[Int64(w)] = tab.slots[Int64(j)].key
                    w = w + 1
                } else {
                    // size 低估了 live 数，回退到安全的两趟法
                    return SwissRaw.fillKeysCountedNoLock_(tab)
                }
            }
            j = j + 1
        }
    
        if (w == cnt) { return arr }
    
        var arr2 = Array<String>(Int64(w), { _ => "" })
        var i: Int32 = 0
        while (i < w) { arr2[Int64(i)] = arr[Int64(i)]; i = i + 1 }
        return arr2
    }
    
    // 你原来的两趟计数版本改个名字保留
    public static func fillKeysCountedNoLock_(tab: SwissRaw): Array<String> {
        var cnt: Int32 = 0
        var j: Int32 = 0
        while (j < tab.cap) { if (tab.ctrlAt(j) < 0x80u8) { cnt = cnt + 1 }; j = j + 1 }
    
        var arr = Array<String>(Int64(cnt), { _ => "" })
        var w: Int32 = 0
        j = 0
        while (j < tab.cap) {
            if (tab.ctrlAt(j) < 0x80u8) {
                arr[Int64(w)] = tab.slots[Int64(j)].key
                w = w + 1
            }
            j = j + 1
        }
        return arr
    }

    public func get(k: String): Option<Int64> {
        let h: UInt64 = hash64_(k)
        // 直接复用只读探测逻辑，不再自己 match16_masks_ptr_
        // Reuse read-only probe logic instead of duplicating match16_masks_ptr_
        return SwissRaw.ro_get_by_hash_(this, h, k)
    }

    public func put(k: String, v: Int64): Unit {
        // 和之前一样先做 rehash 检查
        // Same as before: check whether we should rehash
        if (del_count > (cap >> 3) && (size + del_count) >= max_load) {
            rehash_(groups)       // 等组数，专门清理墓碑 / same group count, just clean tombstones
        } else if (size >= max_load) {
            rehash_(groups << 1)  // 真正满载再扩容 / expand when fully loaded
        }

        let h: UInt64 = hash64_(k)
        putKnown_(h, k, v)
    }

    public func erasePrehashed_(h: UInt64, k: String): Bool {
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
                let ip:  Int64 = Int64(pos)
                let s = slots[ip]
                if (s.h == h) {
                    set_ctrl_(pos, K_DELETED)
                    var sclr = slots[ip]
                    sclr.key = ""
                    slots[ip] = sclr
                    size = size - 1
                    del_count = del_count + 1
                    return true
                }
                m = m & (m - 1u32)
            }
            if (me != 0u32) { return false }
            step = step + GROUP_WIDTH
            base = (base + step) & mask_
        }
        return false
    }

    public func erase(k: String): Bool {
        let h:  UInt64 = hash64_(k)
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
                let ip:  Int64 = Int64(pos)
                let s = slots[ip]
                if (s.h == h) {
                    set_ctrl_(pos, K_DELETED)
                    var sclr = slots[Int64(pos)]
                    sclr.key = ""
                    slots[Int64(pos)] = sclr
                    size = size - 1
                    del_count = del_count + 1
                    return true
                }
                m = m & (m - 1u32)
            }
            if (me != 0u32) { return false }
            step = step + GROUP_WIDTH
            base = (base + step) & mask_
        }
        return false
    }

    // 读快照（如果你需要）
    // Read-only snapshot (if the caller needs it)
    public func snap_(): (CPointer<UInt8>, Array<Slot>, Int32, Int32, Int32) {
        return (ctrl_ptr, slots, cap, mask, groups)
    }

    // ================= 内部实现 =================
    // Internal helpers
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

    // 静态初始化 ctrl（避免构造期间调用实例方法）
    // Static ctrl initialization (to avoid calling instance methods in constructor)
    private static func init_ctrl_static_(p: CPointer<UInt8>, cap: Int32): Unit {
        let n_ctrl: Int32 = cap + GROUP_WIDTH + 1
        var i: Int32 = 0
        while (i < n_ctrl) { unsafe { (p + Int64(i)).write(K_EMPTY) }; i = i + 1 }
        unsafe { (p + Int64(cap)).write(K_SENTINEL) }
        var j: Int32 = 0
        while (j < GROUP_WIDTH) {
            let v: UInt8 = unsafe { (p + Int64(j)).read() }   // 此处为 K_EMPTY / here it is K_EMPTY
            unsafe { (p + Int64(cap + 1 + j)).write(v) }
            j = j + 1
        }
    }

    private func set_ctrl_(pos: Int32, c: UInt8): Unit { ctrl_write_clone_(pos, c) }

    private func insert_at_(pos: Int32, h: UInt64, h2: UInt8, k: String, v: Int64, prev_c: UInt8): Unit {
        let ip: Int64 = Int64(pos)
        var s = slots[ip]
        s.key   = k
        s.value = v
        s.h     = h
        slots[ip] = s
        set_ctrl_(pos, h2)
        size = size + 1
        if (prev_c == K_DELETED) { del_count = del_count - 1 }
        if (!rehashing && prev_c == K_EMPTY && size >= max_load) { rehash_(groups << 1) }
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

        // 重新分配 ctrl / reallocate ctrl buffer
        let n_ctrl: Int32  = cap + GROUP_WIDTH + 1
        ctrl_n   = n_ctrl
        ctrl_ptr = unsafe { malloc(Int64(n_ctrl)) }
        SwissRaw.init_ctrl_static_(ctrl_ptr, cap)

        // 重新分配 slots / reallocate slots
        let n_slots: Int32 = cap
        this.slots = Array<Slot>(Int64(n_slots), { _ => Slot() })

        size = 0

        // 逐个搬运 / move entries one by one
        var i: Int32 = 0
        while (i < old_cap) {
            let c: UInt8 = unsafe { (old_ctrl_ptr + Int64(i)).read() }
            if (c < 0x80u8) {
                let s = old_slots[Int64(i)]
                putKnown_(s.h, s.key, s.value)
            }
            i = i + 1
        }

        // 释放旧 ctrl / free old ctrl buffer
        unsafe { free(old_ctrl_ptr) }
        rehashing = false
    }
}

// ======================= 并发分片包装（seqlock 读、写锁写） =======================
// Sharded concurrency wrapper (seqlock for reads, mutex for writes)
private let DEFAULT_SHARDS: Int32 = 16i32

private struct Shard {
    public var ver:  AtomicUInt64   // seqlock 版本号 / seqlock version
    public var w:    ReentrantMutex // 写锁 / write mutex
    public var tab:  SwissRaw       // 分片内的表 / per-shard SwissRaw
    public init(cap_groups: Int32) {
        this.ver = AtomicUInt64(0u64)
        this.w   = ReentrantMutex()
        this.tab = SwissRaw(cap_groups)
    }
}

public class KeyValue {
    private var shards: Array<Shard>
    var shard_mask: Int32

    public init() {
        let n: Int32 = DEFAULT_SHARDS
        // 直接一次成形 Array / construct the shard array in one go
        shards = Array<Shard>(Int64(n), { _ => Shard(512i32) })
        shard_mask = n - 1 // n 必须是 2 的幂 / n must be power of two
        this.reserve(PRE_RESERVE_NKEYS)
    }

    private init(_unreserved: Bool) {
        let n: Int32 = DEFAULT_SHARDS
        // 最小组，等 reserve(total) 再扩到位
        // Smallest groups; reserve(total) will expand to proper size later
        shards = Array<Shard>(Int64(n), { _ => Shard(1i32) })
        shard_mask = n - 1
    }

    // 供反序列化使用的“裸构造” / bare constructor used by deserialize
    public static func newUnreserved_(): KeyValue { return KeyValue(true) }

    public func reserve(total: Int32): Unit {
        let nshards: Int32 = Int32(shards.size)
        let per = KeyValue.ceilDivI32_(total, nshards)
        // 10~20% 裕量即可，避免刚好满载又 rehash
        // 10–20% extra capacity to avoid rehash right after filling
        let per_pad: Int32 = per + ((per + 5) / 6)
        let g = KeyValue.groupsForCount_(per_pad)

        var i: Int32 = 0
        while (i < nshards) {
            shards[Int64(i)].tab.ensure_capacity_groups_(g)
            i = i + 1
        }
    }

    private func pick_(h: UInt64): Int32 { return Int32(h & UInt64(shard_mask)) }

    // ====== 小工具：向上取整 / 2 的幂封顶到组数 ======
    // Small helpers: ceil division and power-of-two group count
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
    // 根据条目数算出合适的 groups（负载 7/8，组宽 16）
    // Compute proper number of groups given entry count (load 7/8, group width 16)
    private static func groupsForCount_(cnt: Int32): Int32 {
        if (cnt <= 0) { return 1 }
        let needCap    = ceilDivI32_(cnt * 8, 7)              // cap >= cnt/0.875
        let needGroups = ceilDivI32_(needCap, GROUP_WIDTH)    // 每组 16 / 16 slots per group
        return pow2ceilI32_(needGroups)
    }

    private static func parseI64_(s: String, start: Int64, end: Int64): Int64 {
        var p: Int64 = start
        var v: Int64 = 0
        var neg: Bool = false

        // 可选的一个 '-' / optional leading '-'
        if (p < end && s[p] == UInt8(45)) {   // '-'
            neg = true
            p = p + 1
        }

        // 假设剩下全是 '0'..'9' / assume remaining chars are '0'..'9'
        while (p < end) {
            let c: UInt8 = s[p]
            v = v * 10 + Int64(c - 48u8)
            p = p + 1
        }

        return if (neg) { -v } else { v }
    }

    // -------- 无锁读（seqlock） --------
    // Lock-free reads using seqlock
    public func get(k: String): Option<Int64> {
        let h  = hash64_(k)
        let si = pick_(h)
        var spins: Int32 = 0
        while (true) {
            let v1: UInt64 = shards[Int64(si)].ver.load()
            if ((v1 & 1u64) != 0u64) { continue }   // 正在写，重试 / writer in progress, retry

            let res = SwissRaw.ro_get_by_hash_(shards[Int64(si)].tab, h, k)

            let v2: UInt64 = shards[Int64(si)].ver.load()
            if (v1 == v2 && (v2 & 1u64) == 0u64) { return res }

            spins = spins + 1
            if (spins > 32) {                      // 退避到加锁读（极少发生）
                // Fallback to locked read (very rare)
                shards[Int64(si)].w.lock()
                let out = shards[Int64(si)].tab.get(k)
                shards[Int64(si)].w.unlock()
                return out
            }
        }
        return None
    }

    // -------- 写路径（加锁 + seqlock 版本） --------
    // Write path: mutex + seqlock versioning
    public func put(k: String, v: Int64): Unit {
        let h:  UInt64 = hash64_(k)
        let si: Int32  = pick_(h)
        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)    // begin write（odd）/ version becomes odd = writing
        shards[Int64(si)].tab.putPrehashed_(h, k, v)
        shards[Int64(si)].ver.fetchAdd(1u64)    // end write（even）/ version becomes even = done
        shards[Int64(si)].w.unlock()
    }

    public func erase(k: String): Bool {
        let h:  UInt64 = hash64_(k)
        let si: Int32  = pick_(h)
        shards[Int64(si)].w.lock()
        shards[Int64(si)].ver.fetchAdd(1u64)    // begin write
        let ok = shards[Int64(si)].tab.erasePrehashed_(h, k)
        shards[Int64(si)].ver.fetchAdd(1u64)    // end write
        shards[Int64(si)].w.unlock()
        return ok
    }

    public func getKeys(): Array<String> {
        // 1) 统计总 live / count total live entries
        let nshards: Int32 = Int32(shards.size)
        var total: Int32 = 0
        var si: Int32 = 0
        while (si < nshards) {
            total = total + shards[Int64(si)].tab.countLive_()
            si = si + 1
        }

        // 2) 一次成形目标数组 / allocate result array once
        var out = Array<String>(Int64(total), { _ => "" })

        // 3) 直接用 ctrl_ptr 顺序读（仅 0..cap-1，有效区）
        // 3) Iterate using ctrl_ptr directly (only 0..cap-1 valid range)
        var w: Int32 = 0
        si = 0
        while (si < nshards) {
            let tab  = this.shards[Int64(si)].tab
            let cap  = tab.cap
            let ctrl = tab.ctrl_ptr      // cap + GROUP_WIDTH + 1 总长；这里仅读 0..cap-1
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

        // 并发写入下的保护性收缩（通常 w == total）
        // Shrink to actual size if concurrent writes changed the count (usually w == total)
        if (w == total) { return out }
        var out2 = Array<String>(Int64(w), { _ => "" })
        var i: Int32 = 0
        while (i < w) { out2[Int64(i)] = out[Int64(i)]; i = i + 1 }
        return out2
    }

    // === O(N) 快速序列化（文本）：一次容量估算 + 一次写入 ===
    // O(N) text serialization: estimate capacity once, then write once
    public func serialize(): String {
        // 1) 汇总 live & key 总字节
        // 1) Sum total number of live entries and total key bytes
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
        // base-10 文本存 value：'='(1) + value(<=11) + '\n'(1) ≈ 13，再预留 1
        // base-10 text for value: '='(1) + value(<=11 digits) + '\n'(1) ≈ 13, plus some slack
        let extraPer: Int64 = 14
        // 预留一点额外空间，避免 StringBuilder 频繁扩容
        // Reserve some extra space to avoid StringBuilder growing
        var sb = StringBuilder(sumKey + live * extraPer + 32)

        // 2) 单趟写出：key + '=' + value + '\n'
        // 2) Single pass: key + '=' + value + '\n'
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

    // === 文本反序列化（O(N)） ===
    // O(N) text deserialization
    public static func deserialize(s: String): KeyValue {
        if (s.size == 0) { return KeyValue() }

        let n: Int64 = s.size
        let EQ: UInt8 = UInt8(61)   // '='
        let NL: UInt8 = UInt8(10)   // '\n'

        // ① 用 indexOf('=') 预扫描，统计总行数（即总 KV 数）
        // ① First pass: use indexOf('=') to count total lines (i.e. total KV pairs)
        var total: Int32 = 0
        var scan: Int64 = 0
        while (scan < n) {
            let optEq = s.indexOf(EQ, scan)
            match (optEq) {
                case Some(idx) =>
                    total = total + 1
                    scan = idx + 1      // 从 '=' 之后继续找下一行 / continue after '='
                case None =>
                    break                // 没有更多 '='，结束 / no more '=', stop
            }
        }

        // ② 根据 total 预留容量
        // ② Reserve capacity based on total
        let kv = KeyValue.newUnreserved_()
        kv.reserve(total)

        // ③ 第二趟：按行解析 key / value 并插入
        // ③ Second pass: parse each line into key/value and insert
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
            kv.shards[Int64(si)].tab.putPrehashedNoRehash_(h, key, v)

            pos = if (pnl < n) { pnl + 1 } else { n }
        }
        return kv
    }
}



