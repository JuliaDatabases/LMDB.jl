export LMDBDict
@public scan, scan_keys, scan_values, list_dirs, valuesize

"""
    LMDBDict{K,V}(path; readonly, rdahead, mapsize, readers, dbs)

A persistent `AbstractDict{K,V}` backed by a single LMDB environment
and its main database. Unless `readonly` is set, the directory at
`path` is created if it does not exist. Keys and values are stored as
raw bytes. Built-in
decoders support `String`, vectors of bitstypes, and Base's fixed-width
primitive reads; define `Base.read(io::IO, ::Type{T})` for other types.

For prefix-scoped scans (e.g. hierarchical "directory" key schemes),
see `LMDB.scan`, `LMDB.scan_keys`, `LMDB.scan_values`, and `LMDB.list_dirs`.
"""
mutable struct LMDBDict{K,V} <: AbstractDict{K,V}
    env::LMDB.Environment
    dbi::LMDB.Database
    function LMDBDict{K,V}(env::LMDB.Environment, dbi::LMDB.Database) where {K,V}
        x = new{K,V}(env, dbi)
        finalizer(x) do d
            LMDB.close(d.env, d.dbi)
            LMDB.close(d.env)
        end
        x
    end
end
function LMDBDict{K,V}(path::String; readonly = false, rdahead = false,
                       mapsize::Union{Integer,Nothing} = nothing,
                       readers::Union{Integer,Nothing} = nothing,
                       dbs::Union{Integer,Nothing} = nothing) where {K,V}
    # Tie reader slots to transactions, allowing interleaved reads on one thread
    # and moving a read transaction between threads.
    envflags = Cuint(MDB_NOTLS)
    rdahead || (envflags |= Cuint(MDB_NORDAHEAD))
    readonly && (envflags |= Cuint(MDB_RDONLY))
    readonly || mkpath(path)
    env = LMDB.Environment(path; mapsize, maxreaders = readers, maxdbs = dbs,
                           flags = envflags)
    dbi = Transaction(env) do txn
        Database(txn)
    end
    LMDBDict{K,V}(env, dbi)
end
LMDBDict(path::String; kwargs...) = LMDBDict{String, Vector{UInt8}}(path; kwargs...)

function Base.close(d::LMDBDict)
    LMDB.close(d.env, d.dbi)
    LMDB.close(d.env)
end

# --- internal helpers ---

function cursor_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    Transaction(d.env; flags = txnflags) do txn
        Cursor(txn, d.dbi) do cur
            f(cur)
        end
    end
end

function txn_dbi_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    Transaction(d.env; flags = txnflags) do txn
        f(txn, d.dbi)
    end
end

@inline function has_prefix(kv::LMDB.MDB_val, prefix::Vector{UInt8})
    kv.mv_size < length(prefix) && return false
    p = Ptr{UInt8}(kv.mv_data)
    @inbounds for i in 1:length(prefix)
        unsafe_load(p, i) == prefix[i] || return false
    end
    return true
end

function walk_prefix(f, cur, prefix::Vector{UInt8})
    if isempty(prefix)
        LMDB.walk(f, cur)
    else
        LMDB.walk(cur; from = prefix) do k_ref, v_ref
            has_prefix(k_ref[], prefix) || return false
            f(k_ref, v_ref)
            return nothing
        end
    end
end

# --- AbstractDict interface ---

# Iteration state owns a read transaction and cursor. Exhaustion closes both;
# early termination leaves cleanup to their finalizers.
function Base.iterate(d::LMDBDict)
    txn = Transaction(d.env; flags = Cuint(MDB_RDONLY))
    cur = Cursor(txn, d.dbi)
    return iter_step(d, txn, cur, MDB_FIRST)
end
Base.iterate(d::LMDBDict, (txn, cur)::Tuple{Transaction,Cursor}) =
    iter_step(d, txn, cur, MDB_NEXT)

function iter_step(::LMDBDict{K,V}, txn::Transaction, cur::Cursor,
                   op::MDB_cursor_op) where {K,V}
    k_ref = Ref(MDBValue())
    v_ref = Ref(MDBValue())
    ret = LMDB.unchecked_mdb_cursor_get(cur, k_ref, v_ref, op)
    if ret == MDB_NOTFOUND
        LMDB.close(cur)
        LMDB.commit(txn)
        return nothing
    elseif !iszero(ret)
        LMDB.close(cur)
        LMDB.abort(txn)
        throw(LMDBError(ret))
    end
    return (Base.read(LMDB.MDBValueIO(k_ref[]), K) =>
            Base.read(LMDB.MDBValueIO(v_ref[]), V), (txn, cur))
end

function Base.length(d::LMDBDict)
    txn_dbi_do(d, readonly = true) do txn, dbi
        Int(LMDB.stat(txn, dbi).entries)
    end
end

Base.isempty(d::LMDBDict) = iszero(length(d))

function Base.getindex(d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        v = LMDB.get(txn, dbi, convert(K, k), V, nothing)
        v === nothing ? throw(KeyError(k)) : v
    end
end

function Base.haskey(d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        LMDB.get(txn, dbi, convert(K, k), V, nothing) !== nothing
    end
end

function Base.get(d::LMDBDict{K,V}, k, default) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        LMDB.get(txn, dbi, convert(K, k), V, default)
    end
end

function Base.get(f::Base.Callable, d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d, readonly = true) do txn, dbi
        v = LMDB.get(txn, dbi, convert(K, k), V, nothing)
        v === nothing ? f() : v
    end
end

function Base.get!(d::LMDBDict{K,V}, k, default) where {K,V}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.get(txn, dbi, convert(K, k), V, nothing)
        v !== nothing && return v
        LMDB.put!(txn, dbi, convert(K, k), convert(V, default))
        return default
    end
end

function Base.get!(f::Base.Callable, d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.get(txn, dbi, convert(K, k), V, nothing)
        v !== nothing && return v
        default = f()
        LMDB.put!(txn, dbi, convert(K, k), convert(V, default))
        return default
    end
end

function Base.setindex!(d::LMDBDict{K,V}, v, k) where {K,V}
    txn_dbi_do(d) do txn, dbi
        LMDB.put!(txn, dbi, convert(K, k), convert(V, v))
    end
    return d
end

function Base.delete!(d::LMDBDict{K}, k) where K
    txn_dbi_do(d) do txn, dbi
        LMDB.delete!(txn, dbi, convert(K, k))
    end
    return d
end

function Base.pop!(d::LMDBDict{K,V}, k) where {K,V}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.pop!(txn, dbi, convert(K, k), V)
        v === nothing ? throw(KeyError(k)) : v
    end
end

function Base.pop!(d::LMDBDict{K,V}, k, default) where {K,V}
    txn_dbi_do(d) do txn, dbi
        v = LMDB.pop!(txn, dbi, convert(K, k), V)
        v === nothing ? default : v
    end
end

# LMDB's ordering makes the no-key form pop the first key.
function Base.pop!(d::LMDBDict{K,V}) where {K,V}
    txn_dbi_do(d) do txn, dbi
        Cursor(txn, dbi) do cur
            LMDB.seek!(cur, K) === nothing &&
                throw(ArgumentError("LMDBDict must be non-empty"))
            pair = LMDB.item(cur, K, V)
            LMDB.delete!(cur)
            return pair
        end
    end
end

function Base.empty!(d::LMDBDict)
    txn_dbi_do(d) do txn, dbi
        LMDB.drop(txn, dbi; delete = false)
    end
    return d
end

# A new LMDBDict needs a path; use `Dict(d)` for a memory snapshot or
# `copy(d.env, path)` for an on-disk copy.
const _NO_EMPTY_LMDBDICT =
    "LMDBDict has no path-less empty form; use Dict(d) for an in-memory " *
    "snapshot, or copy(d.env, path) for an on-disk clone"
Base.empty(::LMDBDict, ::Type, ::Type) = throw(ArgumentError(_NO_EMPTY_LMDBDICT))
Base.copy(::LMDBDict) = throw(ArgumentError(_NO_EMPTY_LMDBDICT))

# Batch bulk updates in one write transaction instead of one per entry.
function Base.merge!(d::LMDBDict{K,V}, others::AbstractDict...) where {K,V}
    txn_dbi_do(d) do txn, dbi
        for other in others, (k, v) in other
            LMDB.put!(txn, dbi, convert(K, k), convert(V, v))
        end
    end
    return d
end

function Base.mergewith!(combine, d::LMDBDict{K,V}, others::AbstractDict...) where {K,V}
    txn_dbi_do(d) do txn, dbi
        for other in others, (k, v) in other
            kk = convert(K, k)
            existing = LMDB.get(txn, dbi, kk, V, nothing)
            new = existing === nothing ? convert(V, v) :
                                          convert(V, combine(existing, v))
            LMDB.put!(txn, dbi, kk, new)
        end
    end
    return d
end

function Base.filter!(f, d::LMDBDict{K,V}) where {K,V}
    txn_dbi_do(d) do txn, dbi
        to_delete = K[]
        Cursor(txn, dbi) do cur
            LMDB.walk(cur, K, V) do k, v
                f(k => v) || push!(to_delete, k)
            end
        end
        for k in to_delete
            LMDB.delete!(txn, dbi, k)
        end
    end
    return d
end


# --- prefix-scan helpers ---

"""
    scan(d::LMDBDict; prefix=UInt8[]) -> Vector{Pair{K,V}}

Eagerly collect every `key => value` pair whose key starts with `prefix`
(byte-prefix; pass a `String` or `Vector{UInt8}`). Pass an empty prefix
to scan the whole dict.
"""
function scan(d::LMDBDict{K,V}; prefix = UInt8[]) where {K,V}
    bprefix = Vector{UInt8}(prefix)
    out = Pair{K,V}[]
    cursor_do(d, readonly = true) do cur
        walk_prefix(cur, bprefix) do k_ref, v_ref
            push!(out, Base.read(MDBValueIO(k_ref[]), K) =>
                       Base.read(MDBValueIO(v_ref[]), V))
        end
    end
    return out
end

"""
    scan_keys(d::LMDBDict; prefix=UInt8[]) -> Vector{K}

Eagerly collect every key that starts with `prefix`.
"""
function scan_keys(d::LMDBDict{K}; prefix = UInt8[]) where K
    bprefix = Vector{UInt8}(prefix)
    out = K[]
    cursor_do(d, readonly = true) do cur
        walk_prefix(cur, bprefix) do k_ref, _
            push!(out, Base.read(MDBValueIO(k_ref[]), K))
        end
    end
    return out
end

"""
    scan_values(d::LMDBDict; prefix=UInt8[]) -> Vector{V}

Eagerly collect every value whose key starts with `prefix`.
"""
function scan_values(d::LMDBDict{K,V}; prefix = UInt8[]) where {K,V}
    bprefix = Vector{UInt8}(prefix)
    out = V[]
    cursor_do(d, readonly = true) do cur
        walk_prefix(cur, bprefix) do _, v_ref
            push!(out, Base.read(MDBValueIO(v_ref[]), V))
        end
    end
    return out
end

"""
    list_dirs(d::LMDBDict{String}; prefix="", sep='/') -> Vector{String}

For dicts that use a hierarchical String key scheme (e.g. `"a/b/c"`),
return the immediate children of `prefix`. A child is either a leaf
key (no `sep` after `prefix`) or a directory marker (`prefix*name*sep`).
"""
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

"""
    valuesize(d::LMDBDict; prefix=UInt8[]) -> Int

Sum of the byte sizes of all values whose key starts with `prefix`.
"""
function valuesize(d::LMDBDict; prefix = UInt8[])
    bprefix = Vector{UInt8}(prefix)
    total = 0
    cursor_do(d, readonly = true) do cur
        walk_prefix(cur, bprefix) do _, v_ref
            total += Int(v_ref[].mv_size)
        end
    end
    return total
end
