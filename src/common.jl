const MBDValue = MDB_val
const EnvironmentFlags = Unsigned
MDBValue() = MDB_val(zero(Csize_t), C_NULL)
MDBValue(_::Nothing) = MDBValue()
MDBValue(val::String) = MDB_val(Csize_t(sizeof(val)), convert(Ptr{Cvoid},pointer(val)))
function MDBValue(val::T) where {T}
    isbitstype(T) && error("Can not wrap a $T in MDBValue. Use a $T array instead")
    val_size = sizeof(eltype(val))*length(val)
    return MDB_val(Csize_t(val_size), convert(Ptr{Cvoid},pointer(val)))
end

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
