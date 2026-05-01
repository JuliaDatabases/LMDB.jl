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
function open(txn::Transaction, dbname::String = ""; flags::Cuint = zero(Cuint))
    cdbname = length(dbname) > 0 ? dbname : Ptr{Cchar}(C_NULL)
    handle = Ref{MDB_dbi}()
    check(mdb_dbi_open(txn, cdbname, flags, handle))
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
    mdb_dbi_close(env, dbi)
    dbi.handle = zero(Cuint)
    return
end

"Retrieve the DB flags for a database handle"
function flags(txn::Transaction, dbi::DBI)
    flags = Ref{Cuint}(0)
    check(mdb_dbi_flags(txn, dbi, flags))
    return flags[]
end

"""Empty or delete+close a database.

If parameter `delete` is `false` DB will be emptied, otherwise
DB will be deleted from the environment and DB handle will be closed
"""
function drop(txn::Transaction, dbi::DBI; delete = false)
    check(mdb_drop(txn, dbi, Cint(delete)))
end

"Store items into a database"
function put!(txn::Transaction, dbi::DBI, key, val; flags::Cuint = zero(Cuint))
    rkey = isbitstype(typeof(key)) ? Ref(key) : key
    rval = isbitstype(typeof(val)) ? Ref(val) : val
    GC.@preserve rkey rval begin
        check(mdb_put(txn, dbi, MDBValue(rkey), MDBValue(rval), flags))
    end
end

"Delete items from a database"
function delete!(txn::Transaction, dbi::DBI, key, val=C_NULL)
    rkey = isbitstype(typeof(key)) ? Ref(key) : key
    rval = val === C_NULL ? nothing :
           isbitstype(typeof(val)) ? Ref(val) : val
    GC.@preserve rkey rval begin
        val_arg = rval === nothing ? MDBValue() : MDBValue(rval)
        check(mdb_del(txn, dbi, MDBValue(rkey), val_arg))
    end
end

"Get items from a database"
function get(txn::Transaction, dbi::DBI, key, ::Type{T}) where T
    rkey = isbitstype(typeof(key)) ? Ref(key) : key
    GC.@preserve rkey begin
        val_ref = Ref(MDBValue())
        check(mdb_get(txn, dbi, MDBValue(rkey), val_ref))
        return mbd_unpack(T, val_ref)
    end
end
