export DBI, tryget, put_reserved!
@public flags

"""
A handle for an individual database in the DB environment.
"""
mutable struct DBI
    handle::MDB_dbi
    name::String
end

Base.cconvert(::Type{MDB_dbi}, d::DBI) = d.handle

"Check if database is open"
isopen(dbi::DBI) = dbi.handle != zero(Cuint)

"Open a database in the environment"
function open(txn::Transaction, dbname::String = ""; flags::Integer = zero(Cuint))
    cdbname = length(dbname) > 0 ? dbname : Ptr{Cchar}(C_NULL)
    handle = Ref{MDB_dbi}()
    mdb_dbi_open(txn, cdbname, Cuint(flags), handle)
    return DBI(handle[], dbname)
end

"Wrapper of DBI `open` for `do` construct"
function open(f::Function, txn::Transaction, dbname::String = ""; flags::Integer = zero(Cuint))
    dbi = open(txn, dbname, flags=Cuint(flags))
    tenv = env(txn)
    try
        f(dbi)
    finally
        close(tenv, dbi)
    end
end

"Close a database handle. Idempotent on both env and dbi."
function close(env::Environment, dbi::DBI)
    isopen(env) || return
    isopen(dbi) || return
    mdb_dbi_close(env, dbi)
    dbi.handle = zero(Cuint)
    return
end

"Retrieve the DB flags for a database handle"
function flags(txn::Transaction, dbi::DBI)
    flags = Ref{Cuint}(0)
    mdb_dbi_flags(txn, dbi, flags)
    return flags[]
end

function Base.show(io::IO, dbi::DBI)
    print(io, "DBI(")
    isempty(dbi.name) ? print(io, "<main>") : show(io, dbi.name)
    print(io, ", ", isopen(dbi) ? "open" : "closed", ")")
end

"""Empty or delete+close a database.

If parameter `delete` is `false` DB will be emptied, otherwise
DB will be deleted from the environment and DB handle will be closed
"""
function drop(txn::Transaction, dbi::DBI; delete = false)
    mdb_drop(txn, dbi, Cint(delete))
end

"Store items into a database"
function put!(txn::Transaction, dbi::DBI, key, val; flags::Integer = zero(Cuint))
    mdb_put(txn, dbi, key, val, Cuint(flags))
end

"""
    put_reserved!(f, txn::Transaction, dbi::DBI, key, size::Integer; flags=0)

Allocate `size` bytes of value space at `key` directly in LMDB's
mmap'd write buffer, then call `f(buf::Vector{UInt8})` so the caller
fills it in place. Equivalent to `put!` with the `MDB_RESERVE` flag,
without the intermediate `Vector{UInt8}` round-trip. Useful when the
value's bytes can be produced straight into a destination buffer (for
example, an `unsafe_store!` of a header followed by `copyto!` of a
payload). Equivalent to heed's `Database::put_reserved`.

`buf` is an `unsafe_wrap` over the LMDB-allocated page. It is *only
valid inside `f`* (and only inside the enclosing write txn). The
buffer's length is exactly `size`. Don't escape `buf` past `f`'s
return; copy what you want to keep.

Cannot be combined with `MDB_DUPSORT` or `MDB_DUPFIXED` databases,
since LMDB forbids `MDB_RESERVE` there.
"""
function put_reserved!(f, txn::Transaction, dbi::DBI, key, size::Integer;
                       flags::Integer = zero(Cuint))
    val_ref = Ref(MDB_val(Csize_t(size), C_NULL))
    mdb_put(txn, dbi, key, val_ref, Cuint(flags) | Cuint(MDB_RESERVE))
    v = val_ref[]
    buf = unsafe_wrap(Array, Ptr{UInt8}(v.mv_data), Int(v.mv_size))
    return f(buf)
end

"""
    delete!(txn::Transaction, dbi::DBI, key) -> Bool
    delete!(txn::Transaction, dbi::DBI, key, val) -> Bool

Delete `key` (or, in `MDB_DUPSORT`, the specific `(key, val)` pair) from
the database. Returns `true` if an entry was removed, `false` if the
key was not present. Other LMDB errors propagate as `LMDBError`.

The Bool-return, no-throw-on-miss shape matches `Base.delete!`'s "if
any" contract and the LMDB-binding convention shared by heed, py-lmdb,
lmdb-js, and lmdbxx.
"""
delete!(txn::Transaction, dbi::DBI, key) = _delete!(txn, dbi, key, MDBValue())
delete!(txn::Transaction, dbi::DBI, key, val) = _delete!(txn, dbi, key, val)
function _delete!(txn::Transaction, dbi::DBI, key, val_arg)
    ret = unchecked_mdb_del(txn, dbi, key, val_arg)
    ret == MDB_NOTFOUND && return false
    iszero(ret) || throw(LMDBError(ret))
    return true
end

"""
    stat(txn::Transaction, dbi::DBI) -> NamedTuple

Return statistics for the database referenced by `dbi` within `txn`:

| field            | meaning                                       |
|------------------|-----------------------------------------------|
| `psize`          | LMDB page size in bytes                       |
| `depth`          | B-tree depth                                  |
| `branch_pages`   | number of internal (non-leaf) pages           |
| `leaf_pages`     | number of leaf pages                          |
| `overflow_pages` | number of overflow pages (large values)       |
| `entries`        | total number of `(key, value)` data items     |

Live byte usage = `(branch_pages + leaf_pages + overflow_pages) * psize`.
"""
function stat(txn::Transaction, dbi::DBI)
    s_ref = Ref{MDB_stat}()
    mdb_stat(txn, dbi, s_ref)
    return stat_namedtuple(s_ref[])
end

"""Get an item from a database. Throws `LMDBError` if `key` is not present."""
@inline function get(txn::Transaction, dbi::DBI, key, ::Type{T}) where T
    val_ref = Ref(MDBValue())
    mdb_get(txn, dbi, key, val_ref)
    return Base.read(MDBValueIO(val_ref[]), T)
end

"""Get an item from a database, returning `nothing` if `key` is not present.
Use this in preference to `get` + try/catch when a missing key is expected."""
@inline function tryget(txn::Transaction, dbi::DBI, key, ::Type{T}) where T
    val_ref = Ref(MDBValue())
    ret = unchecked_mdb_get(txn, dbi, key, val_ref)
    ret == MDB_NOTFOUND && return nothing
    iszero(ret) || throw(LMDBError(ret))
    return Base.read(MDBValueIO(val_ref[]), T)
end

"""Get an item from a database, returning `default` if `key` is not present.
The signature mirrors `Base.get(dict, key, default)`."""
function get(txn::Transaction, dbi::DBI, key, ::Type{T}, default) where T
    v = tryget(txn, dbi, key, T)
    v === nothing ? default : v
end

"""
    replace!(txn::Transaction, dbi::DBI, key, val, ::Type{V}=typeof(val))
        -> Union{V,Nothing}

Atomically write `val` at `key`, returning the previous value (decoded as
`V`) or `nothing` if `key` was not present. Read and write share the same
transaction.
"""
function replace!(txn::Transaction, dbi::DBI, key, val,
                  ::Type{V}=typeof(val)) where V
    old = tryget(txn, dbi, key, V)
    put!(txn, dbi, key, val)
    return old
end

"""
    pop!(txn::Transaction, dbi::DBI, key, ::Type{T}) -> Union{T,Nothing}

Atomically read and delete the value at `key`, returning it (decoded as
`T`) or `nothing` if `key` was not present.
"""
function pop!(txn::Transaction, dbi::DBI, key, ::Type{T}) where T
    v = tryget(txn, dbi, key, T)
    v === nothing && return nothing
    delete!(txn, dbi, key)
    return v
end
