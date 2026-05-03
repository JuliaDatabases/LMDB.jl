# [Errors](@id API-Errors)

```@meta
CurrentModule = LMDB
```

Every LMDB-internal error surfaces as an `LMDBError` whose `code` field is
the raw status `Cint` returned by the underlying binding. Status-code
matchers cover the three most common branches; less common codes can be
matched against `LMDB.MDB_*` constants directly.

## Exception type

```@docs
LMDBError
```

## Status-code matchers

```@docs
is_notfound
is_keyexist
is_map_full
```

## Error helpers

```@docs
errormsg
```

## Status constants

The full set of LMDB status codes is exposed as `LMDB.MDB_*`. The
commonly-needed ones are exported:

| constant | meaning |
|----------|---------|
| `MDB_NOTFOUND` | key not present |
| `MDB_KEYEXIST` | key (or duplicate) already present, with `MDB_NOOVERWRITE`/`MDB_NODUPDATA` |
| `MDB_MAP_FULL` | environment's `MapSize` exhausted |

The rest (`MDB_PAGE_NOTFOUND`, `MDB_CORRUPTED`, `MDB_PANIC`,
`MDB_VERSION_MISMATCH`, `MDB_INVALID`, `MDB_DBS_FULL`, `MDB_READERS_FULL`,
`MDB_TLS_FULL`, `MDB_TXN_FULL`, `MDB_CURSOR_FULL`, `MDB_PAGE_FULL`,
`MDB_MAP_RESIZED`, `MDB_INCOMPATIBLE`, `MDB_BAD_RSLOT`, `MDB_BAD_TXN`,
`MDB_BAD_VALSIZE`, `MDB_BAD_DBI`) live under the `LMDB.` prefix.

## Where errors come from at each tier

- **Tier 1.** Bindings wrapped by `@checked` auto-throw `LMDBError`;
  the `unchecked_*` companion returns the raw `Cint` so the caller can
  branch on `MDB_NOTFOUND`/`MDB_KEYEXIST`/etc.
- **Tier 2.** Handle methods that wrap status-returning bindings let
  `LMDBError` propagate. `tryget` and `get(..., default)` swallow
  `MDB_NOTFOUND` and return `nothing`/`default`. `delete!(txn, dbi, key)`
  likewise swallows `MDB_NOTFOUND` and returns `false`.
- **Tier 3.** Missing keys produce `KeyError` (matching `Base.Dict`).
  `pop!(d)` on an empty dict throws `ArgumentError`. Other LMDB errors
  propagate as `LMDBError`.
