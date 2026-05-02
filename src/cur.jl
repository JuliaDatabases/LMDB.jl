"""
A handle to a cursor structure for navigating through a database.

A `Cursor` keeps a reference to its parent `Transaction` to expose it via
`transaction(cur)` and to keep the txn alive under GC. The cursor's
finalizer closes any still-open handle.
"""
mutable struct Cursor
    handle::Ptr{MDB_cursor}
    txn::Union{Transaction, Nothing}
    function Cursor(txn::Union{Transaction, Nothing}, h::Ptr{MDB_cursor})
        c = new(h, txn)
        finalizer(close, c)
        return c
    end
end

Base.unsafe_convert(::Type{Ptr{MDB_cursor}}, c::Cursor) = c.handle

"Check if cursor is open"
isopen(cur::Cursor) = cur.handle != C_NULL

"Create a cursor"
function open(txn::Transaction, dbi::DBI)
    cur_ptr_ref = Ref{Ptr{MDB_cursor}}(C_NULL)
    mdb_cursor_open(txn, dbi, cur_ptr_ref)
    return Cursor(txn, cur_ptr_ref[])
end

"Wrapper of Cursor `open` for `do` construct"
function open(f::Function, txn::Transaction, dbi::DBI)
    cur = open(txn, dbi)
    try
        f(cur)
    finally
        close(cur)
    end
end

"Close a cursor. Idempotent."
function close(cur::Cursor)
    cur.handle == C_NULL && return
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

"Return the cursor's database"
function database(cur::Cursor)
    dbi = mdb_cursor_dbi(cur)
    (dbi == 0) && return nothing
    return DBI(dbi, "")
end

"Type to implement the Iterator interface"
struct LMDBIterator{R}
   cur::Cursor
   r::R
   prefix::Vector{UInt8}
end
struct ReturnKeys{K} end
struct ReturnValues{V} end
struct ReturnBoth{K,V} end
struct ReturnValueSize end

arcopy(x::Array) = copy(x)
arcopy(x) = x
# process_returns returns (retval, next_op, key_buf). key_buf is whatever the
# iterator wrote into mdb_key_ref via mdb_key_ref[] = MDBValue(buf); it must
# be GC-preserved across the next mdb_cursor_get call. Variants that don't
# rewrite the key return `nothing` for key_buf.
process_returns(::ReturnKeys{K}, mdb_key_ref, _) where K = arcopy(mbd_unpack(K, mdb_key_ref)), MDB_NEXT, nothing
process_returns(::ReturnValues{V}, _, mdb_val_ref) where V = arcopy(mbd_unpack(V, mdb_val_ref)), MDB_NEXT, nothing
process_returns(::ReturnBoth{K,V}, mdb_key_ref, mdb_val_ref) where {K,V} = arcopy((mbd_unpack(K, mdb_key_ref)) => arcopy(mbd_unpack(V, mdb_val_ref))), MDB_NEXT, nothing
process_returns(::ReturnValueSize, _, mdb_val_ref) = mdb_val_ref[].mv_size, MDB_NEXT, nothing
function init_values(d::LMDBIterator)
    k, op, key_buf = if !isempty(d.prefix)
        Ref(MDBValue(d.prefix)), MDB_SET_RANGE, d.prefix
    else
        Ref(MDBValue()), MDB_FIRST, nothing
    end
    v = Ref(MDBValue())
    return k, v, op, key_buf
end

Base.iterate(iter::LMDBIterator) = Base.iterate(iter, init_values(iter))

"Iterate over database"
function Base.iterate(iter::LMDBIterator, refs)
    mdb_key_ref, mdb_val_ref, cursor_op, key_buf = refs

    # key_buf may be aliased by mdb_key_ref (e.g. DirectoryLister or
    # SET_RANGE seed) and must outlive the C call. unchecked_* because the
    # iterator branches on MDB_NOTFOUND itself.
    ret = GC.@preserve key_buf unchecked_mdb_cursor_get(iter.cur, mdb_key_ref, mdb_val_ref, cursor_op)

    if ret == 0
        #Check if we are still in key prefix
        if !isempty(iter.prefix)
            k = mbd_unpack(Vector{UInt8}, mdb_key_ref)
            if any(i->!=(i...),zip(iter.prefix, k))
                return nothing
            end
        end
        pr = process_returns(iter.r, mdb_key_ref, mdb_val_ref)
        pr === nothing && return nothing
        retval, nextop, next_key_buf = pr
        return (retval, (mdb_key_ref, mdb_val_ref, nextop, next_key_buf))
    elseif ret == MDB_NOTFOUND
        return nothing
    else
        throw(LMDBError(ret))
    end
end

struct DirectoryLister{K}
    sep::UInt8
    istart::Int
end
function DirectoryLister(; sep = '/', lprefix=0)
    DirectoryLister{String}(UInt8(sep),lprefix+1)
end

function process_returns(l::DirectoryLister{K}, mdb_key_ref, _) where K
    k = mbd_unpack(Vector{UInt8}, mdb_key_ref)
    nextsep = findnext(==(l.sep),k,l.istart)
    if nextsep === nothing
        return arcopy(mbd_unpack(K, mdb_key_ref)), MDB_NEXT, nothing
    else
        k = copy(k)
        resize!(k,nextsep)
        kout = arcopy(mbd_unpack(K, Ref(MDBValue(k))))
        k[end] = k[end]+1
        mdb_key_ref[] = MDBValue(k)
        # Return k so the next iterate() can GC.@preserve it across the
        # MDB_SET_RANGE call that reads through mdb_key_ref.
        return kout, MDB_SET_RANGE, k
    end
end


Base.IteratorSize(::LMDBIterator) = Base.SizeUnknown()
Base.eltype(::Type{<:LMDBIterator{<:ReturnKeys{K}}}) where K = K
Base.eltype(::Type{<:LMDBIterator{<:ReturnValues{V}}}) where V = V
Base.eltype(::Type{<:LMDBIterator{<:ReturnBoth{K,V}}}) where {K,V} = Pair{K,V}
Base.eltype(::Type{<:LMDBIterator{<:ReturnValueSize}}) = Csize_t

"Return iterator over keys of uniform, specified type"
function keys(cur::Cursor, ::Type{T}; prefix = UInt8[]) where T
    return LMDBIterator(cur, ReturnKeys{T}(), Vector{UInt8}(prefix))
end

function Base.values(cur::Cursor, ::Type{T}; prefix = UInt8[]) where T
    return LMDBIterator(cur,ReturnValues{T}(),Vector{UInt8}(prefix))
end

function Base.iterate(cur::Cursor, ::Type{K}, ::Type{V}) where {K,V}
    return Base.iterate(LMDBIterator(cur, ReturnBoth{K,V}()),Vector{UInt8}(prefix))
end

"""Retrieve by cursor.

This function retrieves key/data pairs from the database.
"""
function get(cur::Cursor, key, ::Type{T}, op::MDB_cursor_op=MDB_SET_KEY) where T
    val_ref = Ref(MDBValue())
    mdb_cursor_get(cur, key, val_ref, op)
    return mbd_unpack(T, val_ref)
end

"""Store by cursor.

This function stores key/data pairs into the database. The cursor is positioned at the new item, or on failure usually near it.
"""
function put!(cur::Cursor, key, val; flags::Cuint = zero(Cuint))
    mdb_cursor_put(cur, key, val, flags)
end

"Delete current key/data pair to which the cursor refers"
function delete!(cur::Cursor; flags::Cuint = zero(Cuint))
    mdb_cursor_del(cur, flags)
end

"Return count of duplicates for current key"
function count(cur::Cursor)
    countp = Ref(Csize_t(0))
    mdb_cursor_count(cur, countp)
    return Int(countp[])
end
