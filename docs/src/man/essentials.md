# Essentials

```@meta
CurrentModule = LMDB
```

After importing LMDB.jl, you can immediately query the bundled library:

```julia-repl
julia> using LMDB

julia> LMDB.version()
(v"0.9.33", "LMDB 0.9.33: (May 21, 2024)")
```

## A complete example

The easiest entry point is the [`LMDBDict`](@ref), a persistent
`AbstractDict{K,V}` backed by a single LMDB environment:

```julia
using LMDB

d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
d["beta/x"] = Float32[10, 11]

@show d["alpha"]            # [1.0, 2.0, 3.0]
@show haskey(d, "alpha")    # true
@show length(d)             # 2

for (k, v) in d
    @show k, v
end

close(d)
```

Behind the scenes this opens an `Environment` with `MDB_NOTLS` (so
multiple read transactions can coexist on a single thread) and a single
default `DBI`. Type conversions happen automatically — anything the
`MDBValue` constructor accepts (`String`, `Vector{T}` of bitstype `T`,
or any bitstype scalar) can be stored.

## The three layers

LMDB.jl is organised in layers. The same database can be accessed at any
of them, depending on what you need:

```
┌──────────────────────────────────────────────────────────────────┐
│  High-level abstractions — LMDBDict <: AbstractDict{K,V}         │
│           "I want a persistent Dict."                            │
├──────────────────────────────────────────────────────────────────┤
│  Julia API — Environment, Transaction, DBI, Cursor               │
│           Julian wrappers with finalizers and parent refs.       │
│           The recommended surface for most code.                 │
├──────────────────────────────────────────────────────────────────┤
│  C API — mdb_*, MDB_*, unchecked_mdb_*                           │
│           @ccall bindings; status-returning ones auto-throw      │
│           and have `unchecked_*` companions. `MDBValue`,         │
│           `MDBArg`, and `MDBValueIO` glue Julia values to        │
│           `Ptr{MDB_val}` and let custom decoders plug in via     │
│           `Base.read(io, T)`.                                    │
└──────────────────────────────────────────────────────────────────┘
```

The recommended progression is:

1. Start with the [Dictionary interface](@ref) until you need
   transactional grouping or zero-copy reads.
2. Drop to [Environments](@ref) → [Transactions](@ref) →
   [Databases](@ref) → [Cursors](@ref) for explicit lifetimes
   and fine-grained control.
3. Reach for the [Low-level bindings](@ref) only when integrating
   with a custom data layout or when the wrappers introduce overhead
   you can't afford.

## Resource lifecycle

Each Julia-API handle type wraps a raw LMDB pointer in a `mutable struct`
with a finalizer:

| handle | finalizer | parent ref |
|--------|-----------|------------|
| `Environment` | `close` (`mdb_env_close`) | – |
| `Transaction` | `abort` (`mdb_txn_abort`) | `Environment` |
| `Cursor` | `close` (`mdb_cursor_close`) | `Transaction`, `DBI` |
| `LMDBDict` | `close` env + dbi | – |

Parent references pin the lifetime: a `Cursor` keeps its `Transaction`
alive, which keeps its `Environment` alive. All cleanup operations
(`close`, `commit`, `abort`) are idempotent — calling them twice (or
on a never-opened handle) is a silent no-op. This means abandoned write
txns (e.g. from a `for … break` over an `LMDBDict`, or any error path)
are eventually reclaimed when GC runs.

For most call sites the do-block constructors are the simplest correct
shape:

```julia
environment("/tmp/mydb"; flags = MDB_NOTLS) do env
    start(env) do txn
        open(txn) do dbi
            put!(txn, dbi, "k", "v")
        end
    end                       # commits on success, aborts on throw
end                           # closes env
```

## Errors

Every LMDB-internal error surfaces as an `LMDBError`:

```julia
try
    LMDB.get(txn, dbi, "missing", String)
catch e
    e isa LMDBError && is_notfound(e) || rethrow()
    # treat as missing
end
```

Common branches have helpers (`is_notfound`, `is_keyexist`,
`is_map_full`); rarer codes can be matched against `LMDB.MDB_*`
constants directly. See [Errors](@ref API-Errors) for the full list.

For the dominant "missing key" case, prefer the no-throw paths:
[`tryget(txn, dbi, key, T)`](@ref tryget) returns `nothing` on miss,
and `get(txn, dbi, key, T, default)` falls back to `default`.
