export Cursor,
       seek!, seek_last!, seek_range!, next!, prev!,
       seek_first_dup!, seek_last_dup!,
       next_dup!, prev_dup!, next_nodup!, prev_nodup!
@public walk, transaction, database, key, value, item

"""
A handle to a cursor structure for navigating through a database.

A `Cursor` keeps references to its parent `Transaction` and `DBI`, both
to expose them via `transaction(cur)` / `database(cur)` and to keep the
txn alive under GC. The cursor's finalizer closes any still-open handle.
"""
mutable struct Cursor
    handle::Ptr{MDB_cursor}
    txn::Transaction
    dbi::DBI
end

Base.unsafe_convert(::Type{Ptr{MDB_cursor}}, c::Cursor) = c.handle

"Check if cursor is open"
isopen(cur::Cursor) = cur.handle != C_NULL

"""
    Cursor(txn::Transaction, dbi::DBI) -> Cursor

Open a cursor over `dbi` inside `txn`. The cursor is freed by its
finalizer if `close` isn't called explicitly.
"""
function Cursor(txn::Transaction, dbi::DBI)
    cur_ptr_ref = Ref{Ptr{MDB_cursor}}(C_NULL)
    mdb_cursor_open(txn, dbi, cur_ptr_ref)
    cur = Cursor(cur_ptr_ref[], txn, dbi)
    finalizer(close, cur)
    return cur
end

"""
    Cursor(f::Function, txn::Transaction, dbi::DBI) -> result

`do`-block form: open a cursor, run `f(cur)`, close on the way out.
Returns whatever `f` returns.
"""
function Cursor(f::Function, txn::Transaction, dbi::DBI)
    cur = Cursor(txn, dbi)
    try
        f(cur)
    finally
        close(cur)
    end
end

"Close a cursor. Idempotent."
function close(cur::Cursor)
    cur.handle == C_NULL && return
    # Per `lmdb.h`, write-txn cursors are freed by the parent txn's
    # commit/abort, and `mdb_cursor_close` afterwards is undefined. For
    # read-txn cursors, the txn handle is required to still be valid.
    # If the parent txn is already finalised in the wrapper, drop the
    # handle without calling into LMDB.
    isopen(cur.txn) || (cur.handle = C_NULL; return)
    mdb_cursor_close(cur)
    cur.handle = C_NULL
    return
end

"Renew a cursor"
function renew(txn::Transaction, cur::Cursor)
    mdb_cursor_renew(txn, cur)
end

"Return the cursor's transaction."
transaction(cur::Cursor) = cur.txn

"Return the cursor's database."
database(cur::Cursor) = cur.dbi

Base.show(io::IO, cur::Cursor) =
    print(io, "Cursor(", isopen(cur) ? "open" : "closed", ")")


# Fill `dst` with the MDB_val that the cconvert/unsafe_convert ladder
# in `common.jl` would build for `k`. `k`'s storage must outlive the
# eventual ccall (use `GC.@preserve`); the pointer baked into `dst`
# aliases its data.
@inline function fill_mdbval!(dst::Ref{MDB_val}, k)
    arg = Base.cconvert(Ptr{MDB_val}, k)
    dst[] = unsafe_load(Base.unsafe_convert(Ptr{MDB_val}, arg))
    return arg
end

# Position the cursor with `op`. Returns `true` on success, `false` on
# `MDB_NOTFOUND`. Throws on other errors. `key_ref` is used both to feed
# the search key in (for SET_KEY / SET_RANGE) and to receive the matched
# key on the way out.
@inline function cursor_seek!(cur::Cursor, key_ref::Ref{MDB_val},
                               val_ref::Ref{MDB_val}, op::MDB_cursor_op,
                               searchkey)
    if searchkey === nothing
        ret = unchecked_mdb_cursor_get(cur, key_ref, val_ref, op)
    else
        held = fill_mdbval!(key_ref, searchkey)
        ret = GC.@preserve held unchecked_mdb_cursor_get(cur, key_ref, val_ref, op)
    end
    ret == MDB_NOTFOUND && return false
    iszero(ret) || throw(LMDBError(ret))
    return true
end

"""
    seek!(cur::Cursor, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Position the cursor at the first entry. Returns the key as `T`, or `nothing`
if the database is empty. Wraps `MDB_FIRST`.
"""
function seek!(cur::Cursor, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_FIRST, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    seek!(cur::Cursor, key, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Position the cursor at the entry whose key exactly equals `key`. Returns the
matched key as `T`, or `nothing` if no such entry exists. Wraps `MDB_SET_KEY`.
"""
function seek!(cur::Cursor, searchkey, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_SET_KEY, searchkey) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    seek_last!(cur::Cursor, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Position the cursor at the last entry. Returns the key as `T`, or `nothing`
if the database is empty. Wraps `MDB_LAST`.
"""
function seek_last!(cur::Cursor, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_LAST, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    seek_range!(cur::Cursor, key, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Position the cursor at the smallest key `>= key`. Returns the matched key as
`T`, or `nothing` if no such entry exists. Wraps `MDB_SET_RANGE`.
"""
function seek_range!(cur::Cursor, searchkey, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_SET_RANGE, searchkey) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    next!(cur::Cursor, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Advance the cursor by one entry. Returns the new key as `T`, or `nothing` if
the cursor moved past the last entry. Wraps `MDB_NEXT`.
"""
function next!(cur::Cursor, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_NEXT, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    prev!(cur::Cursor, ::Type{T}=Vector{UInt8}) -> Union{T,Nothing}

Move the cursor back by one entry. Returns the new key as `T`, or `nothing`
if the cursor moved past the first entry. Wraps `MDB_PREV`.
"""
function prev!(cur::Cursor, ::Type{T}=Vector{UInt8}) where T
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_PREV, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), T)
end

"""
    key(cur::Cursor, ::Type{K}=Vector{UInt8}) -> K

Return the key at the cursor's current position, decoded as `K`. Wraps
`MDB_GET_CURRENT`. Throws if the cursor is not positioned.
"""
function key(cur::Cursor, ::Type{K}=Vector{UInt8}) where K
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    mdb_cursor_get(cur, key_ref, val_ref, MDB_GET_CURRENT)
    return Base.read(MDBValueIO(key_ref[]), K)
end

"""
    value(cur::Cursor, ::Type{V}=Vector{UInt8}) -> V

Return the value at the cursor's current position, decoded as `V`. Wraps
`MDB_GET_CURRENT`. Throws if the cursor is not positioned.
"""
function value(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    mdb_cursor_get(cur, key_ref, val_ref, MDB_GET_CURRENT)
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    item(cur::Cursor, ::Type{K}=Vector{UInt8}, ::Type{V}=Vector{UInt8}) -> Pair{K,V}

Return the (key => value) pair at the cursor's current position. Wraps
`MDB_GET_CURRENT`.
"""
function item(cur::Cursor, ::Type{K}=Vector{UInt8}, ::Type{V}=Vector{UInt8}) where {K,V}
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    mdb_cursor_get(cur, key_ref, val_ref, MDB_GET_CURRENT)
    return Base.read(MDBValueIO(key_ref[]), K) => Base.read(MDBValueIO(val_ref[]), V)
end

"""
    seek_first_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) -> Union{V,Nothing}

Position at the first duplicate of the cursor's current key. Returns the
value as `V`, or `nothing` if the current entry has no duplicates. Wraps
`MDB_FIRST_DUP`. Only meaningful in `MDB_DUPSORT` databases.
"""
function seek_first_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_FIRST_DUP, nothing) || return nothing
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    seek_last_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) -> Union{V,Nothing}

Position at the last duplicate of the cursor's current key. Returns the
value as `V`, or `nothing` if the current entry has no duplicates. Wraps
`MDB_LAST_DUP`.
"""
function seek_last_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_LAST_DUP, nothing) || return nothing
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    next_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) -> Union{V,Nothing}

Advance to the next duplicate of the current key. Returns the new value
as `V`, or `nothing` if there are no more duplicates of this key. Wraps
`MDB_NEXT_DUP`.
"""
function next_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_NEXT_DUP, nothing) || return nothing
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    prev_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) -> Union{V,Nothing}

Move to the previous duplicate of the current key. Returns the new value
as `V`, or `nothing` if there are no earlier duplicates. Wraps
`MDB_PREV_DUP`.
"""
function prev_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_PREV_DUP, nothing) || return nothing
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    next_nodup!(cur::Cursor, ::Type{K}=Vector{UInt8}) -> Union{K,Nothing}

Advance to the first entry of the next key, skipping any remaining duplicates
of the current key. Returns the new key as `K`, or `nothing` past the last
key. Wraps `MDB_NEXT_NODUP`.
"""
function next_nodup!(cur::Cursor, ::Type{K}=Vector{UInt8}) where K
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_NEXT_NODUP, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), K)
end

"""
    prev_nodup!(cur::Cursor, ::Type{K}=Vector{UInt8}) -> Union{K,Nothing}

Move to the last entry of the previous key. Returns the new key as `K`, or
`nothing` past the first key. Wraps `MDB_PREV_NODUP`.
"""
function prev_nodup!(cur::Cursor, ::Type{K}=Vector{UInt8}) where K
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_PREV_NODUP, nothing) || return nothing
    return Base.read(MDBValueIO(key_ref[]), K)
end

"""
    walk(f, cur::Cursor; from = nothing)

Walk every entry the cursor visits, calling
`f(key_ref::Ref{MDB_val}, val_ref::Ref{MDB_val})` once per entry. Iteration
starts at the first key (`MDB_FIRST`) when `from === nothing`, otherwise at
the smallest key `>= from` (`MDB_SET_RANGE`).

Iteration stops when `f` returns `false` (any other return value, including
`nothing`, continues). Inside `f`, `key_ref[]` and `val_ref[]` point into
LMDB-owned memory and are valid only for the duration of the surrounding
transaction; copy out anything you want to retain.
"""
function walk(f, cur::Cursor; from = nothing)
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    if from === nothing
        ret = unchecked_mdb_cursor_get(cur, key_ref, val_ref, MDB_FIRST)
    else
        held = fill_mdbval!(key_ref, from)
        ret = GC.@preserve held unchecked_mdb_cursor_get(cur, key_ref, val_ref,
                                                          MDB_SET_RANGE)
    end
    while iszero(ret)
        # Returning `false` from the callback halts iteration; any other
        # return (including `nothing`) continues.
        f(key_ref, val_ref) === false && return
        ret = unchecked_mdb_cursor_get(cur, key_ref, val_ref, MDB_NEXT)
    end
    ret == MDB_NOTFOUND && return
    throw(LMDBError(ret))
end

"""
    walk(f, cur::Cursor, ::Type{K}, ::Type{V}=K; from = nothing)

Typed overload of `walk` mirroring the `tryget(txn, dbi, key, T)` /
`key(cur, T)` / `seek!(cur, key, T)` shape used elsewhere in the Julia wrappers.
Decodes each key and value through `read(::MDBValueIO, K)` /
`read(::MDBValueIO, V)` before passing them to `f(k::K, v::V)`. Same
stop contract as the raw form: `f` returning `false` halts iteration.

Define a custom `Base.read(io::LMDB.MDBValueIO, ::Type{T})` to control
what gets decoded (for example, a `(atime, size)` tuple from a framed
value, or a zero-copy view). This is the iteration counterpart to
`tryget(..., T)`.
"""
function walk(f, cur::Cursor, ::Type{K}, ::Type{V} = K;
              from = nothing) where {K, V}
    walk(cur; from) do k_ref, v_ref
        f(Base.read(MDBValueIO(k_ref[]), K), Base.read(MDBValueIO(v_ref[]), V))
    end
end

"""Store by cursor.

This function stores key/data pairs into the database. The cursor is positioned at the new item, or on failure usually near it.
"""
function put!(cur::Cursor, key, val; flags::Integer = zero(Cuint))
    mdb_cursor_put(cur, key, val, Cuint(flags))
end

"""
    delete!(cur::Cursor; flags=0)

Delete the entry the cursor is currently positioned at. Throws
`LMDBError` if the cursor is not on a live entry. LMDB returns `EINVAL`
rather than `MDB_NOTFOUND`, so the Bool/idempotent shape used by
`delete!(txn, dbi, key)` doesn't apply here. Position the cursor first
with `seek!` or `next!` if you need to recover from a missing entry.

After a successful delete, LMDB advances the cursor to the next entry.
"""
function delete!(cur::Cursor; flags::Integer = zero(Cuint))
    mdb_cursor_del(cur, Cuint(flags))
    return
end

"Return count of duplicates for current key"
function count(cur::Cursor)
    countp = Ref(Csize_t(0))
    mdb_cursor_count(cur, countp)
    return Int(countp[])
end
