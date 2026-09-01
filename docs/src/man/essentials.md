# Essentials

```@meta
CurrentModule = LMDB
```

After importing LMDB.jl, you can immediately query the bundled library:

```julia-repl
julia> using LMDB

julia> LMDB.version()
v"1.0.0"
```

LMDB 1.0 changed the on-disk file format. Databases created by LMDB
0.9 must be exported with a 0.9 `mdb_dump` and imported with a 1.0
`mdb_load`; LMDB 1.0 does not open 0.9 database files directly.

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

This opens an `Environment` with `MDB_NOTLS`, allowing multiple read
transactions on one thread, and uses the main `Database`. Strings, contiguous
arrays of bitstypes, and bitstype scalars can be stored directly.

## Picking a surface

LMDB.jl exposes the same database three ways, in increasing order of
control:

- The high-level interface ([`LMDBDict`](@ref)) is the
  `AbstractDict{K,V}` surface. Start here unless you need
  transactional grouping or zero-copy reads.
- The Julia wrappers (`Environment`, `Transaction`, `Database`,
  `Cursor`) give you explicit lifetimes and fine-grained control with
  finalizers, parent refs, and `do`-block forms. Drop down to these
  via [Environments](@ref) → [Transactions](@ref) →
  [Databases](@ref) → [Cursors](@ref).
- The C API (`mdb_*`, `MDB_*`, `unchecked_mdb_*`) is the raw
  `@ccall` surface. `MDBValue`, `MDBArg`, and `MDBValueIO` glue Julia
  values to `MDB_val` and let custom decoders plug in via
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
| `Cursor` | `close` (`mdb_cursor_close`) | `Transaction`, `Database` |
| `LMDBDict` | `close` env + dbi | – |

Parent references pin the lifetime: a `Cursor` keeps its `Transaction`
alive, which keeps its `Environment` alive. Repeated `close`, `commit`, and
`abort` calls are no-ops. Ending a transaction closes its cursors first.
Finalizers eventually release abandoned handles; use do-blocks for
deterministic cleanup.

The do-block constructors are usually what you want:

```julia
Environment("/tmp/mydb"; flags = LMDB.MDB_NOTLS) do env
    Transaction(env) do txn
        Database(txn) do dbi
            put!(txn, dbi, "k", "v")
        end
    end                       # commits on success, aborts on throw
end                           # closes env
```

## Errors

Checked LMDB calls throw `LMDBError`. For a missing key, prefer the no-throw
path:
`get(txn, dbi, key, T, default)` falls back to `default` (use
`nothing` for the `Union{T,Nothing}` shape).
