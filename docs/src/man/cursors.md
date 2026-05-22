# Cursors

```@meta
CurrentModule = LMDB
```

A `Cursor` is a positioned iterator over a `DBI`. Use it for ordered
scans, range queries, or to amortise the per-lookup overhead of
`mdb_get` across many keys.

## Opening a cursor

```julia
Transaction(env; flags = LMDB.MDB_RDONLY) do txn
    DBI(txn) do dbi
        Cursor(txn, dbi) do cur
            # use cur
        end
    end
end
```

A cursor is bound to its transaction; closing the txn invalidates the
cursor. The cursor's finalizer is idempotent, so a still-open cursor is
reclaimed when GC visits it.

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
    DBI(txn) do dbi
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
# Untyped: receives Ref{MDB_val} pairs (zero-copy, mmap pointers)
walk(cur) do k_ref, v_ref
    kv = k_ref[]; vv = v_ref[]
    # kv.mv_data / vv.mv_data are mmap pointers, valid in this scope
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

Use the untyped form when you want to inspect raw byte sizes, copy
slices, or feed a custom decoder. The data pointers are into LMDB's
mmap and are valid only inside the callback (and only for the
surrounding txn). The typed form is the iteration analogue of
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

`count(cur)` returns the number of duplicate values for the current
key (1 in non-DUPSORT databases).

## Custom value decoding

`get`, `key`, `value`, `item`, and typed `walk` all funnel
through `Base.read(io::IO, ::Type{T})` against an
[`MDBValueIO`](@ref LMDB.MDBValueIO). The defaults cover Base's
primitive numeric types (`Int8`/…/`Float64`, `Bool`, `Char`, `Ptr`),
`String`, and (added by this package) `Vector{E}` for any bitstype `E`.

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

`MDBValueIO <: IO`, so all the usual `Base` IO primitives work on it:
`position`, `seek`, `skip`, `read(io, n::Integer)`, `read(io, T)`,
`read!(io, A)`, `bytesavailable`, `eof`. Structured framed-value
decoders end up reading like any other Julia binary parser, and the
same decoder works against any byte source. This is the analogue of
heed's `BytesDecode<'txn>` trait, expressed through Julia's existing IO
extension point instead of a bespoke trait.

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
