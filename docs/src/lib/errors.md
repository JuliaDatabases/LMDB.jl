# [Errors](@id API-Errors)

```@meta
CurrentModule = LMDB
```

`LMDBError.code` contains the raw status returned by LMDB. Compare it with a
qualified `LMDB.MDB_*` constant when handling a particular error.

## Exception type

```@docs
LMDBError
```

## Status constants

The full set of status codes is available as qualified `LMDB.MDB_*` names:

| constant | meaning |
|----------|---------|
| `MDB_NOTFOUND` | key not present |
| `MDB_KEYEXIST` | key (or duplicate) already present, with `MDB_NOOVERWRITE`/`MDB_NODUPDATA` |
| `MDB_MAP_FULL` | environment's `MapSize` exhausted |

The rest (`MDB_PAGE_NOTFOUND`, `MDB_CORRUPTED`, `MDB_PANIC`,
`MDB_VERSION_MISMATCH`, `MDB_INVALID`, `MDB_DBS_FULL`, `MDB_READERS_FULL`,
`MDB_TLS_FULL`, `MDB_TXN_FULL`, `MDB_CURSOR_FULL`, `MDB_PAGE_FULL`,
`MDB_MAP_RESIZED`, `MDB_INCOMPATIBLE`, `MDB_BAD_RSLOT`, `MDB_BAD_TXN`,
`MDB_BAD_VALSIZE`, `MDB_BAD_DBI`, `MDB_PROBLEM`, `MDB_BAD_CHECKSUM`,
`MDB_CRYPTO_FAIL`, `MDB_ENV_ENCRYPTION`, `MDB_TXN_PENDING`,
`MDB_CANT_ROLLBACK`, `MDB_DBIS_BUSY`, `MDB_SHORT_WRITE`,
`MDB_ENV_BUSY`, `MDB_IS_READONLY`, `MDB_ADDR_BUSY`) live under the
`LMDB.` prefix.

## Where errors come from at each surface

At the C API, bindings wrapped by `@checked` auto-throw `LMDBError`;
the `unchecked_*` companion returns the raw `Cint` so the caller can
branch on `MDB_NOTFOUND`/`MDB_KEYEXIST` and friends.

At the Julia wrappers, handle methods that wrap status-returning
bindings let `LMDBError` propagate. `get(..., default)` swallows
`MDB_NOTFOUND` and returns `default` (use `nothing` for the
`Union{T,Nothing}` shape). `delete!(txn, dbi, key)` likewise swallows
`MDB_NOTFOUND` and returns `false`.

At the high-level interface, missing keys produce `KeyError` (matching
`Base.Dict`), and `pop!(d)` on an empty dict throws `ArgumentError`.
Other LMDB errors propagate as `LMDBError`.
