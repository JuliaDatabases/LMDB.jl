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

"""
    mdb_unpack(::Type{T}, ref::Ref{MDB_val}) -> T

Decode an `MDB_val` (size + raw `mv_data` pointer) into a Julia value of
type `T`. Called by `tryget` / `get` / cursor accessors after a
successful read. Default methods cover `String`, `Vector{E}` for any
bitstype `E`, and any bitstype scalar; all of them copy out so the
returned value is safe to keep past the producing transaction.

This is the package's customization point for typed reads — analogous
to heed's `BytesDecode<'txn>` trait. To plug in a custom value
representation (e.g. skip a framing prefix, parse a tagged buffer,
build a non-bitstype struct), define a method on a marker type:

    struct PrefixedBlob end
    function LMDB.mdb_unpack(::Type{PrefixedBlob}, ref::Ref{LMDB.MDB_val})
        v = ref[]; sz = Int(v.mv_size)
        sz < 8 && return UInt8[]
        out = Vector{UInt8}(undef, sz - 8)
        unsafe_copyto!(pointer(out),
                       Ptr{UInt8}(v.mv_data) + 8, sz - 8)
        out
    end

    LMDB.tryget(txn, dbi, key, PrefixedBlob)   # → Union{Vector{UInt8}, Nothing}

The `mv_data` pointer is into LMDB's mmap and is only valid for the
producing transaction's lifetime. Custom unpack methods must copy what
they want to keep, exactly as the default `Vector{E}` method does.
"""
mdb_unpack(::Type{T}, mdb_val_ref::Ref{MDB_val}) where {T} = _mdb_unpack(T, mdb_val_ref[])
function _mdb_unpack(::Type{T}, mdb_val::MDB_val) where {T <: String}
    unsafe_string(convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
end
function _mdb_unpack(::Type{V}, mdb_val::MDB_val) where {T, V <: Vector{T}}
    # The MDB_val data points into the LMDB-owned mmap and is only valid for
    # the lifetime of the transaction. Copy out so the returned Vector owns
    # its memory and is safe to retain past commit/abort (issue #41).
    src = unsafe_wrap(Array, convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
    copy(reinterpret(T, src))
end
function _mdb_unpack(::Type{T}, mdb_val::MDB_val) where {T}
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

# Convert a raw `MDB_stat` (C field names) into the documented NamedTuple
# returned from `stat(env)` and `stat(txn, dbi)`.
@inline _stat_namedtuple(s::MDB_stat) =
    (psize          = Int(s.ms_psize),
     depth          = Int(s.ms_depth),
     branch_pages   = Int(s.ms_branch_pages),
     leaf_pages     = Int(s.ms_leaf_pages),
     overflow_pages = Int(s.ms_overflow_pages),
     entries        = Int(s.ms_entries))
