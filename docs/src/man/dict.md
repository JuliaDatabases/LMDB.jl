# Dictionary interface

```@meta
CurrentModule = LMDB
```

`LMDBDict{K,V}` is a persistent `AbstractDict{K,V}` backed by a single
LMDB environment + the default DBI. It is the simplest way to use LMDB
from Julia: open it, treat it like a `Dict`, close it.

## Construction

```julia
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
```

`LMDBDict(path)` without explicit type parameters defaults to
`LMDBDict{String, Vector{UInt8}}`. The path is the directory LMDB will
manage (it must exist; LMDB will create the data files inside it).

Constructor keyword arguments:

| kwarg | default | meaning |
|-------|---------|---------|
| `readonly` | `false` | open with `MDB_RDONLY` |
| `rdahead` | `false` | unset `MDB_NORDAHEAD` (LMDB's default is to read-ahead; LMDB.jl turns it off because cold-page workloads pay for it) |
| `mapsize` | LMDB default (10 MiB) | virtual map size in bytes; the on-disk file may be much smaller |
| `readers` | LMDB default | max concurrent reader slots |
| `dbs` | LMDB default | max named sub-databases |

`MDB_NOTLS` is always set, so a single thread can hold multiple read
transactions. This is required for any interleaved read pattern (e.g.
calling `length(d)` mid-iteration) and for read txns shared between
tasks.

## Storing and retrieving

Anything that round-trips through the package's `MDB_val` glue and
[`MDBValueIO`](@ref LMDB.MDBValueIO) works as a value type — `String`,
`Vector{T}` for any bitstype `T`, and any bitstype scalar (`Int`,
`Float32`, `(Int, UInt32)` `Tuple`, …).

```julia
d = LMDBDict{String, Float64}("/tmp/scores")
d["alpha"] = 1.5
d["beta"]  = 2.0

@show d["alpha"]                # 1.5
@show get(d, "missing", -1.0)   # -1.0
@show haskey(d, "alpha")        # true
@show length(d)                 # 2
```

Missing keys throw `KeyError`, exactly like `Base.Dict`:

```julia-repl
julia> d["nonexistent"]
ERROR: KeyError: key "nonexistent" not found
```

## Iteration

```julia
for (k, v) in d
    println(k, " => ", v)
end
```

Iteration is in **lexicographic key order** — strictly stronger than
`Base.Dict`'s no-order promise. Each `for` loop opens a fresh read
transaction; the txn is committed on normal exit and aborted (via the
`Transaction` finalizer) on early break or throw.

`keys(d)`, `values(d)`, `pairs(d)` are lazy. `collect(d)` materialises
a `Vector{Pair{K,V}}`.

## Mutations

```julia
d["x"]  = 42
delete!(d, "x")        # silent no-op if missing
pop!(d, "x")           # throws KeyError if missing
pop!(d, "x", default)  # returns default if missing
empty!(d)              # drops every entry
```

`delete!` matches `Base.delete!`'s "if any" contract: it returns `d` and
silently no-ops when the key isn't present.

Generic `AbstractDict` operations all kick in for free:

```julia
merge!(d, Dict("a" => 1, "b" => 2))
filter!(((k, v),) -> v > 0, d)
```

## Prefix-scoped scans

For hierarchical key schemes (e.g. `"users/123/name"`), LMDB's
lexicographic order makes prefix scans cheap — they're a single
`MDB_SET_RANGE` plus iteration until the prefix stops matching.

```julia
d = LMDBDict{String, String}("/tmp/tree")
d["users/1/name"]  = "Ada"
d["users/2/name"]  = "Bob"
d["users/2/email"] = "bob@example.com"
d["other"]         = "skip"

LMDB.scan_keys(d, prefix = "users/")
# 3-element Vector{String}:
#  "users/1/name"
#  "users/2/email"
#  "users/2/name"

LMDB.scan(d, prefix = "users/2/")
# 2-element Vector{Pair{String,String}}:
#  "users/2/email" => "bob@example.com"
#  "users/2/name"  => "Bob"
```

For directory-style listings — leaf keys appear as-is, anything with
the separator after the prefix collapses to its first segment:

```julia
LMDB.list_dirs(d, prefix = "")        # ["other", "users/"]
LMDB.list_dirs(d, prefix = "users/")  # ["users/1/", "users/2/"]
```

`LMDB.valuesize(d; prefix)` sums byte sizes — useful for quick storage
audits without `stat`.

## When to drop down

Reach for the explicit Julia API (next chapters) when:

- you need **multi-key atomicity**: a single transaction grouping more
  than one `put!`/`delete!`,
- you want to **stream** without eagerly building a `Vector{Pair{K,V}}`
  (see [Cursors](@ref) and `walk`),
- you need **multiple named databases** in one env (LMDBDict only
  exposes the default unnamed DB),
- you're using `MDB_DUPSORT` (multiple values per key — see
  [Duplicate-sort databases](@ref)),
- or you want zero-copy reads against the mmap.
