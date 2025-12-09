# cangjie-concurrent-kv

🏆 Champion – Huawei Tech Arena UK 2025

Originally developed for the Huawei Tech Arena UK 2025 concurrent key–value store challenge.

A high-performance in-memory key–value store written in Cangjie, inspired by SwissTable and designed for concurrent workloads (shards + seqlock readers).

---

## 1. Overview / 项目概览

This repository provides a single core implementation:

- `src/KeyValue.cj` – the main key–value store

The table maps:

- `String -> Int64`

and is optimized for:

- high load factor
- predictable probing
- concurrent reads with minimal contention

---

## 2. Public API / 对外接口

The main type exposed by the library is:

### `class KeyValue`

A sharded, SwissTable-style concurrent key–value store implementing **strict production key semantics** (no mode switch), optimized for **String → Int64**.  
It provides **old-value returns** for update/remove-style operations, a **stdlib-like facade**, and **O(N)** text-based serialization/deserialization.

一个基于分片 + SwissTable（ctrl 指针版）+ seqlock 的并发键值容器，使用**严格生产环境 key 语义**（无模式切换），面向 **String → Int64** 场景优化。  
支持**返回旧值**、**标准库风格接口**，并提供 **O(N)** 文本序列化/反序列化能力。

---

### Construction / 构造

```cangjie
let kv = KeyValue()
```

- Internally uses `DEFAULT_SHARDS = 16`.
- The default constructor pre-reserves for large workloads (via `reserve(PRE_RESERVE_NKEYS)`).

---

### Capacity / 预分配

```cangjie
kv.reserve(1_000_000i32)
```

Pre-sizes each shard to reduce rehashing overhead in large batch inserts.

---

### Queries / 查询

```cangjie
let n = kv.size
let empty = kv.isEmpty()
let ok = kv.contains("foo")
let vOpt = kv.get("foo")
```

- `size: Int64`
- `isEmpty(): Bool`
- `contains(key: String): Bool`
- `get(key: String): Option<Int64>`  
  Seqlock optimistic read; may fall back to locked read after repeated conflicts.

---

### Mutations / 写入与更新

```cangjie
let old1 = kv.add("foo", 1i64)          // returns old value if existed
kv.put("bar", 2i64)                     // compatibility alias of add
let old2 = kv.addIfAbsent("foo", 9i64)  // returns existing value if present
```

- `add(key, value): Option<Int64>`
- `put(key, value): Unit` (compatibility alias)
- `addIfAbsent(key, value): Option<Int64>`

---

### Removal / 删除

```cangjie
let old = kv.remove("foo")

let old2 = kv.remove("bar", { v => v > 0i64 })

let ok = kv.erase("baz") // Bool compatibility API
```

- `remove(key): Option<Int64>`
- `remove(key, predicate): Option<Int64>`
- `erase(key): Bool` (compatibility alias)

---

### Replace / 条件替换

```cangjie
let old = kv.replace("foo", 7i64)
let ok  = kv.replace("foo", 7i64, 8i64)
```

- `replace(key, value): Option<Int64>`  
  Only updates when key exists.
- `replace(key, oldValue, newValue): Bool`

---

### Keys / Values / 遍历

```cangjie
let ks = kv.getKeys()
let vs = kv.values()

for (pair in kv.iterator()) {
    // (String, Int64)
}
```

- `getKeys(): Array<String>`
- `keys(): Array<String>` (alias)
- `values(): Array<Int64>`
- `iterator(): Iterator<(String, Int64)>`  
  Weakly consistent.

---

### Clear / 清空

```cangjie
kv.clear()
```

Rebuilds each shard with the same group size.

---

### Operators / 下标操作

```cangjie
let x = kv["foo"]     // throws if missing
kv["foo"] = 123i64
```

- `operator [](key): Int64`
- `operator [](key, value!): Unit`

---

### Serialization / 序列化

Text format: one entry per line:

```
key=value\n
```

```cangjie
let txt = kv.serialize()
let kv2 = KeyValue.deserialize(txt)
```

- `serialize(): String`  
  O(N) scan of live slots across shards.
- `static deserialize(s: String): KeyValue`  
  Two-pass parse:  
  1) count entries  
  2) reserve + insert using `putPrehashedNoRehash_` for lower overhead

---

### Basic usage / 基本用法

```cangjie
let kv = KeyValue()

kv.put("foo", 1i64)
kv.put("bar", 2i64)

match (kv.get("foo")) {
    case Some(v) => println("foo = ${v}")
    case None    => println("not found")
}

kv.erase("bar")

let txt = kv.serialize()

let kv2 = KeyValue.deserialize(txt)
```






