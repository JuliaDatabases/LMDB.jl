"""
A database transaction. Every database operation requires a transaction.
Transactions may be read-only or read-write.

A `Transaction` keeps a reference to its parent `Environment`, both to
expose it via `env(txn)` and to ensure the env outlives the txn under
GC. If a transaction is dropped without an explicit `commit` or `abort`,
its finalizer aborts it.
"""
mutable struct Transaction
    handle::Ptr{MDB_txn}
    env::Environment
    function Transaction(env::Environment, h::Ptr{MDB_txn})
        t = new(h, env)
        finalizer(_finalize_txn, t)
        return t
    end
end

Base.unsafe_convert(::Type{Ptr{MDB_txn}}, t::Transaction) = t.handle

"Return the `Environment` this transaction was started against."
env(txn::Transaction) = txn.env

"Check if transaction is open."
isopen(txn::Transaction) = txn.handle != C_NULL

"""Create a transaction for use with the environment

`start` function creates a new transaction and returns `Transaction` object.
It allows to set transaction flags with `flags` option.
"""
function start(env::Environment; flags::Cuint=zero(Cuint),
               parent::Union{Transaction,Nothing} = nothing)
    txn_ref = Ref{Ptr{MDB_txn}}(C_NULL)
    p = parent === nothing ? C_NULL : parent
    mdb_txn_begin(env, p, Cuint(flags), txn_ref)
    return Transaction(env, txn_ref[])
end
function start(f::Function, env::Environment; flags::EnvironmentFlags=Cuint(0))
    txn = start(env, flags=Cuint(flags))
    try
        r = f(txn)
        commit(txn)
        r
    catch e
        abort(txn)
        rethrow(e)
    end
end

"""Abandon all the operations of the transaction instead of saving them.

The transaction and its cursors must not be used after, because its handle is freed.
Idempotent — safe to call after a previous `commit`/`abort` or on a never-opened txn.
"""
function abort(txn::Transaction)
    txn.handle == C_NULL && return
    mdb_txn_abort(txn)
    txn.handle = C_NULL
    return
end

"""Commit all the operations of a transaction into the database.

The transaction and its cursors must not be used after, because its handle is freed.
Idempotent.
"""
function commit(txn::Transaction)
    txn.handle == C_NULL && return
    mdb_txn_commit(txn)
    txn.handle = C_NULL
    return
end

# Finalizer: aborts a still-open transaction so it doesn't leak an LMDB
# reader slot or block subsequent write txns.
_finalize_txn(t::Transaction) = abort(t)

"""Reset a read-only transaction

Abort the transaction like `abort`, but keep the transaction handle.
"""
function reset(txn::Transaction)
    mdb_txn_reset(txn)
end

"""Renew a read-only transaction

This acquires a new reader lock for a transaction handle that had been released by `reset`.
It must be called before a reset transaction may be used again.
"""
function renew(txn::Transaction)
    check(mdb_txn_renew(txn))
end

Base.show(io::IO, txn::Transaction) =
    print(io, "Transaction(", isopen(txn) ? "open" : "closed", ")")
