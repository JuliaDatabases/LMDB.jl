# Cursors

```@meta
CurrentModule = LMDB
```

A `Cursor` is a positioned iterator over a `DBI`. Use it for ordered
scans, range queries, and any time you want to amortise the per-lookup
overhead of `mdb_get` across many keys.

## Opening a cursor

```julia
start(env; flags = MDB_RDONLY) do txn
    open(txn) do dbi
        open(txn, dbi) do cur
            # use cur
        end
    end
end
```

A cursor is bound to its transaction; closing the txn invalidates the
cursor. The cursor's finalizer is idempotent, so a still-open cursor
is reclaimed when GC visits it.

## Navigation

Each navigation function repositions the cursor and returns the new
key, or `nothing` if the move would step past the end:

```julia
seek!(cur)              # MDB_FIRST   — first entry
seek_last!(cur)         # MDB_LAST    — last entry
seek!(cur, key)         # MDB_SET_KEY — exact key match
seek_range!(cur, key)   # MDB_SET_RANGE — smallest key ≥ `key`
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
key(cur, K)                   # current key, decoded as K
value(cur, V)                 # current value, decoded as V
item(cur, K, V)               # Pair{K, V}
```

The defaults are `K = V = Vector{UInt8}`.

```julia
seek_range!(cur, "users/", String) === nothing && return
@show key(cur, String), value(cur, String)
```

## Range scans

A typical pattern for "all keys with a given prefix":

```julia
prefix = "users/"
start(env; flags = MDB_RDONLY) do txn
    open(txn) do dbi
        open(txn, dbi) do cur
            k = seek_range!(cur, prefix, String)
            while k !== nothing && startswith(k, prefix)
                v = value(cur, String)
                handle(k, v)
                k = next!(cur, String)
            end
        end
    end
end
```

For the same pattern *one level up* (already wrapped, returns a
`Vector{Pair}`), use [`LMDB.scan(d; prefix)`](@ref LMDB.scan) on an
`LMDBDict`.

## [Bulk walk — zero-copy iteration](@id man-cur-walk)

`walk` runs a callback over every entry the cursor visits. It exists in
two shapes:

```julia
# Untyped — receives Ref{MDB_val} pairs (zero-copy, mmap pointers)
walk(cur) do k_ref, v_ref
    kv = k_ref[]; vv = v_ref[]
    # kv.mv_data / vv.mv_data are mmap pointers, valid in this scope
    do_something(kv.mv_size, vv.mv_size)
end

# Typed — runs each ref through `read(MDBValueIO, K)` / `read(MDBValueIO, V)`
walk(cur, String, Vector{UInt8}) do k::String, v::Vector{UInt8}
    println(k, " => ", length(v), " bytes")
end
```

Pass `from = key` to start at the smallest entry `≥ key` (i.e.
`MDB_SET_RANGE`); the default is to start at `MDB_FIRST`.

The callback can return `false` to stop iteration; any other return
(including `nothing`) continues.

The untyped form is the right tool when you want to inspect raw byte
sizes, copy slices, or feed a custom decoder — the data pointers are
into LMDB's mmap and are valid only inside the callback (and only for
the surrounding txn). The typed form is the iteration analogue of
`tryget(..., T)` and works for any `T` for which `Base.read(io::IO,
::Type{T})` (or `Base.read(io::LMDB.MDBValueIO, ::Type{T})`) is
defined (see [Custom value decoding](@ref)).

## Cursor mutation

Inside a write transaction, a cursor can put or delete at its current
position:

```julia
put!(cur, key, val)
put!(cur, key, val; flags = MDB_NOOVERWRITE)
delete!(cur)
delete!(cur; flags = MDB_NODUPDATA)
```

`count(cur)` returns the number of duplicate values for the current
key (1 in non-DUPSORT databases).

## Custom value decoding

`tryget` / `get` / `key` / `value` / `item` / typed `walk` all funnel
through `Base.read(io::IO, ::Type{T})` against an
[`MDBValueIO`](@ref LMDB.MDBValueIO). The defaults cover Base's
primitive numeric types (`Int8`/…/`Float64`, `Bool`, `Char`, `Ptr`),
`String`, and (added by this package) `Vector{E}` for any bitstype `E`.

For everything else — including `isbitstype` structs and framed
values — define a single `Base.read` method on the abstract `IO`:

```julia
struct PrefixedBlob end

function Base.read(io::IO, ::Type{PrefixedBlob})
    bytesavailable(io) < 8 && return UInt8[]
    skip(io, 8)
    return read(io, Vector{UInt8})
end

# now usable everywhere a value-type parameter is accepted:
LMDB.tryget(txn, dbi, key, PrefixedBlob)
walk(cur, String, PrefixedBlob) do k, blob
    handle(k, blob)
end
```

`MDBValueIO <: IO` so all the usual `Base` IO primitives — `position`,
`seek`, `skip`, `read(io, n::Integer)`, `read(io, T)`, `read!(io, A)`,
`bytesavailable`, `eof` — work as expected. This makes structured
framed-value decoders read like any other Julia binary parser, and is
the analogue of heed's `BytesDecode<'txn>` trait — but expressed
through Julia's existing IO extension point rather than a bespoke
trait, so the same decoder works against any byte source.

## Reset and renew

For long-running readers, opening one cursor per snapshot can be
expensive. Park the txn with [`reset`](@ref Base.reset(::LMDB.Transaction))
and refresh both the txn and the cursor with `renew(txn, cur)`:

```julia
txn = start(env; flags = MDB_RDONLY)
cur = open(txn, dbi)
while running
    ...                # use cur
    reset(txn)
    renew(txn)
    renew(txn, cur)
end
abort(txn)
```
