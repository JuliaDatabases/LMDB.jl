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
                       readers::Union{Integer,Nothing} = nothing,
                       dbs::Union{Integer,Nothing} = nothing) where {K,V}
    flags = readonly ? MDB_RDONLY : zero(Cuint)
    if !rdahead
        flags = flags | MDB_NORDAHEAD
    end
    env = LMDB.create()
    mapsize  === nothing || (env[:MapSize] = mapsize)
    readers  === nothing || (env[:Readers] = readers)
    dbs      === nothing || (env[:DBs]     = dbs)
    open(env, path)
    #A transaction just for getting a DBI handle
    dbi = LMDB.start(env,flags=flags) do txn
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

# Does `kv`'s data start with `prefix`?
@inline function _has_prefix(kv::LMDB.MDB_val, prefix::Vector{UInt8})
    kv.mv_size < length(prefix) && return false
    p = Ptr{UInt8}(kv.mv_data)
    @inbounds for i in 1:length(prefix)
        unsafe_load(p, i) == prefix[i] || return false
    end
    return true
end

# Walk every entry under `prefix` (or every entry if `prefix` is empty),
# stopping at the first key that no longer matches.
function _walk_prefix(f, cur, prefix::Vector{UInt8})
    if isempty(prefix)
        LMDB.walk(f, cur)
    else
        LMDB.walk(cur; from = prefix) do k_ref, v_ref
            _has_prefix(k_ref[], prefix) || return false
            f(k_ref, v_ref)
            return nothing
        end
    end
end

function list_dirs(d::LMDBDict{String}; prefix = "", sep = '/')
    bprefix = Vector{UInt8}(prefix)
    sepb = UInt8(sep)
    out = String[]
    cursor_do(d, readonly = true) do cur
        k = isempty(bprefix) ? LMDB.seek!(cur, Vector{UInt8}) :
                               LMDB.seek_range!(cur, bprefix, Vector{UInt8})
        while k !== nothing
            (length(k) >= length(bprefix) &&
             view(k, 1:length(bprefix)) == bprefix) || break
            sepidx = findnext(==(sepb), k, length(bprefix) + 1)
            if sepidx === nothing
                push!(out, String(copy(k)))
                k = LMDB.next!(cur, Vector{UInt8})
            else
                push!(out, String(@view k[1:sepidx]))
                next_marker = copy(k[1:sepidx])
                next_marker[end] = next_marker[end] + 0x01
                k = LMDB.seek_range!(cur, next_marker, Vector{UInt8})
            end
        end
    end
    return out
end

function Base.keys(d::LMDBDict{K}; prefix=UInt8[]) where K
    bprefix = Vector{UInt8}(prefix)
    out = K[]
    cursor_do(d, readonly = true) do cur
        _walk_prefix(cur, bprefix) do k_ref, _
            push!(out, LMDB.mdb_unpack(K, k_ref))
        end
    end
    return out
end

function Base.values(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    bprefix = Vector{UInt8}(prefix)
    out = V[]
    cursor_do(d, readonly = true) do cur
        _walk_prefix(cur, bprefix) do _, v_ref
            push!(out, LMDB.mdb_unpack(V, v_ref))
        end
    end
    return out
end

function Base.collect(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    bprefix = Vector{UInt8}(prefix)
    out = Pair{K,V}[]
    cursor_do(d, readonly = true) do cur
        _walk_prefix(cur, bprefix) do k_ref, v_ref
            push!(out, LMDB.mdb_unpack(K, k_ref) => LMDB.mdb_unpack(V, v_ref))
        end
    end
    return out
end

function valuesize(d::LMDBDict; prefix = UInt8[])
    bprefix = Vector{UInt8}(prefix)
    total = 0
    cursor_do(d, readonly = true) do cur
        _walk_prefix(cur, bprefix) do _, v_ref
            total += Int(v_ref[].mv_size)
        end
    end
    return total
end

function Base.getindex(d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        LMDB.get(txn, dbi, convert(K, k), V)
    end
end

function Base.haskey(d::LMDBDict{K,V}, key) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        LMDB.tryget(txn, dbi, convert(K, key), V) !== nothing
    end
end

function Base.get(d::LMDBDict{K,V}, key, default) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        LMDB.get(txn, dbi, convert(K, key), V, default)
    end
end

function Base.get!(d::LMDBDict{K,V}, key, default) where {K,V}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.tryget(txn, dbi, convert(K, key), V)
        v !== nothing && return v
        LMDB.put!(txn, dbi, convert(K, key), convert(V, default))
        return default
    end
end

function Base.get(f::F, d::LMDBDict{K,V}, key) where {K,V,F<:Union{Function, Type}}
    txn_dbi_do(d, readonly = true) do txn, dbi
        v = LMDB.tryget(txn, dbi, convert(K, key), V)
        v === nothing ? f() : v
    end
end

function Base.get!(f::F, d::LMDBDict{K,V}, key) where {K,V,F<:Union{Function, Type}}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.tryget(txn, dbi, convert(K, key), V)
        v !== nothing && return v
        default = f()
        LMDB.put!(txn, dbi, convert(K, key), convert(V, default))
        return default
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
