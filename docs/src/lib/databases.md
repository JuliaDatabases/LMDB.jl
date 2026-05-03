# [Databases](@id API-DBI)

```@meta
CurrentModule = LMDB
```

A `DBI` (database identifier) is a handle to one B-tree inside an
environment. By default an env has a single anonymous database (the
"main DB"); pass `maxdbs > 0` to `Environment` and a name to `open` to
work with multiple named sub-databases.

## Construction

```@docs
DBI
Base.open(::Transaction, ::String)
Base.close(::Environment, ::DBI)
Base.isopen(::DBI)
flags
drop
Base.stat(::Transaction, ::DBI)
```

## Reads

```@docs
Base.get(::Transaction, ::DBI, ::Any, ::Type{T}) where T
Base.get(::Transaction, ::DBI, ::Any, ::Type{T}, ::Any) where T
tryget
```

`get(txn, dbi, key, T, default)` falls back to `default` if `key` is
missing — same shape as `Base.get(dict, key, default)`.

## Writes

```@docs
Base.put!(::Transaction, ::DBI, ::Any, ::Any)
put_reserved!
Base.delete!(::Transaction, ::DBI, ::Any)
Base.replace!(::Transaction, ::DBI, ::Any, ::Any)
Base.pop!(::Transaction, ::DBI, ::Any, ::Type)
```

## Write flags

The `flags` keyword on `put!` accepts a bitwise-or of:

| flag | meaning |
|------|---------|
| `MDB_NOOVERWRITE` | fail with `MDB_KEYEXIST` if `key` is already present |
| `MDB_NODUPDATA`   | (DUPSORT) fail if `(key, val)` pair already present |
| `MDB_APPEND`      | append at the end; only valid if the new key sorts after every existing key |
| `MDB_RESERVE`     | preferred via [`put_reserved!`](@ref) |

See also the [DUPSORT-only ops](@ref API-Cur-DUPSORT) on the cursor surface.
