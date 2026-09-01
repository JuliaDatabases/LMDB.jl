@public Database, put_reserved!, flags

"""A database handle within an LMDB environment."""
mutable struct Database
    handle::MDB_dbi
    name::String
end

Base.cconvert(::Type{MDB_dbi}, d::Database) = d.handle

"Return whether the database handle is open."
isopen(dbi::Database) = dbi.handle != zero(Cuint)

"""
    Database(txn::Transaction, dbname::AbstractString = ""; flags=0) -> Database

Open `dbname` in `txn`; an empty name selects the main database. `flags` may
include database options such as `MDB_CREATE` and `MDB_DUPSORT`.
"""
function Database(txn::Transaction, dbname::AbstractString = "";
             flags::Integer = zero(Cuint))
    cdbname = length(dbname) > 0 ? String(dbname) : Ptr{Cchar}(C_NULL)
    handle = Ref{MDB_dbi}()
    mdb_dbi_open(txn, cdbname, Cuint(flags), handle)
    return Database(handle[], String(dbname))
end

"""
    Database(f::Function, txn::Transaction, dbname::AbstractString = ""; kwargs...) -> result

Open `dbname`, call `f`, and close the handle afterward. Return the result of
`f`.
"""
function Database(f::Function, txn::Transaction, dbname::AbstractString = "";
             flags::Integer = zero(Cuint))
    dbi = Database(txn, dbname; flags = Cuint(flags))
    tenv = env(txn)
    try
        f(dbi)
    finally
        close(tenv, dbi)
    end
end

"Close a database handle. Repeated calls are no-ops."
function close(env::Environment, dbi::Database)
    isopen(dbi) || return
    isopen(env) && mdb_dbi_close(env, dbi)
    dbi.handle = zero(Cuint)
    return
end

"Return the flags associated with a database handle."
function flags(txn::Transaction, dbi::Database)
    flags = Ref{Cuint}(0)
    mdb_dbi_flags(txn, dbi, flags)
    return flags[]
end

function Base.show(io::IO, dbi::Database)
    print(io, "Database(")
    isempty(dbi.name) ? print(io, "<main>") : show(io, dbi.name)
    print(io, ", ", isopen(dbi) ? "open" : "closed", ")")
end

"""
    drop(txn, dbi; delete=false)

Empty `dbi`, or delete the database and close its handle when `delete=true`.
"""
function drop(txn::Transaction, dbi::Database; delete = false)
    mdb_drop(txn, dbi, Cint(delete))
    delete && (dbi.handle = zero(Cuint))
    return nothing
end

"Store `val` at `key`."
function put!(txn::Transaction, dbi::Database, key, val; flags::Integer = zero(Cuint))
    mdb_put(txn, dbi, key, val, Cuint(flags))
end

"""
    put_reserved!(f, txn::Transaction, dbi::Database, key, size::Integer; flags=0)

Reserve `size` bytes of LMDB-managed value storage at `key` and call `f` with
a `Vector{UInt8}` view of it. The view is valid only during `f`; fill every
byte and do not retain it. `MDB_RESERVE` is not valid for `MDB_DUPSORT`
databases.
"""
function put_reserved!(f, txn::Transaction, dbi::Database, key, size::Integer;
                       flags::Integer = zero(Cuint))
    size >= 0 || throw(ArgumentError("reserved value size must be nonnegative"))
    val_ref = Ref(MDB_val(Csize_t(size), C_NULL))
    mdb_put(txn, dbi, key, val_ref, Cuint(flags) | Cuint(MDB_RESERVE))
    v = val_ref[]
    buf = unsafe_wrap(Array, Ptr{UInt8}(v.mv_data), Int(v.mv_size))
    return f(buf)
end

"""
    delete!(txn::Transaction, dbi::Database, key) -> Bool
    delete!(txn::Transaction, dbi::Database, key, val) -> Bool

Delete `key` (or, in `MDB_DUPSORT`, the specific `(key, val)` pair) from
the database. Returns `true` if an entry was removed, `false` if the
key was not present. Other LMDB errors propagate as `LMDBError`.

This method does not throw for `MDB_NOTFOUND`.
"""
delete!(txn::Transaction, dbi::Database, key) = _delete!(txn, dbi, key, MDBValue())
delete!(txn::Transaction, dbi::Database, key, val) = _delete!(txn, dbi, key, val)
function _delete!(txn::Transaction, dbi::Database, key, val_arg)
    ret = unchecked_mdb_del(txn, dbi, key, val_arg)
    ret == MDB_NOTFOUND && return false
    iszero(ret) || throw(LMDBError(ret))
    return true
end

"""
    stat(txn::Transaction, dbi::Database) -> NamedTuple

Return statistics for the database referenced by `dbi` within `txn`:

| field            | meaning                                       |
|------------------|-----------------------------------------------|
| `psize`          | LMDB page size in bytes                       |
| `depth`          | B-tree depth                                  |
| `branch_pages`   | number of internal (non-leaf) pages           |
| `leaf_pages`     | number of leaf pages                          |
| `overflow_pages` | number of overflow pages (large values)       |
| `entries`        | total number of `(key, value)` data items     |

"""
function stat(txn::Transaction, dbi::Database)
    s_ref = Ref{MDB_stat}()
    mdb_stat(txn, dbi, s_ref)
    return stat_namedtuple(s_ref[])
end

"""
    get(txn::Transaction, dbi::Database, key, ::Type{T}) -> T

Read the value at `key`, decoded as `T`. Throws `LMDBError` if `key`
isn't there, the same as `d[k]` on a regular `AbstractDict`.
"""
@inline function get(txn::Transaction, dbi::Database, key, ::Type{T}) where T
    val_ref = Ref(MDBValue())
    mdb_get(txn, dbi, key, val_ref)
    return Base.read(MDBValueIO(val_ref[]), T)
end

"""
    get(txn::Transaction, dbi::Database, key, ::Type{T}, default) -> Union{T,typeof(default)}

Read the value at `key`, decoded as `T`; return `default` if the key
isn't there. Mirrors `Base.get(dict, key, default)`. Pass `nothing`
as `default` for the `Union{T,Nothing}` form.
"""
@inline function get(txn::Transaction, dbi::Database, key, ::Type{T}, default) where T
    val_ref = Ref(MDBValue())
    ret = unchecked_mdb_get(txn, dbi, key, val_ref)
    ret == MDB_NOTFOUND && return default
    iszero(ret) || throw(LMDBError(ret))
    return Base.read(MDBValueIO(val_ref[]), T)
end

"""
    replace!(txn::Transaction, dbi::Database, key, val, ::Type{V}=typeof(val))
        -> Union{V,Nothing}

Atomically write `val` at `key`, returning the previous value (decoded as
`V`) or `nothing` if `key` was not present. Read and write share the same
transaction.
"""
function replace!(txn::Transaction, dbi::Database, key, val,
                  ::Type{V}=typeof(val)) where V
    old = get(txn, dbi, key, V, nothing)
    put!(txn, dbi, key, val)
    return old
end

"""
    pop!(txn::Transaction, dbi::Database, key, ::Type{T}) -> Union{T,Nothing}

Atomically read and delete the value at `key`, returning it (decoded as
`T`) or `nothing` if `key` was not present.
"""
function pop!(txn::Transaction, dbi::Database, key, ::Type{T}) where T
    v = get(txn, dbi, key, T, nothing)
    v === nothing && return nothing
    delete!(txn, dbi, key)
    return v
end
