# Databases

```@meta
CurrentModule = LMDB
```

A `Database` is a handle to one B-tree inside an environment. By default an
env has a single anonymous database (the "main DB"); pass `maxdbs > 0`
to `Environment` to support multiple named sub-databases.

## Opening a Database

```julia
dbi = Database(txn)                      # main (unnamed) DB
dbi = Database(txn, "users")             # named sub-DB; needs maxdbs >= 1
dbi = Database(txn, "edges"; flags = LMDB.MDB_CREATE | LMDB.MDB_DUPSORT)
```

The do-block form closes the Database on the way out:

```julia
Database(txn, "users") do dbi
    put!(txn, dbi, "1", "Ada")
end
```

In practice you'll rarely *want* to close a Database handle explicitly. The
env owns it, and `mdb_dbi_close` is documented as rarely useful. The
env's finalizer cascades through any open Database handles.

## Database flags

`flags` accepts a bitwise-or of:

| flag | meaning |
|------|---------|
| `MDB_CREATE` | create the named DB if it doesn't exist |
| `MDB_REVERSEKEY` | compare keys back-to-front (suffix-sorted) |
| `MDB_INTEGERKEY` | keys are native-endian integers, sorted numerically |
| `MDB_DUPSORT` | allow multiple values per key, sorted; see [Duplicate-sort databases](@ref) |
| `MDB_DUPFIXED` | (DUPSORT) all duplicates have the same byte size |
| `MDB_INTEGERDUP` | (DUPSORT) duplicates are native-endian integers |
| `MDB_REVERSEDUP` | (DUPSORT) compare duplicates back-to-front |

## Reads

Every read takes a value-type parameter `T`. The two shapes are:

```julia
get(txn, dbi, key, T)               # throws LMDBError(MDB_NOTFOUND) on miss
get(txn, dbi, key, T, default)      # returns `default` on miss
```

`T` is anything `read(::LMDB.MDBValueIO, ::Type{T})` knows how to
decode: `String`, `Vector{E}` for any bitstype `E`, or any bitstype
scalar.

```julia
get(txn, dbi, "name", String, nothing)              # → Union{String, Nothing}
get(txn, dbi, key,    Vector{Float32}, nothing)     # → Union{Vector{Float32}, Nothing}
get(txn, dbi, key,    UInt64,         zero(UInt64)) # → UInt64
```

The default-form `get` inspects the raw status code and swallows
`MDB_NOTFOUND` without throwing.

## Writes

```julia
put!(txn, dbi, key, val)
put!(txn, dbi, key, val; flags = LMDB.MDB_NOOVERWRITE)
delete!(txn, dbi, key)                       # → Bool: true if removed
delete!(txn, dbi, key, val)                  # DUPSORT: delete one specific dup
replace!(txn, dbi, key, val)                 # atomic put-and-return-old
pop!(txn, dbi, key, T)                       # atomic get-and-delete
```

Useful write flags:

| flag | meaning |
|------|---------|
| `MDB_NOOVERWRITE` | fail with `MDB_KEYEXIST` if `key` is already present |
| `MDB_NODUPDATA` | (DUPSORT) fail if the `(key, val)` pair already exists |
| `MDB_APPEND` | append; only valid if the new key sorts after every existing key. Much faster for sorted bulk loads |

```julia
# Bulk import in sorted order:
Transaction(env) do txn
    Database(txn) do dbi
        for (k, v) in sorted_pairs
            put!(txn, dbi, k, v; flags = LMDB.MDB_APPEND)
        end
    end
end
```

`replace!` and `pop!` do the read-modify pair inside the same
transaction, so there is no time-of-check / time-of-use gap.

## `put_reserved!`: write directly into the mmap

When the value is large or assembled from multiple sources, you can
skip the intermediate `Vector{UInt8}` round-trip and write straight
into the LMDB-allocated page:

```julia
put_reserved!(txn, dbi, key, sizeof(header) + length(payload)) do buf
    unsafe_store!(Ptr{Header}(pointer(buf)), header)
    copyto!(buf, sizeof(header) + 1, payload, 1, length(payload))
end
```

`buf` is an `unsafe_wrap` over the LMDB write buffer. It is only valid
inside the callback, and only inside the surrounding write txn; don't
escape it.

`put_reserved!` is the equivalent of heed's `Database::put_reserved`.
It is incompatible with DUPSORT.

## Stats

```julia
s = stat(txn, dbi)
@show s.entries, s.depth, s.leaf_pages, s.psize

# rough on-disk byte count:
live = (s.branch_pages + s.leaf_pages + s.overflow_pages) * s.psize
```

## Dropping a database

```julia
LMDB.drop(txn, dbi)                 # empty the DB (handle still valid)
LMDB.drop(txn, dbi; delete = true)  # delete the DB and close the handle
```

For named sub-DBs, `delete = true` removes the entry from the env's
main DB. For the main DB itself, `delete = true` is treated as
`delete = false`, since LMDB cannot delete its own root.
