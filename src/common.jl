@public isflagset, version, MDBValueIO

# Empty value used for output arguments and for deleting all values at a key.
MDBValue() = MDB_val(zero(Csize_t), C_NULL)
MDBValue(::Nothing) = MDBValue()

# `ccall` preserves the object returned by `cconvert` until the call completes.
# Keep the `MDB_val` storage and the Julia data it points to in one carrier.
struct MDBArg{D}
    box::Base.RefValue{MDB_val}
    data::D
    MDBArg(data::D) where {D} = new{D}(Ref{MDB_val}(), data)
end

@inline function Base.unsafe_convert(::Type{Ptr{MDB_val}}, m::MDBArg{String})
    m.box[] = MDB_val(Csize_t(sizeof(m.data)),
                       Ptr{Cvoid}(Base.unsafe_convert(Ptr{UInt8}, m.data)))
    return Base.unsafe_convert(Ptr{MDB_val}, m.box)
end
@inline function Base.unsafe_convert(::Type{Ptr{MDB_val}}, m::MDBArg{<:AbstractArray{T}}) where {T}
    m.box[] = MDB_val(Csize_t(sizeof(T) * length(m.data)),
                       Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, m.data)))
    return Base.unsafe_convert(Ptr{MDB_val}, m.box)
end
@inline function Base.unsafe_convert(::Type{Ptr{MDB_val}}, m::MDBArg{<:Base.RefValue{T}}) where {T}
    m.box[] = MDB_val(Csize_t(sizeof(T)),
                       Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, m.data)))
    return Base.unsafe_convert(Ptr{MDB_val}, m.box)
end

# `Ref` has pointer ABI without overlapping Base's array-to-`Ptr` conversions.
Base.cconvert(::Type{Ref{MDB_val}}, x::MDB_val) = Ref(x)
Base.cconvert(::Type{Ref{MDB_val}}, x::Base.RefValue{MDB_val}) = x
Base.cconvert(::Type{Ref{MDB_val}}, x::Ptr) = convert(Ptr{MDB_val}, x)
Base.cconvert(::Type{Ref{MDB_val}}, x::String) = MDBArg(x)

function _iscontiguous(x::AbstractArray)
    isempty(x) && return true
    applicable(strides, x) || return false
    expected = 1
    for d in 1:ndims(x)
        size(x, d) > 1 && stride(x, d) != expected && return false
        expected *= size(x, d)
    end
    return true
end

function _array_arg(x::AbstractArray{T}) where T
    isbitstype(T) || throw(ArgumentError("LMDB array elements must be bitstypes"))
    _iscontiguous(x) || throw(ArgumentError("LMDB arrays must have contiguous storage"))
    return MDBArg(x)
end

Base.cconvert(::Type{Ref{MDB_val}}, x::AbstractArray) = _array_arg(x)
function Base.cconvert(::Type{Ref{MDB_val}}, x::Base.RefValue{T}) where T
    isbitstype(T) || throw(ArgumentError("LMDB Ref values must be bitstypes"))
    return MDBArg(x)
end

function Base.cconvert(::Type{Ref{MDB_val}}, x::T) where {T}
    isbitstype(T) || throw(MethodError(Base.cconvert, (Ref{MDB_val}, x)))
    return MDBArg(Ref(x))
end

"""
    MDBValueIO(v::MDB_val) <: IO
    MDBValueIO(ref::Ref{MDB_val}) <: IO

A read-only, positionable `IO` view of an `MDB_val`. `String` and
`Vector{T}` reads consume and copy the remaining bytes; Base's fixed-width
`read(io, T)` methods consume `sizeof(T)` bytes.

Define `Base.read(io::IO, ::Type{T})` to support another representation:

    struct PrefixedBlob end
    function Base.read(io::IO, ::Type{PrefixedBlob})
        bytesavailable(io) < 8 && return UInt8[]
        skip(io, 8)
        return read(io, Vector{UInt8})
    end

    LMDB.get(txn, dbi, key, PrefixedBlob, nothing)   # → Union{Vector{UInt8}, Nothing}

For an `isbitstype` struct `T`, for example:

    Base.read(io::IO, ::Type{T}) = read!(io, Ref{T}())[]

`MDBValueIO` does not own the referenced memory. LMDB invalidates returned
values after a subsequent update operation or when the transaction ends.
"""
mutable struct MDBValueIO <: IO
    ptr::Ptr{UInt8}
    size::Int
    pos::Int
end
@inline MDBValueIO(v::MDB_val) =
    MDBValueIO(Ptr{UInt8}(v.mv_data), Int(v.mv_size), 0)
@inline MDBValueIO(ref::Ref{MDB_val}) = MDBValueIO(ref[])

# These two read methods supply Base's generic fixed-width and array reads.
@inline Base.isreadable(::MDBValueIO) = true
@inline Base.iswritable(::MDBValueIO) = false
@inline Base.eof(io::MDBValueIO)            = io.pos >= io.size
@inline Base.position(io::MDBValueIO)       = io.pos
@inline Base.bytesavailable(io::MDBValueIO) = io.size - io.pos
@inline function Base.seek(io::MDBValueIO, n::Integer)
    io.pos = clamp(Int(n), 0, io.size)
    return io
end
@inline Base.seekstart(io::MDBValueIO) = (io.pos = 0; io)
@inline Base.seekend(io::MDBValueIO)   = (io.pos = io.size; io)
@inline function Base.skip(io::MDBValueIO, n::Integer)
    io.pos = clamp(io.pos + Int(n), 0, io.size)
    return io
end

@inline function Base.unsafe_read(io::MDBValueIO, dst::Ptr{UInt8}, n::UInt)
    p = io.pos
    p + n <= io.size || throw(EOFError())
    GC.@preserve io unsafe_copyto!(dst, io.ptr + p, n)
    io.pos = p + Int(n)
    return nothing
end

@inline Base.unsafe_read(io::MDBValueIO, p::Ptr, n::Integer) =
    unsafe_read(io, convert(Ptr{UInt8}, p), convert(UInt, n))

@inline function Base.read(io::MDBValueIO, ::Type{UInt8})
    p = io.pos
    p < io.size || throw(EOFError())
    b = unsafe_load(io.ptr + p)
    io.pos = p + 1
    return b
end

# A generic bitstype overload here would be ambiguous with a user method such as
# `read(::IO, ::Type{MyType})`; rely on Base's concrete methods instead.

# Whole-value reads consume the remaining buffer.
@inline function Base.read(io::MDBValueIO, ::Type{String})
    p = io.pos
    n = io.size - p
    s = GC.@preserve io unsafe_string(io.ptr + p, n)
    io.pos = io.size
    return s
end

@inline function Base.read(io::MDBValueIO, ::Type{Vector{T}}) where {T}
    isbitstype(T) || throw(ArgumentError("LMDB vector elements must be bitstypes"))
    p = io.pos
    nbytes = io.size - p
    n, r = divrem(nbytes, sizeof(T))
    iszero(r) || throw(ArgumentError(
        "MDB value byte size $(nbytes) is not a multiple of sizeof($T)=$(sizeof(T))"))
    out = Vector{T}(undef, n)
    GC.@preserve io out unsafe_copyto!(Ptr{UInt8}(pointer(out)), io.ptr + p, nbytes)
    io.pos = io.size
    return out
end


"""Return the LMDB library version."""
function version()
    major = Ref{Cint}()
    minor = Ref{Cint}()
    patch = Ref{Cint}()
    mdb_version(major, minor, patch)
    return VersionNumber(major[], minor[], patch[])
end

"""Return whether every bit in `flag` is set in `value`."""
isflagset(value, flag) = (value & flag) == flag

# Convert a raw `MDB_stat` (C field names) into the documented NamedTuple
# returned from `stat(env)` and `stat(txn, dbi)`.
@inline stat_namedtuple(s::MDB_stat) =
    (psize          = Int(s.ms_psize),
     depth          = Int(s.ms_depth),
     branch_pages   = Int(s.ms_branch_pages),
     leaf_pages     = Int(s.ms_leaf_pages),
     overflow_pages = Int(s.ms_overflow_pages),
     entries        = Int(s.ms_entries))
