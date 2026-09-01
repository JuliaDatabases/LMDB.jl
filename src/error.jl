export LMDBError

"""LMDB exception type. `code` is the raw status code."""
struct LMDBError <: Exception
    code::Cint
    msg::AbstractString
    LMDBError(code::Integer) = new(Cint(code), unsafe_string(mdb_strerror(code)))
end
Base.showerror(io::IO, err::LMDBError) =
    print(io, "LMDBError(", err.code, "): ", err.msg)

"Throw an `LMDBError` if `code` is non-zero. Returns `code` otherwise."
@inline check(code) = iszero(code) ? code : throw(LMDBError(code))

# Applied to a binding with LMDB's usual zero-success status convention. Emits:
#
#   * `<fname>(...)`           same name, throws `LMDBError` on a non-zero
#                              status; returns the status (always 0) otherwise.
#   * `unchecked_<fname>(...)` returns the raw status; the caller decides what
#                              to do (e.g. branch on `MDB_NOTFOUND`).
#
# Bindings that return data or `Cvoid` are left bare.
function checked_def(ex, nonnegative::Bool, macro_name::String)
    Meta.isexpr(ex, :function) ||
        throw(ArgumentError("$macro_name expects a function definition"))
    sig, body = ex.args
    Meta.isexpr(sig, :call) ||
        throw(ArgumentError("$macro_name expects a method definition with a call signature"))
    fname = sig.args[1]
    args = sig.args[2:end]
    unchecked_name = Symbol("unchecked_", fname)
    unchecked_sig = Expr(:call, unchecked_name, args...)
    validate = nonnegative ? :(ret < 0 && throw(LMDBError(ret))) : :(check(ret))
    safe_body = quote
        ret = $body
        $validate
        ret
    end
    safe_def = Expr(:function, sig, safe_body)
    unchecked_def = Expr(:function, unchecked_sig, body)
    return Expr(:block, safe_def, unchecked_def)
end

macro checked(ex)
    esc(checked_def(ex, false, "@checked"))
end

# `mdb_reader_list` returns a negative error or the callback's nonnegative
# return value, so its checked form must accept positive values.
macro checked_nonnegative(ex)
    esc(checked_def(ex, true, "@checked_nonnegative"))
end
