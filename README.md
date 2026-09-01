# LMDB.jl

[![CI](https://github.com/JuliaDatabases/LMDB.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaDatabases/LMDB.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/JuliaDatabases/LMDB.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaDatabases/LMDB.jl)
[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaDatabases.github.io/LMDB.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaDatabases.github.io/LMDB.jl/dev)

Julia bindings for [LMDB](http://www.lmdb.tech/doc/), the Lightning
Memory-Mapped Database. LMDB is an embedded, memory-mapped, ACID key-value
store developed by Symas for OpenLDAP. It persists to disk while reading
at near in-memory speeds.

LMDB 1.0 changed the on-disk file format. Databases created by LMDB 0.9
must be exported with a 0.9 `mdb_dump` and imported with a 1.0 `mdb_load`;
LMDB 1.0 does not open 0.9 database files directly.

```julia
using Pkg; Pkg.add("LMDB")
```

## Using LMDB.jl

LMDB.jl exposes the same database through three surfaces:

- High-level interface: `LMDBDict <: AbstractDict`, an
  `AbstractDict{K,V}` over a single LMDB file. Standard library
  machinery (`merge!`, `filter!`, `pairs`, iteration, …) works out
  of the box. Reach for this when you want a persistent `Dict`.
- Julia wrappers: `LMDB.Environment`, `LMDB.Transaction`,
  `LMDB.Database`, `LMDB.Cursor`. Julia-shaped wrappers around
  handles, transactions, and cursors, with finalizers, `do`-block
  forms, and so on. Use these when you want explicit transactions.
- C API: `LMDB.mdb_*` and `LMDB.MDB_*`. Raw `ccall` bindings and
  status-code constants. Use this when the Julia wrappers don't expose
  a particular API or you want to inspect status codes directly.

### `LMDBDict`

```julia
using LMDB
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
d["beta/x"] = Float32[10, 11]
d["beta/y"] = Float32[12, 13]

@show d["alpha"]
@show haskey(d, "alpha"), haskey(d, "missing")  # (true, false)
@show length(d)                                  # 3
for (k, v) in d
    @show k, v
end
@show LMDB.scan_keys(d, prefix = "beta/")       # ["beta/x", "beta/y"]
@show LMDB.list_dirs(d)                         # ["alpha", "beta/"]
close(d)
```

### Julia wrappers

```julia
using LMDB

LMDB.Environment("/tmp/mydb"; mapsize = 1<<30, maxreaders = 510,
                              flags   = LMDB.MDB_NOTLS | LMDB.MDB_NORDAHEAD) do env
    LMDB.Transaction(env) do txn                       # auto-commits/aborts
        LMDB.Database(txn) do dbi
            put!(txn, dbi, "k1", "hello")
            put!(txn, dbi, "k2", "world")

            @show LMDB.get(txn, dbi, "k1", String, nothing)
            @show LMDB.get(txn, dbi, "missing", String, "default")
            @show LMDB.stat(txn, dbi).entries
        end
    end

    # Decode every key and value visited by the cursor.
    LMDB.Transaction(env; flags = LMDB.MDB_RDONLY) do txn
        LMDB.Database(txn) do dbi
            LMDB.Cursor(txn, dbi) do cur
                LMDB.walk(cur, String, String) do k, v
                    println(k, " => ", v)
                end
            end
        end
    end
end
```

The package decodes `String`, `Vector{T}` for any bitstype `T`, and Base's
fixed-width primitive reads. To add a representation, define
`Base.read(io::IO, ::Type{T})`; it will be used by
`LMDB.get`, `LMDB.walk(f, cur, K, V)`, and the cursor accessors
`LMDB.key`/`LMDB.value`/`LMDB.item`.

For a missing-key tolerant lookup, prefer
`LMDB.get(txn, dbi, key, T, default)` over `try`/`catch` on `LMDBError`:

```julia
v = LMDB.get(txn, dbi, "missing", String, nothing)
if v === nothing
    # treat as missing
end
```

### C API bindings

The bindings are `LMDB.mdb_*`; constants like `LMDB.MDB_NOTLS` and
`LMDB.MDB_NOTFOUND` are available under the `LMDB` prefix. Status-returning
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

# Inspect a raw status code:
ret = LMDB.unchecked_mdb_env_open(env, "/path/that/does/not/exist",
                                  Cuint(0), LMDB.mode_t(0o644))
ret == 0 || @show LMDB.LMDBError(ret)
LMDB.mdb_env_close(env)
```

## Reference

- LMDB upstream: <https://github.com/LMDB/lmdb>
- LMDB API docs: <http://www.lmdb.tech/doc/>
- LMDB 1.0 upgrade notes: <http://www.lmdb.tech/doc/upgrading.html>
