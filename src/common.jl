export isflagset
@public version, MDBValueIO

# Zero-valued `MDB_val` sentinels, used as out-parameters and for the
# "no value" form of `delete!`. Constructing a non-empty `MDB_val` from a
# Julia value requires taking a raw pointer into that value, which is only
# safe when the value is GC-preserved across the eventual ccall. We keep
# that pointer extraction confined to `unsafe_convert(::Ptr{MDB_val}, ::MDBArg)`
# below, where ccall's automatic preservation covers the carrier.
MDBValue() = MDB_val(zero(Csize_t), C_NULL)
MDBValue(::Nothing) = MDBValue()

# Self-rooted argument for `Ptr{MDB_val}` ccall sites. `box` is an
# uninitialized `Ref{MDB_val}`; `data` is the Julia-owned buffer whose
# pointer the C call needs to see. `cconvert` returns an `MDBArg`, ccall
# preserves it across the call, and `unsafe_convert` (below) is the one
# place pointer extraction happens, so `data` is provably alive
# at the moment its pointer is taken.
struct MDBArg{D}
    box::Base.RefValue{MDB_val}
    data::D
    MDBArg(data::D) where {D} = new{D}(Ref{MDB_val}(), data)
end

# Lazy pointer extraction. Runs while ccall is preserving `m`, so
# `m.data` is alive at the point we ask it for a pointer, satisfying the
# Julia GC contract for `Base.unsafe_convert`.
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

# Bare `MDB_val` (used for `delete!`'s empty val): heap-box it.
Base.cconvert(::Type{Ptr{MDB_val}}, x::MDB_val) = Ref(x)
# Pre-built `Ref{MDB_val}` (iterator state, `get` out-param): passthrough;
# ccall reads/writes the box directly.
Base.cconvert(::Type{Ptr{MDB_val}}, x::Base.RefValue{MDB_val}) = x
# User input: package the data, defer pointer extraction.
Base.cconvert(::Type{Ptr{MDB_val}}, x::String)        = MDBArg(x)
Base.cconvert(::Type{Ptr{MDB_val}}, x::Array)         = MDBArg(x)
# Other AbstractArrays that support `unsafe_convert(Ptr{T}, x)` flow through:
# contiguous `SubArray`, `ReinterpretArray`, and so on. Non-contiguous inputs
# surface the standard "cannot take pointer" error from `unsafe_convert`.
# The `Array` method above stays as a more-specific overload to break the
# ambiguity with `Base.cconvert(::Type{<:Ptr}, ::Array)`.
Base.cconvert(::Type{Ptr{MDB_val}}, x::AbstractArray) = MDBArg(x)
Base.cconvert(::Type{Ptr{MDB_val}}, x::Base.RefValue) = MDBArg(x)
# Bare bitstype scalar: heap-box via `Ref` so it has a stable address.
function Base.cconvert(::Type{Ptr{MDB_val}}, x::T) where {T}
    isbitstype(T) || throw(MethodError(Base.cconvert, (Ptr{MDB_val}, x)))
    MDBArg(Ref(x))
end

"""
    MDBValueIO(v::MDB_val) <: IO
    MDBValueIO(ref::Ref{MDB_val}) <: IO

A read-only `IO` view over an LMDB-owned `MDB_val`. Wraps the
`(mv_data, mv_size)` pair as a positionable byte stream so the
package's typed-read path is the standard `Base.read(io, T)`.

Any `T` for which `Base.read(io::IO, ::Type{T})` is defined can be
passed to `tryget`, `get`, `key`, `value`, `item`, typed `walk`,
`pop!`, and `replace!`. Out of the box this covers everything Base
ships: the primitive numeric types (`Int8`/…/`Int128`, `Float16`/…/
`Float64`, `Bool`, `Char`, `Ptr{T}`) plus `String`, all zero-allocation
thanks to the `@inline` `unsafe_read` override below. The package adds
two more overloads, `Vector{E}` for any bitstype `E` and `UInt8`, that
consume the remaining buffer in a single copy.

To plug in a custom representation (including bitstype structs that
Base's primitive reads don't cover), define a single `Base.read`
method on your own type. Defining it on the abstract `IO` is the
idiomatic Julia form and keeps the decoder portable to other byte
sources:

    struct PrefixedBlob end
    function Base.read(io::IO, ::Type{PrefixedBlob})
        bytesavailable(io) < 8 && return UInt8[]
        skip(io, 8)
        return read(io, Vector{UInt8})
    end

    LMDB.tryget(txn, dbi, key, PrefixedBlob)   # → Union{Vector{UInt8}, Nothing}

For an `isbitstype` struct `T`, the one-liner is the standard Base
pattern:

    Base.read(io::IO, ::Type{T}) = read!(io, Ref{T}())[]

This is the analogue of heed's `BytesDecode<'txn>` trait, expressed
through Julia's existing IO interface instead of a bespoke function.

The underlying buffer points into LMDB's mmap and is only valid for
the producing transaction's lifetime. Copy out anything you want to
retain past commit/abort. The default `String` and `Vector{E}` reads
both copy.
"""
mutable struct MDBValueIO <: IO
    ptr::Ptr{UInt8}
    size::Int
    pos::Int
end
@inline MDBValueIO(v::MDB_val) =
    MDBValueIO(Ptr{UInt8}(v.mv_data), Int(v.mv_size), 0)
@inline MDBValueIO(ref::Ref{MDB_val}) = MDBValueIO(ref[])

# IO interface primitives. Defining `read(::MDBValueIO, ::Type{UInt8})`
# and `unsafe_read(::MDBValueIO, ::Ptr{UInt8}, ::UInt)` is enough to
# inherit Base's generic numeric and array reads; the rest are
# convenience getters.
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

# Override Base's `@noinline unsafe_read(::IO, ::Ref{T}, ::Integer)`
# (base/io.jl, "mark noinline to ensure ref is gc-rooted somewhere by the
# caller"). The barrier is correct in general but blocks SROA from
# eliminating the `Ref{T}(0)` that Base's `read(::IO, T::Union{Int16,…})`
# allocates. Our copy is bytewise into Julia memory and needs no GC root,
# so we inline through the Ref→Ptr conversion and let escape analysis
# elide the box. This is what makes plain `read(io, T)` for primitive
# numeric `T` allocation-free without needing per-type fast paths.
@inline Base.unsafe_read(io::MDBValueIO, p::Ref{T}, n::Integer) where {T} =
    unsafe_read(io, Base.unsafe_convert(Ref{T}, p)::Ptr, n)

@inline Base.unsafe_read(io::MDBValueIO, p::Ptr, n::Integer) =
    unsafe_read(io, convert(Ptr{UInt8}, p), convert(UInt, n))

@inline function Base.read(io::MDBValueIO, ::Type{UInt8})
    p = io.pos
    p < io.size || throw(EOFError())
    b = unsafe_load(io.ptr + p)
    io.pos = p + 1
    return b
end

# Note: we deliberately don't define a `Base.read(io::MDBValueIO, ::Type{T})
# where T` catch-all for `isbitstype(T)`. Such a generic conflicts with
# users defining the idiomatic `Base.read(io::IO, ::Type{MyT})`: Julia
# treats `(MDBValueIO, Type{T} where T)` and `(IO, Type{MyT})` as
# unordered (one is more specific in arg1, the other in arg2), so the
# call ambiguates. Instead, we rely on Base's existing
# `read(::IO, T::Union{Int8,…,Float64,Bool,Char,Ptr})` specialisations
# for the well-known primitives. Our `@inline unsafe_read` above lets
# the optimiser elide the `Ref{T}` Base allocates internally, so they
# stay zero-allocation. User-defined types, including `isbitstype`
# structs, just need a one-line `Base.read(io::IO, ::Type{MyT})` method
# defined wherever the user owns the type.

# Whole-blob defaults: read everything from the current position to the end.
# These mirror what users intuitively expect when calling `read(io, T)`
# against an LMDB-backed value (`String` and `Vector{E}` consume the rest
# of the buffer).
@inline function Base.read(io::MDBValueIO, ::Type{String})
    p = io.pos
    n = io.size - p
    s = GC.@preserve io unsafe_string(io.ptr + p, n)
    io.pos = io.size
    return s
end

@inline function Base.read(io::MDBValueIO, ::Type{Vector{T}}) where {T}
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
    ver_str = mdb_version(major, minor, patch)
    return VersionNumber(major[], minor[], patch[])
end

""" Check if binary flag is set in provided value"""
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
