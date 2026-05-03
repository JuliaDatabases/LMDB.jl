# LMDB.jl

[![CI](https://github.com/maleadt/LMDB.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/maleadt/LMDB.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/maleadt/LMDB.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/maleadt/LMDB.jl)
[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://maleadt.github.io/LMDB.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://maleadt.github.io/LMDB.jl/dev)

Julia bindings for [LMDB](http://www.lmdb.tech/doc/), the Lightning
Memory-Mapped Database — an embedded, memory-mapped, ACID key-value
store developed by Symas for OpenLDAP. Small, fast, persisted to disk,
and reads at near in-memory speeds.

```julia
using Pkg; Pkg.add("LMDB")
```

## Three layers

LMDB.jl exposes the same database through three layers, each with a
clear consumer:

- **High-level abstractions** — `LMDBDict <: AbstractDict`, an
  `AbstractDict{K,V}` over a single LMDB file. Standard library
  machinery (`merge!`, `filter!`, `pairs`, iteration, …) works out
  of the box. Reach for this when you want a persistent `Dict`.
- **Julia API** — `Environment`, `Transaction`, `DBI`, `Cursor`. Julian
  wrappers around handles, transactions, and cursors, with finalizers,
  `do`-block forms, and typed reads through the
  [`MDBValueIO`](https://en.wikipedia.org/wiki/Memory-mapped_file)
  extension point. The recommended surface for most code that needs
  explicit transactions.
- **C API** — `LMDB.mdb_*` and `LMDB.MDB_*`. Raw `ccall` bindings and
  status-code constants. Status-returning functions auto-throw
  `LMDBError` on a non-zero return; an `unchecked_*` companion is
  available where the caller needs to inspect the raw status (for
  example, branching on `MDB_NOTFOUND`).

### High-level abstractions — `LMDBDict`

```julia
using LMDB
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
d["beta/x"] = Float32[10, 11]
d["beta/y"] = Float32[12, 13]

@show d["alpha"]
@show haskey(d, "alpha"), haskey(d, "missing")  # missing throws KeyError
@show length(d)                                  # 3
for (k, v) in d
    @show k, v
end
@show LMDB.scan_keys(d, prefix = "beta/")       # ["beta/x", "beta/y"]
@show LMDB.list_dirs(d)                         # ["alpha", "beta/"]
close(d)
```

Constructor kwargs: `mapsize`, `readers`, `dbs`, `readonly`, `rdahead`.
The env is opened with `MDB_NOTLS` so multiple read txns can coexist
on a single thread.

### Julia API — explicit env / txn / cursor

```julia
using LMDB

env = Environment("/tmp/mydb"; mapsize = 1<<30, maxreaders = 510,
                               flags   = MDB_NOTLS | MDB_NORDAHEAD)
try
    start(env) do txn                                  # auto-commits/aborts
        open(txn) do dbi
            put!(txn, dbi, "k1", "hello")
            put!(txn, dbi, "k2", [1.0, 2.0, 3.0])

            @show LMDB.tryget(txn, dbi, "k1", String)
            @show LMDB.get(txn, dbi, "missing", String, "default")
            @show LMDB.stat(txn, dbi).entries
        end
    end

    # Cursor walk over the LMDB-owned mmap (zero-copy access).
    start(env; flags = MDB_RDONLY) do txn
        open(txn) do dbi
            open(txn, dbi) do cur
                LMDB.walk(cur, String, String) do k, v
                    println(k, " => ", v)
                end
            end
        end
    end
finally
    close(env)
end
```

The package decodes `String`, `Vector{T}` for any bitstype `T`, and
the primitive numeric types out of the box. To plug in a custom
representation, define a single `Base.read(io::IO, ::Type{T})` method;
it will be picked up by `tryget` / `get` / `walk(f, cur, K, V)` and
the cursor accessors `key`/`value`/`item`. Status-code matchers live
on `LMDBError`:

```julia
try
    LMDB.get(txn, dbi, "missing", String)
catch e
    e isa LMDBError && LMDB.is_notfound(e) || rethrow()
    # treat as missing
end
```

### C API — raw bindings

The bindings are `LMDB.mdb_*`; constants like `LMDB.MDB_NOTLS` and
`LMDB.MDB_NOTFOUND` are public-but-unexported. Status-returning
bindings have an auto-throwing default and an `unchecked_*` companion:

```julia
import LMDB

env_ref = Ref{Ptr{LMDB.MDB_env}}(C_NULL)
LMDB.mdb_env_create(env_ref)                          # auto-throws on error
env = env_ref[]
LMDB.mdb_env_set_maxreaders(env, Cuint(510))
LMDB.mdb_env_set_mapsize(env, Csize_t(1 << 30))
LMDB.mdb_env_open(env, "/tmp/mydb",
                  LMDB.MDB_NOTLS | LMDB.MDB_NORDAHEAD,
                  LMDB.mode_t(0o644))

# Inspect the raw status code (e.g. for MDB_NOTFOUND):
ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
ret == LMDB.MDB_NOTFOUND && return nothing
ret == 0 || throw(LMDB.LMDBError(ret))
```

## Reference

- LMDB upstream: <https://github.com/LMDB/lmdb>
- LMDB API docs: <http://www.lmdb.tech/doc/>
