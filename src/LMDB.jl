module LMDB

import Base: open, close, getindex, setindex!, put!, pop!, replace!, reset,
             isopen, count, delete!, keys, get, show, show, stat, copy,
             empty!, length, isempty, iterate, haskey
import Base.Iterators: drop

export
    # error type + matchers
    LMDBError, is_notfound, is_keyexist, is_map_full,

    # commonly-needed status codes
    MDB_NOTFOUND, MDB_KEYEXIST, MDB_MAP_FULL,

    # commonly-needed env flags
    MDB_RDONLY, MDB_NOTLS, MDB_NORDAHEAD, MDB_NOSUBDIR,
    MDB_NOSYNC, MDB_NOMETASYNC, MDB_WRITEMAP, MDB_NOMEMINIT,

    # commonly-needed db flags
    MDB_CREATE, MDB_DUPSORT, MDB_INTEGERKEY, MDB_REVERSEKEY,
    MDB_DUPFIXED, MDB_INTEGERDUP, MDB_REVERSEDUP,

    # commonly-needed write flags
    MDB_NOOVERWRITE, MDB_NODUPDATA, MDB_APPEND, MDB_RESERVE,

    # Julia API — environment
    Environment, create, environment,
    sync, set!, unset!, info, stat, path, isopen, isflagset,
    reader_check, reader_list,

    # Julia API — transaction
    Transaction, start, abort, commit, reset, renew,

    # Julia API — database (DBI)
    DBI, drop, get, put!, put_reserved!, delete!, tryget, replace!,

    # Julia API — cursor
    Cursor, count, transaction, database,
    seek!, seek_last!, seek_range!, next!, prev!,
    key, value, item, walk,
    seek_first_dup!, seek_last_dup!,
    next_dup!, prev_dup!, next_nodup!, prev_nodup!,

    # High-level abstractions
    LMDBDict

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
is_notfound

"""
    is_keyexist(err::LMDBError) -> Bool

`true` if `err.code == MDB_KEYEXIST`. Raised by `put!` with `MDB_NOOVERWRITE`
or `MDB_NODUPDATA` when the key (or duplicate) is already present.
"""
is_keyexist

"""
    is_map_full(err::LMDBError) -> Bool

`true` if `err.code == MDB_MAP_FULL`. Raised when a write txn would exceed
the environment's `MapSize`. The remedy is to grow `mapsize` (which can be
done after `close(env)` without rewriting the database).
"""
is_map_full

# ---------------------------------------------------------------------------
# C API — raw bindings, types, constants. Public-but-unexported.
#
# Every status-returning binding has a `@checked` wrapper (auto-throws) and an
# `unchecked_*` companion (returns the raw `Cint` for callers that need to
# inspect it, e.g. branching on `MDB_NOTFOUND`).
#
# Use as `LMDB.mdb_env_create`, `LMDB.MDB_NOTLS`, `LMDB.MDB_val`. Mostly
# relevant to power users; the Julia API (`Environment`, `Transaction`, …) is
# the recommended surface.
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
# ccall glue between the C API and the Julia API: `MDBValue`, `MDBArg`, and
# the `MDBValueIO <: IO` extension point used to plug in custom decoders via
# `Base.read(io, T)`.
# ---------------------------------------------------------------------------

include("common.jl")

# ---------------------------------------------------------------------------
# Julia API — Julian wrappers around the raw bindings.
# ---------------------------------------------------------------------------

include("env.jl")
include("txn.jl")
include("dbi.jl")
include("cur.jl")

# ---------------------------------------------------------------------------
# High-level abstractions — `LMDBDict`.
# ---------------------------------------------------------------------------

include("dicts.jl")

end # module
