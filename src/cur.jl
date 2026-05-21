"""
A handle to a cursor structure for navigating through a database.
"""
mutable struct Cursor
    handle::Ptr{MDB_cursor}
end

"Check if cursor is open"
isopen(cur::Cursor) = cur.handle != C_NULL

"Create a cursor"
function open(txn::Transaction, dbi::DBI)
    cur_ptr_ref = Ref{Ptr{MDB_cursor}}(C_NULL)
    mdb_cursor_open(txn.handle, dbi.handle, cur_ptr_ref)
    return Cursor(cur_ptr_ref[])
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

"Close a cursor"
function close(cur::Cursor)
    if cur.handle == C_NULL
        @warn("Cursor is already closed")
    end
    _mdb_cursor_close(cur.handle)
    cur.handle = C_NULL
    return
end

"Renew a cursor"
function renew(txn::Transaction, cur::Cursor)
    mdb_cursor_renew(txn.handle, cur.handle)
end

"Return the cursor's transaction"
function transaction(cur::Cursor)
    txn_ptr = _mdb_cursor_txn(cur.handle)
    (txn_ptr == C_NULL) && return nothing
    return Transaction(txn_ptr)
end

"Return the cursor's database"
function database(cur::Cursor)
    dbi = _mdb_cursor_dbi(cur.handle)
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
process_returns(::ReturnKeys{K}, mdb_key_ref, _) where K = arcopy(mbd_unpack(K, mdb_key_ref)),MDB_NEXT
process_returns(::ReturnValues{V}, _, mdb_val_ref) where V = arcopy(mbd_unpack(V, mdb_val_ref)), MDB_NEXT
process_returns(::ReturnBoth{K,V}, mdb_key_ref, mdb_val_ref) where {K,V} = arcopy((mbd_unpack(K, mdb_key_ref)) => arcopy(mbd_unpack(V, mdb_val_ref))), MDB_NEXT
process_returns(::ReturnValueSize, _, mdb_val_ref) = mdb_val_ref[].mv_size, MDB_NEXT
function init_values(d::LMDBIterator)
    k,op = if !isempty(d.prefix)
        Ref(MDBValue(d.prefix)), MDB_SET_RANGE
    else
        Ref(MDBValue()), MDB_FIRST
    end
    v = Ref(MDBValue())
    return k,v,op
end

Base.iterate(iter::LMDBIterator) = Base.iterate(iter, init_values(iter))

"Iterate over database"
function Base.iterate(iter::LMDBIterator, refs)
    # Setup parameters
    mdb_key_ref, mdb_val_ref, cursor_op = refs

    ret = _mdb_cursor_get(iter.cur.handle, mdb_key_ref, mdb_val_ref, cursor_op)

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
        retval, nextop = pr
        return (retval, (mdb_key_ref, mdb_val_ref, nextop))
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
        return arcopy(mbd_unpack(K, mdb_key_ref)),MDB_NEXT
    else
        k = copy(k)
        resize!(k,nextsep)
        kout = arcopy(mbd_unpack(K, Ref(MDBValue(k))))
        k[end] = k[end]+1
        mdb_key_ref[] = MDBValue(k)
        return kout, MDB_SET_RANGE
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
    rkey = toref(key)
    GC.@preserve rkey begin
        mdb_key_ref = Ref(MDBValue(rkey))
        mdb_val_ref = Ref(MDBValue())
        mdb_cursor_get(cur.handle, mdb_key_ref, mdb_val_ref, op)
        return mbd_unpack(T, mdb_val_ref)
    end
end

"""Store by cursor.

This function stores key/data pairs into the database. The cursor is positioned at the new item, or on failure usually near it.
"""
function put!(cur::Cursor, key, val; flags::Cuint = zero(Cuint))
    rkey = toref(key)
    rval = toref(val)
    GC.@preserve rkey rval begin
        mdb_key_ref = Ref(MDBValue(rkey))
        mdb_val_ref = Ref(MDBValue(rval))
        mdb_cursor_put(cur.handle, mdb_key_ref, mdb_val_ref, flags)
    end
end

"Delete current key/data pair to which the cursor refers"
function delete!(cur::Cursor; flags::Cuint = zero(Cuint))
    mdb_cursor_del(cur.handle, flags)
end

"Return count of duplicates for current key"
function count(cur::Cursor)
    countp = Ref(Csize_t(0))
    mdb_cursor_count(cur.handle, countp)
    return Int(countp[])
end
