module LMDB

import Base: open, close, getindex, setindex!, put!, pop!, replace!, reset, copy,
             isopen, count, delete!, keys, get, show, stat

export Environment, create, open, close, sync, set!, unset!, getindex, setindex!, path, info, stat, show,
       reader_check, reader_list, copy,
       Transaction, start, abort, commit, reset, renew, environment,
       DBI, drop, delete!, keys, get, put!, tryget, replace!, pop!,
       Cursor, count, transaction, database,
       seek_first_dup!, seek_last_dup!,
       next_dup!, prev_dup!, next_nodup!, prev_nodup!,
       isflagset, isopen,
       LMDBError, LMDBDict

# ---------------------------------------------------------------------------
# Error type. Defined here so the `@checked` macro can reference it; the
# constructor itself defers to `errormsg` (defined after `liblmdb.jl` once
# `mdb_strerror` is in scope).
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Tier 1 — raw bindings, types, constants. Public-but-unexported.
#
# Every status-returning binding has a `@checked` wrapper (auto-throws) and an
# `unchecked_*` companion (returns the raw `Cint` for callers that need to
# inspect it, e.g. branching on `MDB_NOTFOUND`).
#
# Use as `LMDB.mdb_env_create`, `LMDB.MDB_NOTLS`, `LMDB.MDB_val`. Mostly
# relevant to power users; tier 2 (`Environment`, `Transaction`, …) is the
# recommended surface.
# ---------------------------------------------------------------------------

include("checked.jl")
include("liblmdb.jl")

"""Return a string describing a given LMDB status code."""
errormsg(err::Cint) = unsafe_string(mdb_strerror(err))

# Common status-code matchers, mirroring `is_notfound`/`is_keyexist` patterns.
is_notfound(err::LMDBError) = err.code == MDB_NOTFOUND
is_keyexist(err::LMDBError) = err.code == MDB_KEYEXIST
is_map_full(err::LMDBError) = err.code == MDB_MAP_FULL

# ---------------------------------------------------------------------------
# Tier 1.5 — ccall glue.
# ---------------------------------------------------------------------------

include("common.jl")

# ---------------------------------------------------------------------------
# Tier 2 — Julian wrappers around the raw bindings.
# ---------------------------------------------------------------------------

include("env.jl")
include("txn.jl")
include("dbi.jl")
include("cur.jl")

# ---------------------------------------------------------------------------
# Tier 3 — high-level convenience.
# ---------------------------------------------------------------------------

include("dicts.jl")

end # module
