# Zero-valued `MDB_val` sentinels — used as out-parameters and for the
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
# place pointer extraction happens — that means `data` is provably alive
# at the moment its pointer is taken.
struct MDBArg{D}
    box::Base.RefValue{MDB_val}
    data::D
    MDBArg(data::D) where {D} = new{D}(Ref{MDB_val}(), data)
end

# Lazy pointer extraction. Runs while ccall is preserving `m`; therefore
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
# User input — package the data, defer pointer extraction.
Base.cconvert(::Type{Ptr{MDB_val}}, x::String)        = MDBArg(x)
Base.cconvert(::Type{Ptr{MDB_val}}, x::Array)         = MDBArg(x)
# Other AbstractArrays that support `unsafe_convert(Ptr{T}, x)` flow through —
# contiguous `SubArray`, `ReinterpretArray`, etc. Non-contiguous inputs
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

# Private: build an `MDB_val` whose `mv_data` aliases `buf`. The pointer
# is taken via `unsafe_convert`; the caller MUST keep `buf` alive across
# any ccall that reads the resulting `MDB_val` (in practice, by wrapping
# the call site in `GC.@preserve buf ...`). Used by the cursor iterator,
# which already threads its key buffer through the iteration state for
# exactly this reason.
@inline _mdb_val_for(buf::Vector{T}) where {T} =
    MDB_val(Csize_t(sizeof(T) * length(buf)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, buf)))

mbd_unpack(::Type{T}, mdb_val_ref::Ref{MDB_val}) where {T} = _mbd_unpack(T, mdb_val_ref[])
function _mbd_unpack(::Type{T}, mdb_val::MDB_val) where {T <: String}
    unsafe_string(convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
end
function _mbd_unpack(::Type{V}, mdb_val::MDB_val) where {T, V <: Vector{T}}
    # The MDB_val data points into the LMDB-owned mmap and is only valid for
    # the lifetime of the transaction. Copy out so the returned Vector owns
    # its memory and is safe to retain past commit/abort (issue #41).
    src = unsafe_wrap(Array, convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
    copy(reinterpret(T, src))
end
function _mbd_unpack(::Type{T}, mdb_val::MDB_val) where {T}
    unsafe_load(convert(Ptr{T}, mdb_val.mv_data))
end


"""Return the LMDB library version and version information

Function returns tuple `(VersionNumber, String)` that contains a library version and a library version string.
"""
function version()
    major = Ref{Cint}()
    minor = Ref{Cint}()
    patch = Ref{Cint}()
    ver_str = mdb_version(major, minor, patch)
    return VersionNumber(major[], minor[], patch[]), unsafe_string(ver_str)
end

""" Check if binary flag is set in provided value"""
isflagset(value, flag) = (value & flag) == flag
