# [Databases](@id API-Database)

```@meta
CurrentModule = LMDB
```

A `Database` (database identifier) is a handle to one B-tree inside an
environment. By default an env has a single anonymous database (the
"main DB"); pass `maxdbs > 0` to `Environment` and a name to the `Database`
constructor to work with multiple named sub-databases.

## Construction

```@docs
Database
Database(::Transaction, ::AbstractString)
Base.close(::Environment, ::Database)
Base.isopen(::Database)
flags
drop
Base.stat(::Transaction, ::Database)
```

## Reads

```@docs
Base.get(::Transaction, ::Database, ::Any, ::Type{T}) where T
Base.get(::Transaction, ::Database, ::Any, ::Type{T}, ::Any) where T
```

`get(txn, dbi, key, T, default)` falls back to `default` if `key` is
missing, matching `Base.get(dict, key, default)`.

## Writes

```@docs
Base.put!(::Transaction, ::Database, ::Any, ::Any)
put_reserved!
Base.delete!(::Transaction, ::Database, ::Any)
Base.replace!(::Transaction, ::Database, ::Any, ::Any)
Base.pop!(::Transaction, ::Database, ::Any, ::Type)
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
