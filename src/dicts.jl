mutable struct LMDBDict{K,V}
    env::LMDB.Environment
    dbi::LMDB.DBI
    function LMDBDict{K,V}(env::LMDB.Environment, dbi::LMDB.DBI) where {K,V}
        x = new{K,V}(env, dbi)
        finalizer(x) do d
            LMDB.close(d.env,d.dbi)
            LMDB.close(d.env)
        end
        x
    end
end
function LMDBDict{K,V}(path::String; readonly = false, rdahead = false,
                       mapsize::Union{Integer,Nothing} = nothing,
                       maxreaders::Union{Integer,Nothing} = nothing,
                       maxdbs::Union{Integer,Nothing} = nothing) where {K,V}
    txnflags = readonly ? Cuint(MDB_RDONLY) : zero(Cuint)
    if !rdahead
        txnflags = txnflags | Cuint(MDB_NORDAHEAD)
    end
    env = LMDB.Environment(path; mapsize, maxreaders, maxdbs)
    # A transaction just for getting a DBI handle.
    dbi = LMDB.start(env, flags = txnflags) do txn
        LMDB.open(txn)
    end
    LMDBDict{K,V}(env, dbi)
end
LMDBDict(path::String; kwargs...) = LMDBDict{String, Vector{UInt8}}(path; kwargs...)
Base.keytype(::LMDBDict{K}) where K = K
Base.eltype(::LMDBDict{<:Any,V}) where V = V
function Base.close(d::LMDBDict)
    LMDB.close(d.env,d.dbi)
    LMDB.close(d.env)
end
function cursor_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    LMDB.start(d.env, flags = txnflags) do txn
        LMDB.open(txn,d.dbi) do cur
            f(cur)
        end
    end
end

function txn_dbi_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    LMDB.start(d.env, flags = txnflags) do txn
        f(txn, d.dbi)
    end
end

function list_dirs(d::LMDBDict{String}; prefix = "", sep = '/')
    cursor_do(d, readonly = true) do cur
        bprefix = Vector{UInt8}(prefix)
        iter = LMDB.LMDBIterator(cur,LMDB.DirectoryLister(;sep = sep, lprefix = length(bprefix)),bprefix)
        collect(iter)
    end
end

function Base.keys(d::LMDBDict{K}; prefix=UInt8[]) where K
    cursor_do(d, readonly = true) do cur
        collect(keys(cur,K,prefix=prefix))
    end
end

function Base.values(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    cursor_do(d, readonly = true) do cur
        collect(values(cur,V,prefix=prefix))
    end
end

function Base.collect(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    cursor_do(d, readonly = true) do cur
        collect((LMDB.LMDBIterator(cur,LMDB.ReturnBoth{K,V}(),Vector{UInt8}(prefix))))
    end
end

function valuesize(d::LMDBDict; prefix = UInt8[])
    cursor_do(d, readonly = true) do cur
        iter = LMDB.LMDBIterator(cur,LMDB.ReturnValueSize(),Vector{UInt8}(prefix))
        sum(iter)
    end
end

function Base.getindex(d::LMDBDict{K,V},k) where {K,V}
    cursor_do(d, readonly = true) do cur
        LMDB.get(cur, convert(K,k), V, LMDB.MDB_SET_KEY)
    end
end

function Base.haskey(d::LMDBDict{K}, key) where K
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_val_ref = Ref(MDBValue())
        ret = unchecked_mdb_get(txn, dbi, convert(K, key), mdb_val_ref)
        if ret == MDB_NOTFOUND
            return false
        elseif ret == Cint(0)
            return true
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.get(d::LMDBDict{K,V}, key, default) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_val_ref = Ref(MDBValue())
        ret = unchecked_mdb_get(txn, dbi, convert(K, key), mdb_val_ref)
        if ret == MDB_NOTFOUND
            return default
        elseif ret == Cint(0)
            return mdb_unpack(V, mdb_val_ref)
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.get!(d::LMDBDict{K,V}, key, default) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_val_ref = Ref(MDBValue())
        ret = unchecked_mdb_get(txn, dbi, convert(K, key), mdb_val_ref)
        if ret == MDB_NOTFOUND
            d[key] = default
            return default
        elseif ret == Cint(0)
            return mdb_unpack(V, mdb_val_ref)
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.get(f::F, d::LMDBDict{K,V}, key) where {K,V,F<:Union{Function, Type}}
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_val_ref = Ref(MDBValue())
        ret = unchecked_mdb_get(txn, dbi, convert(K, key), mdb_val_ref)
        if ret == MDB_NOTFOUND
            return f()
        elseif ret == Cint(0)
            return mdb_unpack(V, mdb_val_ref)
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.get!(f::F, d::LMDBDict{K,V}, key) where {K,V,F<:Union{Function, Type}}
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_val_ref = Ref(MDBValue())
        ret = unchecked_mdb_get(txn, dbi, convert(K, key), mdb_val_ref)
        if ret == MDB_NOTFOUND
            default = f()
            d[key] = default
            return default
        elseif ret == Cint(0)
            return mdb_unpack(V, mdb_val_ref)
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.setindex!(d::LMDBDict{K,V},v,k) where {K,V}
    txn_dbi_do(d) do txn, dbi
        LMDB.put!(txn,dbi,convert(K,k),convert(V,v))
    end
    v
end

function Base.delete!(d::LMDBDict{K},k) where K
    txn_dbi_do(d) do txn, dbi
        LMDB.delete!(txn, dbi, convert(K,k))
    end
    d
end
