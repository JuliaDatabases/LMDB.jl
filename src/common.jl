const EnvironmentFlags = Unsigned

# Build an `MDB_val` (size + raw data pointer) from a heap-rooted Julia value.
# The pointer is taken via `Base.unsafe_convert` — the same primitive ccall
# uses internally to lower `Ref{T}`/`Vector{T}`/`String` arguments. The caller
# is responsible for keeping `val` alive across the ccall (via `GC.@preserve`),
# since the resulting `MDB_val` is opaque to GC.
MDBValue() = MDB_val(zero(Csize_t), C_NULL)
MDBValue(::Nothing) = MDBValue()
MDBValue(val::String) =
    MDB_val(Csize_t(sizeof(val)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{UInt8}, val)))
MDBValue(val::AbstractArray{T}) where {T} =
    MDB_val(Csize_t(sizeof(T) * length(val)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, val)))
MDBValue(val::Base.RefValue{T}) where {T} =
    MDB_val(Csize_t(sizeof(T)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, val)))

# Auto-box bare `MDB_val` values at `Ptr{MDB_val}` ccall sites. This makes
# `mdb_put(..., MDBValue(rkey), ...)` work without an explicit `Ref(...)`
# wrap — equivalent to changing the @ccall signature to `Ref{MDB_val}`
# (which Clang.jl doesn't emit), routed through `cconvert` instead. Compare
# `base/refpointer.jl:178` for the same pattern on `Ptr{Ptr}` arg sites.
Base.cconvert(::Type{Ptr{MDB_val}}, x::MDB_val) = Ref(x)

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

"""Return a string describing a given error code

Function returns description of the error as a string. It accepts following arguments:
* `err::Int32`: An error code.
"""
function errormsg(err::Cint)
    errstr = mdb_strerror(err)
    return unsafe_string(errstr)
end

""" Check if binary flag is set in provided value"""
isflagset(value, flag) = (value & flag) == flag
