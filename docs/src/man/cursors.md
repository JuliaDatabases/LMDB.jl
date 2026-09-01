# Cursors

```@meta
CurrentModule = LMDB
```

A `Cursor` is a positioned iterator over a `Database`. Use it for ordered
scans, range queries, or to amortise the per-lookup overhead of
`mdb_get` across many keys.

## Opening a cursor

```julia
Transaction(env; flags = LMDB.MDB_RDONLY) do txn
    Database(txn) do dbi
        Cursor(txn, dbi) do cur
            # use cur
        end
    end
end
```

A cursor is bound to its transaction. A read-only cursor must still be closed
after its transaction ends; the wrapper's `close` and finalizer handle both
read and write cursor lifetimes.

## Navigation

Each navigation function repositions the cursor and returns the new
key, or `nothing` if the move would step past the end:

```julia
seek!(cur)              # MDB_FIRST     first entry
seek_last!(cur)         # MDB_LAST      last entry
seek!(cur, key)         # MDB_SET_KEY   exact key match
seek_range!(cur, key)   # MDB_SET_RANGE smallest key ≥ `key`
next!(cur)              # MDB_NEXT
prev!(cur)              # MDB_PREV
```

Each accepts an optional key-type parameter `T` (default `Vector{UInt8}`):

```julia
seek!(cur, String)             # decode the resulting key as String
seek_range!(cur, "users/", String)
```

## Reading at the current position

```julia
LMDB.key(cur, K)              # current key, decoded as K
LMDB.value(cur, V)            # current value, decoded as V
LMDB.item(cur, K, V)          # Pair{K, V}
```

The defaults are `K = V = Vector{UInt8}`.

```julia
seek_range!(cur, "users/", String) === nothing && return
@show LMDB.key(cur, String), LMDB.value(cur, String)
```

## Range scans

A typical pattern for "all keys with a given prefix":

```julia
prefix = "users/"
Transaction(env; flags = LMDB.MDB_RDONLY) do txn
    Database(txn) do dbi
        Cursor(txn, dbi) do cur
            k = seek_range!(cur, prefix, String)
            while k !== nothing && startswith(k, prefix)
                v = LMDB.value(cur, String)
                handle(k, v)
                k = next!(cur, String)
            end
        end
    end
end
```

For the same pattern one level up (already wrapped, returns a
`Vector{Pair}`), use [`LMDB.scan(d; prefix)`](@ref LMDB.scan) on an
`LMDBDict`.

## [Bulk walk: zero-copy iteration](@id man-cur-walk)

`walk` runs a callback over every entry the cursor visits. It exists in
two shapes:

```julia
# Untyped: receives reused Ref{MDB_val} pairs
walk(cur) do k_ref, v_ref
    kv = k_ref[]; vv = v_ref[]
    do_something(kv.mv_size, vv.mv_size)
end

# Typed: runs each ref through `read(MDBValueIO, K)` / `read(MDBValueIO, V)`
walk(cur, String, Vector{UInt8}) do k::String, v::Vector{UInt8}
    println(k, " => ", length(v), " bytes")
end
```

Pass `from = key` to start at the smallest entry `≥ key` (i.e.
`MDB_SET_RANGE`); the default is to start at `MDB_FIRST`.

The callback can return `false` to stop iteration; any other return
(including `nothing`) continues.

Use the untyped form to inspect raw byte sizes or copy bytes. The `Ref`s are
reused on the next iteration, and LMDB invalidates returned data after an
update or when the transaction ends. The typed form is the iteration analogue of
`get(..., T, nothing)` and works for any `T` for which
`Base.read(io::IO, ::Type{T})` (or
`Base.read(io::LMDB.MDBValueIO, ::Type{T})`) is defined. See
[Custom value decoding](@ref).

## Cursor mutation

Inside a write transaction, a cursor can put or delete at its current
position:

```julia
put!(cur, key, val)
put!(cur, key, val; flags = LMDB.MDB_NOOVERWRITE)
delete!(cur)
delete!(cur; flags = LMDB.MDB_NODUPDATA)
```

`count(cur)` returns the number of values at the current key in an
`MDB_DUPSORT` database.

## Custom value decoding

`get`, `key`, `value`, `item`, and typed `walk` decode through
[`MDBValueIO`](@ref LMDB.MDBValueIO). The package handles `String` and
`Vector{E}` for bitstype `E`; Base supplies fixed-width primitive reads.

For everything else, including `isbitstype` structs and framed
values, define a single `Base.read` method on the abstract `IO`.

```julia
struct PrefixedBlob end

function Base.read(io::IO, ::Type{PrefixedBlob})
    bytesavailable(io) < 8 && return UInt8[]
    skip(io, 8)
    return read(io, Vector{UInt8})
end

# now usable everywhere a value-type parameter is accepted:
LMDB.get(txn, dbi, key, PrefixedBlob, nothing)
walk(cur, String, PrefixedBlob) do k, blob
    handle(k, blob)
end
```

`MDBValueIO <: IO` supports the IO operations needed by binary decoders:
`position`, `seek`, `skip`, `read(io, n::Integer)`, `read(io, T)`,
`read!(io, A)`, `bytesavailable`, and `eof`. A decoder defined for `IO` can
also work with other byte sources.

## Reset and renew

For long-running readers, opening one cursor per snapshot can be
expensive. Park the txn with [`reset`](@ref Base.reset(::LMDB.Transaction))
and refresh both the txn and the cursor with `renew(txn, cur)`:

```julia
txn = Transaction(env; flags = LMDB.MDB_RDONLY)
cur = Cursor(txn, dbi)
while running
    ...                # use cur
    reset(txn)
    renew(txn)
    renew(txn, cur)
end
abort(txn)
```
