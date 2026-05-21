"""
A handle for an individual database in the DB environment.
"""
mutable struct DBI
    handle::MDB_dbi
    name::String
end

"Check if database is open"
isopen(dbi::DBI) = dbi.handle != zero(Cuint)

"Open a database in the environment"
function open(txn::Transaction, dbname::String = ""; flags::Cuint = zero(Cuint))
    cdbname = length(dbname) > 0 ? dbname : Ptr{Cchar}(C_NULL)
    handle = Ref{MDB_dbi}()
    mdb_dbi_open(txn.handle, cdbname, flags, handle)
    return DBI(handle[], dbname)
end

"Wrapper of DBI `open` for `do` construct"
function open(f::Function, txn::Transaction, dbname::String = ""; flags::Cuint = zero(Cuint))
    dbi = open(txn, dbname, flags=flags)
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
    _mdb_dbi_close(env.handle, dbi.handle)
    dbi.handle = zero(Cuint)
    return
end

"Retrieve the DB flags for a database handle"
function flags(txn::Transaction, dbi::DBI)
    flags = Ref{Cuint}(0)
    mdb_dbi_flags(txn.handle, dbi.handle, flags)
    return flags[]
end

"""Empty or delete+close a database.

If parameter `delete` is `false` DB will be emptied, otherwise
DB will be deleted from the environment and DB handle will be closed
"""
function drop(txn::Transaction, dbi::DBI; delete = false)
    del = Cint(delete)
    mdb_drop(txn.handle, dbi.handle, del)
end

toref(v) = isbitstype(typeof(v)) ? [v] : v
toref(v::Ptr{Nothing}) = v

"Store items into a database"
function put!(txn::Transaction, dbi::DBI, key, val; flags::Cuint = zero(Cuint))
    rkey = toref(key)
    rval = toref(val)
    GC.@preserve rkey rval begin
        mdb_key_ref = Ref(MDBValue(rkey))
        mdb_val_ref = Ref(MDBValue(rval))
        mdb_put(txn.handle, dbi.handle, mdb_key_ref, mdb_val_ref, flags)
    end
end

"Delete items from a database"
function delete!(txn::Transaction, dbi::DBI, key, val=C_NULL)
    rkey = toref(key)
    rval = val === C_NULL ? nothing : toref(val)
    GC.@preserve rkey rval begin
        mdb_key_ref = Ref(MDBValue(rkey))
        mdb_val_ref = val === C_NULL ? Ref(MDBValue()) : Ref(MDBValue(rval))
        mdb_del(txn.handle, dbi.handle, mdb_key_ref, mdb_val_ref)
    end
end

"Get items from a database"
function get(txn::Transaction, dbi::DBI, key, ::Type{T}) where T
    rkey = toref(key)
    GC.@preserve rkey begin
        mdb_key_ref = Ref(MDBValue(rkey))
        mdb_val_ref = Ref(MDBValue())
        mdb_get(txn.handle, dbi.handle, mdb_key_ref, mdb_val_ref)
        return mbd_unpack(T, mdb_val_ref)
    end
end
