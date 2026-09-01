@public Transaction, env, abort, commit, renew

"""
An LMDB read or write transaction. The parent `Environment` is retained for
the transaction's lifetime. A live transaction is aborted when finalized.
"""
mutable struct Transaction
    handle::Ptr{MDB_txn}
    env::Environment
end

Base.unsafe_convert(::Type{Ptr{MDB_txn}}, t::Transaction) = t.handle

"Return the `Environment` this transaction was started against."
env(txn::Transaction) = txn.env

"Return whether the transaction is active."
isopen(txn::Transaction) = txn.handle != C_NULL

"""
    Transaction(env::Environment; flags=0, parent=nothing) -> Transaction

Begin a transaction in `env`. Pass `MDB_RDONLY` in `flags` for a read-only
transaction, or `parent` for a nested transaction.
"""
function Transaction(env::Environment; flags::Integer = zero(Cuint),
                     parent::Union{Transaction,Nothing} = nothing)
    txn_ref = Ref{Ptr{MDB_txn}}(C_NULL)
    p = parent === nothing ? C_NULL : parent
    mdb_txn_begin(env, p, Cuint(flags), txn_ref)
    txn = Transaction(txn_ref[], env)
    # Allow `close(env)` to end this transaction first.
    push!(env.txns, WeakRef(txn))
    finalizer(_finalize_txn, txn)
    return txn
end

"""
    Transaction(f::Function, env::Environment; kwargs...) -> result

Begin a transaction, call `f`, commit on return, and abort if `f` throws.
Return the result of `f`.
"""
function Transaction(f::Function, env::Environment;
                     flags::Integer = zero(Cuint),
                     parent::Union{Transaction,Nothing} = nothing)
    txn = Transaction(env; flags = Cuint(flags), parent)
    try
        r = f(txn)
        commit(txn)
        return r
    catch
        abort(txn)
        rethrow()
    end
end

"""Abort the transaction and free its handle. Repeated calls are no-ops."""
function abort(txn::Transaction)
    txn.handle == C_NULL && return
    # Closing the environment invalidates all child handles.
    isopen(txn.env) || (txn.handle = C_NULL; return)
    mdb_txn_abort(txn)
    txn.handle = C_NULL
    return
end

"""Commit the transaction and free its handle. Repeated calls are no-ops."""
function commit(txn::Transaction)
    txn.handle == C_NULL && return
    # LMDB frees the handle even when commit fails; clear it before throwing.
    ret = unchecked_mdb_txn_commit(txn)
    txn.handle = C_NULL
    check(ret)
    return
end

# Release a reader slot or the single-writer lock held by an abandoned txn.
_finalize_txn(t::Transaction) = abort(t)

"""Release a read-only transaction's snapshot while retaining its handle."""
function reset(txn::Transaction)
    mdb_txn_reset(txn)
end

"""Acquire a new snapshot for a read-only transaction after `reset`."""
function renew(txn::Transaction)
    check(mdb_txn_renew(txn))
end

Base.show(io::IO, txn::Transaction) =
    print(io, "Transaction(", isopen(txn) ? "open" : "closed", ")")
