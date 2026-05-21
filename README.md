# LMDB.jl

Julia bindings for [LMDB](http://www.lmdb.tech/doc/), the
Lightning Memory-Mapped Database — an embedded, memory-mapped, ACID
key-value store developed by Symas for OpenLDAP. It is small, fast, and
persists to disk while reading at near in-memory speeds.

```julia
using Pkg; Pkg.add("LMDB")
```

## Three layers

LMDB.jl exposes three tiers, each with a clear consumer:

```
Tier 3  LMDBDict           — `AbstractDict` over a single LMDB file.
Tier 2  Environment, …     — Julian wrappers: handles, txns, cursors, dicts.
Tier 1  mdb_*, MDB_*       — raw bindings + status-code constants.
```

Tier 3 is the easy mode. Tier 2 is what most users want. Tier 1 is for
power users who need to integrate with custom data layouts or skip
allocations on hot paths — its functions auto-throw on non-zero status,
and an `unchecked_*` companion is available for callers that need to
inspect the raw status code.

### Tier 3 — `LMDBDict`

A persistent `Dict`-like object backed by one LMDB environment + DBI.

```julia
using LMDB
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
d["beta/x"] = Float32[10, 11]
d["beta/y"] = Float32[12, 13]

@show d["alpha"]
@show haskey(d, "alpha"), haskey(d, "missing")
@show keys(d, prefix = "beta/")           # ["beta/x", "beta/y"]
@show LMDB.list_dirs(d)                   # ["alpha", "beta/"]
close(d)
```

Constructor kwargs: `mapsize`, `readers`, `dbs`, `readonly`, `rdahead`.

### Tier 2 — explicit env / txn / cursor

```julia
using LMDB

env = Environment("/tmp/mydb"; mapsize = 1<<30, maxreaders = 510,
                               flags   = MDB_NOTLS | MDB_NORDAHEAD)
try
    start(env) do txn                                  # auto-commits/aborts
        open(txn) do dbi
            put!(txn, dbi, "k1", "hello")
            put!(txn, dbi, "k2", [1.0, 2.0, 3.0])

            @show LMDB.tryget(txn, dbi, "k1", String)    # "hello"
            @show LMDB.get(txn, dbi, "missing", String, "default")
            @show LMDB.stat(txn, dbi).ms_entries         # 2
        end
    end

    # Cursor walk: zero-copy access to raw MDB_val refs.
    start(env; flags = MDB_RDONLY) do txn
        open(txn) do dbi
            open(txn, dbi) do cur
                LMDB.walk(cur) do k_ref, v_ref
                    println(LMDB.mbd_unpack(String, k_ref))
                end
            end
        end
    end
finally
    close(env)
end
```

Status-code matchers are in `LMDBError`:

```julia
try
    LMDB.get(txn, dbi, "missing", String)
catch e
    e isa LMDBError && LMDB.is_notfound(e) || rethrow()
    # …
end
```

### Tier 1 — raw bindings

The bindings are `LMDB.mdb_*`; constants like `LMDB.MDB_NOTLS`,
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
                  Cushort(0o644))

# Inspect the raw status code (e.g. for MDB_NOTFOUND):
ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
ret == LMDB.MDB_NOTFOUND && return nothing
ret == 0 || throw(LMDB.LMDBError(ret))
```

## Reference

- LMDB upstream: <https://github.com/LMDB/lmdb>
- LMDB API docs: <http://www.lmdb.tech/doc/>
- Julia LMDB.jl issues / PRs: this repository.
