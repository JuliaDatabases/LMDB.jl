# Duplicate-sort databases

```@meta
CurrentModule = LMDB
```

By default each key in an LMDB database has a single value. Opening a
DB with `MDB_DUPSORT` instead allows multiple values per key, kept in
sorted order. This is what LMDB offers for inverted indexes,
many-to-many edges, time-series buckets, and similar "key → set of
values" patterns.

```julia
env = Environment("/tmp/edges"; mapsize = 1 << 30, maxdbs = 1)
Transaction(env) do txn
    dbi = DBI(txn, "edges"; flags = LMDB.MDB_CREATE | LMDB.MDB_DUPSORT)
    put!(txn, dbi, "a", "b")
    put!(txn, dbi, "a", "c")
    put!(txn, dbi, "a", "d")
    put!(txn, dbi, "b", "c")
end
```

`(a, b)`, `(a, c)`, `(a, d)`, `(b, c)` are all distinct entries.
Putting the same `(key, val)` pair twice silently no-ops (or raises
`MDB_KEYEXIST` if `MDB_NODUPDATA` is set).

## Why DUPSORT instead of value packing

A common alternative is to pack a list into a single value
(`key -> [v1, v2, v3]`) and read-modify-write on each update.
DUPSORT wins when:

- you want `O(log n)` insert/delete of a single value (vs. rewriting
  the whole list),
- you want sorted access to values without sorting in-process,
- the per-key cardinality is large enough that value-packing pages
  blow past `MDB_MAXKEYSIZE` or LMDB's overflow-page threshold,
- you want range queries within a key's values
  (`seek_range!` style).

It loses if you need fast aggregate reads of every value at a key. For
that case, use `MDB_DUPFIXED` (fixed-size duplicates), which stores
values contiguously and returns them in batches.

## Navigation

DUPSORT layers an extra dimension on the cursor. The cursor is
positioned at a `(key, value)` pair, and you can navigate either
across keys or across values within the current key.

```julia
seek!(cur, "a")                    # position at (a, b), the first dup
seek_first_dup!(cur)               # value of first dup of current key
next_dup!(cur)                     # next dup of current key  → (a, c)
next_dup!(cur)                     #                          → (a, d)
next_dup!(cur)                     # nothing, out of dups for "a"
next_nodup!(cur)                   # skip to next key, first dup → (b, c)
```

| function | LMDB op | step within key | step across keys |
|----------|---------|-----------------|------------------|
| `next!`            | `MDB_NEXT`         | yes (next dup) | yes (next key when dups exhausted) |
| `prev!`            | `MDB_PREV`         | yes | yes |
| `next_dup!`        | `MDB_NEXT_DUP`     | yes | no, `nothing` past last dup |
| `prev_dup!`        | `MDB_PREV_DUP`     | yes | no |
| `next_nodup!`      | `MDB_NEXT_NODUP`   | jump out | yes (first dup of next key) |
| `prev_nodup!`      | `MDB_PREV_NODUP`   | jump out | yes (first dup of previous key) |
| `seek_first_dup!`  | `MDB_FIRST_DUP`    | first dup of current key | – |
| `seek_last_dup!`   | `MDB_LAST_DUP`     | last dup of current key | – |

`count(cur)` returns the number of duplicates at the current key.

## Deleting a single duplicate

```julia
delete!(txn, dbi, "a", "c")        # → true; only (a, c) is removed
delete!(txn, dbi, "a")             # → true; removes ALL dups of "a"
```

The two-argument `delete!` removes every value at `key`. The
three-argument form removes one specific `(key, val)` pair, leaving
the rest of the dups intact.

## Useful flag combinations

- `MDB_DUPSORT` alone: variable-size duplicates, sorted by full byte
  comparison.
- `MDB_DUPSORT | MDB_DUPFIXED`: every duplicate has the same byte
  size; LMDB stores them as a packed array per key. Required for the
  `MDB_GET_MULTIPLE` / `MDB_NEXT_MULTIPLE` cursor ops, which are
  reachable from the C API.
- `MDB_DUPSORT | MDB_DUPFIXED | MDB_INTEGERDUP`: values are
  native-endian integers; sorted numerically.
- `MDB_DUPSORT | MDB_REVERSEDUP`: values compared back-to-front.

`MDB_RESERVE` (and therefore `put_reserved!`) is not valid against a
DUPSORT database; LMDB rejects it.
