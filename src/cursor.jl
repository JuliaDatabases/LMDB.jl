@public Cursor,
        seek!, seek_last!, seek_range!, next!, prev!,
        seek_first_dup!, seek_last_dup!,
        next_dup!, prev_dup!, next_nodup!, prev_nodup!,
        walk, transaction, database, key, value, item

"""
A cursor for navigating a database. It retains its transaction and database,
and closes a live handle when finalized.
"""
mutable struct Cursor
    handle::Ptr{MDB_cursor}
    txn::Transaction
    dbi::Database
    readonly::Bool
end

Base.unsafe_convert(::Type{Ptr{MDB_cursor}}, c::Cursor) = c.handle

"Return whether the cursor handle is open."
isopen(cur::Cursor) = cur.handle != C_NULL

"""
    Cursor(txn::Transaction, dbi::Database) -> Cursor

Open a cursor over `dbi` in `txn`.
"""
function Cursor(txn::Transaction, dbi::Database)
    cur_ptr_ref = Ref{Ptr{MDB_cursor}}(C_NULL)
    mdb_cursor_open(txn, dbi, cur_ptr_ref)
    txn_flags = Ref{Cuint}()
    mdb_txn_flags(txn, txn_flags)
    cur = Cursor(cur_ptr_ref[], txn, dbi,
                 isflagset(txn_flags[], Cuint(MDB_RDONLY)))
    finalizer(close, cur)
    return cur
end

"""
    Cursor(f::Function, txn::Transaction, dbi::Database) -> result

Open a cursor, call `f`, and close the cursor afterward. Return the result of
`f`.
"""
function Cursor(f::Function, txn::Transaction, dbi::Database)
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
    # Write transactions free their cursors. Read cursors remain allocated after
    # a transaction ends and must be closed before the environment.
    if isopen(cur.txn) || (cur.readonly && isopen(cur.txn.env))
        mdb_cursor_close(cur)
    end
    cur.handle = C_NULL
    return
end

"Renew a read-only cursor for use with `txn`."
function renew(txn::Transaction, cur::Cursor)
    mdb_cursor_renew(txn, cur)
end

"Return the cursor's transaction."
transaction(cur::Cursor) = cur.txn

"Return the cursor's database."
database(cur::Cursor) = cur.dbi

Base.show(io::IO, cur::Cursor) =
    print(io, "Cursor(", isopen(cur) ? "open" : "closed", ")")


# Materialize an input `MDB_val`; the returned carrier must be preserved while
# `dst` is passed to C.
@inline function fill_mdbval!(dst::Ref{MDB_val}, k)
    arg = Base.cconvert(Ref{MDB_val}, k)
    dst[] = unsafe_load(Base.unsafe_convert(Ref{MDB_val}, arg))
    return arg
end

# Return false for `MDB_NOTFOUND`; otherwise update the cursor or throw.
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

Position at the first value of the current key. Return it as `V`, or `nothing`
if there is no current key. Only valid for `MDB_DUPSORT` databases.
"""
function seek_first_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) where V
    key_ref = Ref(MDBValue())
    val_ref = Ref(MDBValue())
    cursor_seek!(cur, key_ref, val_ref, MDB_FIRST_DUP, nothing) || return nothing
    return Base.read(MDBValueIO(val_ref[]), V)
end

"""
    seek_last_dup!(cur::Cursor, ::Type{V}=Vector{UInt8}) -> Union{V,Nothing}

Position at the last value of the current key. Return it as `V`, or `nothing`
if there is no current key. Only valid for `MDB_DUPSORT` databases.
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

Iteration stops when `f` returns `false`; any other value continues. The same
two `Ref`s are reused on each iteration. Consume or copy their contents before
the callback returns. LMDB also invalidates returned data after an update or
when the transaction ends.
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
        f(key_ref, val_ref) === false && return
        ret = unchecked_mdb_cursor_get(cur, key_ref, val_ref, MDB_NEXT)
    end
    ret == MDB_NOTFOUND && return
    throw(LMDBError(ret))
end

"""
    walk(f, cur::Cursor, ::Type{K}, ::Type{V}=K; from = nothing)

Decode each key and value as `K` and `V` before calling `f`. Returning `false`
stops iteration. Define `Base.read(io::IO, ::Type{T})` to add a decoder.
"""
function walk(f, cur::Cursor, ::Type{K}, ::Type{V} = K;
              from = nothing) where {K, V}
    walk(cur; from) do k_ref, v_ref
        f(Base.read(MDBValueIO(k_ref[]), K), Base.read(MDBValueIO(v_ref[]), V))
    end
end

"""Store `val` at `key` and position the cursor at the stored entry."""
function put!(cur::Cursor, key, val; flags::Integer = zero(Cuint))
    mdb_cursor_put(cur, key, val, Cuint(flags))
end

"""
    delete!(cur::Cursor; flags=0)

Delete the current key/value pair. An unpositioned cursor produces
`LMDBError(EINVAL)`. The cursor remains usable; both `MDB_GET_CURRENT` and
`MDB_NEXT` select the following record after deletion.
"""
function delete!(cur::Cursor; flags::Integer = zero(Cuint))
    mdb_cursor_del(cur, Cuint(flags))
    return
end

"Return the number of values at the current key in an `MDB_DUPSORT` database."
function count(cur::Cursor)
    countp = Ref(Csize_t(0))
    mdb_cursor_count(cur, countp)
    return Int(countp[])
end
