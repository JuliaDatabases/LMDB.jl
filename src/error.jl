export LMDBError, is_notfound, is_keyexist, is_map_full

"""LMDB exception type. `code` is the raw status code; use `is_notfound`,
`is_keyexist`, `is_map_full` for common matches."""
struct LMDBError <: Exception
    code::Cint
    msg::AbstractString
    LMDBError(code::Integer) = new(Cint(code), errormsg(Cint(code)))
    LMDBError(code::Integer, msg::AbstractString) = new(Cint(code), msg)
end
show(io::IO, err::LMDBError) = print(io, "Code[$(err.code)]: $(err.msg)")

"Throw an `LMDBError` if `code` is non-zero. Returns `code` otherwise."
@inline check(code) = iszero(code) ? code : throw(LMDBError(code))

"""Return a string describing a given LMDB status code."""
errormsg(err::Cint) = unsafe_string(mdb_strerror(err))

# Applied to a C-API binding that returns an LMDB status code (`Cint`).
# Emits two functions:
#
#   * `<fname>(...)`           same name, throws `LMDBError` on a non-zero
#                              status; returns the status (always 0) otherwise.
#   * `unchecked_<fname>(...)` returns the raw status; the caller decides what
#                              to do (e.g. branch on `MDB_NOTFOUND`).
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

"""
    is_notfound(err::LMDBError) -> Bool

`true` if `err.code == MDB_NOTFOUND` (LMDB's "key not present" status).

Use this to recover from a missing key when the lookup is not point-typed
(otherwise `tryget` / `get(..., default)` are simpler):

```julia
try
    LMDB.get(txn, dbi, "key", String)
catch e
    e isa LMDBError && is_notfound(e) || rethrow()
    # treat as missing
end
```
"""
is_notfound(err::LMDBError) = err.code == MDB_NOTFOUND

"""
    is_keyexist(err::LMDBError) -> Bool

`true` if `err.code == MDB_KEYEXIST`. Raised by `put!` with `MDB_NOOVERWRITE`
or `MDB_NODUPDATA` when the key (or duplicate) is already present.
"""
is_keyexist(err::LMDBError) = err.code == MDB_KEYEXIST

"""
    is_map_full(err::LMDBError) -> Bool

`true` if `err.code == MDB_MAP_FULL`. Raised when a write txn would exceed
the environment's `MapSize`. The remedy is to grow `mapsize` (which can be
done after `close(env)` without rewriting the database).
"""
is_map_full(err::LMDBError) = err.code == MDB_MAP_FULL
