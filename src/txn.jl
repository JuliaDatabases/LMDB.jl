"""
A database transaction. Every operation requires a transaction handle.
All database operations require a transaction handle. Transactions may be read-only or read-write.
"""
mutable struct Transaction
    handle::Ptr{MDB_txn}
    Transaction() = new(C_NULL)
    Transaction(h::Ptr{MDB_txn}) = new(h)
end

function env(txn::Transaction)
    env_ptr = mdb_txn_env(txn.handle)
    (env_ptr == C_NULL) && return nothing
    return Environment(env_ptr)
end

"Check if transaction is open."
isopen(txn::Transaction) = txn.handle != C_NULL

"""Create a transaction for use with the environment

`start` function creates a new transaction and returns `Transaction` object.
It allows to set transaction flags with `flags` option.
"""
function start(env::Environment; flags::Cuint=zero(Cuint),
               parent::Union{Transaction,Nothing} = nothing)
    txn_ref = Ref{Ptr{MDB_txn}}(C_NULL)
    p = parent !== nothing ? parent.handle : Transaction().handle
    check(mdb_txn_begin(env.handle, p, flags, txn_ref))
    return Transaction(txn_ref[])
end
function start(f::Function, env::Environment; flags::EnvironmentFlags=Cuint(0))
    txn = start(env, flags=Cuint(flags))
    try
        r = f(txn)
        commit(txn)
        r
    catch e
        mdb_txn_abort(txn.handle)
        rethrow(e)
    end
end

"""Abandon all the operations of the transaction instead of saving them

The transaction and its cursors must not be used after, because its handle is freed.
"""
function abort(txn::Transaction)
    mdb_txn_abort(txn.handle)
    txn.handle = C_NULL
    return
end

"""Commit all the operations of a transaction into the database

The transaction and its cursors must not be used after, because its handle is freed.
"""
function commit(txn::Transaction)
    check(mdb_txn_commit(txn.handle))
    txn.handle = C_NULL
    return
end

"""Reset a read-only transaction

Abort the transaction like `abort`, but keep the transaction handle.
"""
function reset(txn::Transaction)
    mdb_txn_reset(txn.handle)
end

"""Renew a read-only transaction

This acquires a new reader lock for a transaction handle that had been released by `reset`.
It must be called before a reset transaction may be used again.
"""
function renew(txn::Transaction)
    check(mdb_txn_renew(txn.handle))
end
