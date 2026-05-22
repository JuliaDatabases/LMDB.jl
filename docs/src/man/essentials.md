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
default `DBI`. Type conversion happens automatically for anything the
`MDBValue` constructor accepts: `String`, `Vector{T}` of bitstype `T`,
or any bitstype scalar.

## Picking a surface

LMDB.jl exposes the same database three ways, in increasing order of
control:

- The **high-level interface** ([`LMDBDict`](@ref)) is the
  `AbstractDict{K,V}` surface — start here unless you need
  transactional grouping or zero-copy reads.
- The **Julia wrappers** (`Environment`, `Transaction`, `DBI`,
  `Cursor`) give you explicit lifetimes and fine-grained control with
  finalizers, parent refs, and `do`-block forms. Drop down to these
  via [Environments](@ref) → [Transactions](@ref) →
  [Databases](@ref) → [Cursors](@ref).
- The **C API** (`mdb_*`, `MDB_*`, `unchecked_mdb_*`) is the raw
  `@ccall` surface. `MDBValue`, `MDBArg`, and `MDBValueIO` glue Julia
  values to `Ptr{MDB_val}` and let custom decoders plug in via
  `Base.read(io, T)`. Reach for the [Low-level bindings](@ref) only
  when integrating with a custom data layout or when the wrappers
  introduce overhead you can't afford.

## Resource lifecycle

Each wrapper handle is a `mutable struct` around a raw LMDB pointer,
with a finalizer:

| handle | finalizer | parent ref |
|--------|-----------|------------|
| `Environment` | `close` (`mdb_env_close`) | – |
| `Transaction` | `abort` (`mdb_txn_abort`) | `Environment` |
| `Cursor` | `close` (`mdb_cursor_close`) | `Transaction`, `DBI` |
| `LMDBDict` | `close` env + dbi | – |

Parent references pin the lifetime: a `Cursor` keeps its `Transaction`
alive, which keeps its `Environment` alive. `close`, `commit`, and
`abort` are idempotent: calling them twice, or on a handle that was
never opened, is a silent no-op. So an abandoned write txn — say, from
a `for … break` over an `LMDBDict`, or any error path — gets reclaimed
when GC runs.

The do-block constructors are usually what you want:

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

For the usual "missing key" case, prefer the no-throw paths:
[`tryget(txn, dbi, key, T)`](@ref tryget) returns `nothing` on miss,
and `get(txn, dbi, key, T, default)` falls back to `default`.
