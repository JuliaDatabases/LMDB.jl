module LMDB

import Base: open, close, getindex, setindex!, put!, reset,
             isopen, count, delete!, keys, get, show, show
import Base.Iterators: drop

export Environment, create, open, close, sync, set!, unset!, getindex, setindex!, path, info, show,
       Transaction, start, abort, commit, reset, renew, environment,
       DBI, drop, delete!, keys, get, put!,
       Cursor, count, transaction, database,
       isflagset, isopen,
       LMDBError, CursorOps, LMDBDict

include("liblmdb.jl")

"""LMDB exception type"""
struct LMDBError <: Exception
    code::Cint
    msg::AbstractString
    LMDBError(code::Integer) = new(Cint(code), errormsg(Cint(code)))
    LMDBError(code::Integer, msg::AbstractString) = new(Cint(code), msg)
end
show(io::IO, err::LMDBError) = print(io, "Code[$(err.code)]: $(err.msg)")

"Throw an `LMDBError` if `code` is non-zero. Returns `code` otherwise."
@inline check(code) = iszero(code) ? code : throw(LMDBError(code))

include("common.jl")
include("env.jl")
include("txn.jl")
include("dbi.jl")
include("cur.jl")
include("dicts.jl")

end # module
