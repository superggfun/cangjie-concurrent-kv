# cangjie-concurrent-kv

🏆 Winner – Huawei Tech Arena UK 2025

This project was originally developed for the Huawei Tech Arena UK 2025 challenge (concurrent key–value store problem).
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

Basic usage:

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


