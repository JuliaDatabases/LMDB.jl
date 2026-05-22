export Transaction
@public env, abort, commit, renew

"""
A database transaction. Every database operation requires a transaction.
Transactions may be read-only or read-write.

A `Transaction` keeps a reference to its parent `Environment`, both to
expose it via `env(txn)` and to ensure the env outlives the txn under
GC. A transaction dropped without an explicit `commit` or `abort` is
aborted by its finalizer.
"""
mutable struct Transaction
    handle::Ptr{MDB_txn}
    env::Environment
end

Base.unsafe_convert(::Type{Ptr{MDB_txn}}, t::Transaction) = t.handle

"Return the `Environment` this transaction was started against."
env(txn::Transaction) = txn.env

"Check if transaction is open."
isopen(txn::Transaction) = txn.handle != C_NULL

"""
    Transaction(env::Environment; flags=0, parent=nothing) -> Transaction

Begin a transaction against `env`. `flags` is forwarded to
`mdb_txn_begin` (e.g. `MDB_RDONLY` for a read-only txn). `parent` lets
you nest a write txn inside an existing one. Call `commit` to persist
or `abort` to discard; a dropped transaction is aborted by its
finalizer.
"""
function Transaction(env::Environment; flags::Integer = zero(Cuint),
                     parent::Union{Transaction,Nothing} = nothing)
    txn_ref = Ref{Ptr{MDB_txn}}(C_NULL)
    p = parent === nothing ? C_NULL : parent
    mdb_txn_begin(env, p, Cuint(flags), txn_ref)
    txn = Transaction(txn_ref[], env)
    # Track on the env so `close(env)` can abort us if the caller forgot.
    push!(env.txns, WeakRef(txn))
    finalizer(_finalize_txn, txn)
    return txn
end

"""
    Transaction(f::Function, env::Environment; kwargs...) -> result

`do`-block form: begin a transaction, run `f(txn)`, commit on a normal
return, abort if `f` throws. Returns whatever `f` returns.
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

"""Abandon all the operations of the transaction instead of saving them.

The transaction and its cursors must not be used afterward, because the handle is freed.
Idempotent: safe to call after a previous `commit` or `abort`, or on a never-opened txn.
"""
function abort(txn::Transaction)
    txn.handle == C_NULL && return
    # If env was closed first, `mdb_env_close` already freed the txn memory,
    # so the handle is dangling. Same defensive check as `close(::Cursor)`.
    isopen(txn.env) || (txn.handle = C_NULL; return)
    mdb_txn_abort(txn)
    txn.handle = C_NULL
    return
end

"""Commit all the operations of a transaction into the database.

The transaction and its cursors must not be used afterward, because the handle is freed.
Idempotent.
"""
function commit(txn::Transaction)
    txn.handle == C_NULL && return
    # mdb_txn_commit frees the txn handle whether it returns success or an
    # error (per lmdb.h). Null the wrapper out *before* the checked call can
    # throw, otherwise the finalizer would re-abort an already-freed pointer.
    ret = unchecked_mdb_txn_commit(txn)
    txn.handle = C_NULL
    check(ret)
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
