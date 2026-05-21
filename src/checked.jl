# Applied to a tier-1 binding that returns an LMDB status code (`Cint`).
# Emits two functions:
#
#   * `<fname>(...)`           — same name, throws `LMDBError` on a non-zero
#                                status; returns the status (always 0) otherwise.
#   * `unchecked_<fname>(...)` — returns the raw status; the caller decides what
#                                to do (e.g. branch on `MDB_NOTFOUND`).
#
# Used in `liblmdb.jl` for every binding whose return type is a status. Bindings
# that return a value (`mdb_strerror`, `mdb_txn_id`, comparators, …) or are
# `Cvoid` are left bare.
macro checked(ex)
    Meta.isexpr(ex, :function) ||
        throw(ArgumentError("@checked expects a function definition"))
    sig, body = ex.args
    Meta.isexpr(sig, :call) ||
        throw(ArgumentError("@checked expects a method definition with a call signature"))
    fname = sig.args[1]
    args = sig.args[2:end]
    unchecked_name = Symbol("unchecked_", fname)
    unchecked_sig = Expr(:call, unchecked_name, args...)
    safe_def = Expr(:function, sig, quote
        ret = $body
        iszero(ret) ? ret : throw(LMDBError(Cint(ret)))
    end)
    unchecked_def = Expr(:function, unchecked_sig, body)
    esc(Expr(:block, safe_def, unchecked_def))
end
