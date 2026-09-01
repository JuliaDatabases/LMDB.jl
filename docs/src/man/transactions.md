# Transactions

```@meta
CurrentModule = LMDB
```

Every database operation runs inside a transaction. An environment permits
multiple readers, up to `maxreaders`, and one writer at a time.

## Starting a transaction

```julia
txn = Transaction(env)                          # read-write
txn = Transaction(env; flags = LMDB.MDB_RDONLY) # read-only
```

Readers do not block the writer, but they delay reuse of old database pages.

The do-block form commits on normal return and aborts on throw:

```julia
result = Transaction(env) do txn
    Database(txn) do dbi
        put!(txn, dbi, "k", "v")
        get(txn, dbi, "k", String, nothing)
    end
end                                       # commits if no throw
```

## Commit / abort

`commit(txn)` closes the transaction's cursors, publishes its modifications,
and frees the handle; durability depends on the environment's synchronization
flags. `abort(txn)` closes the cursors and discards the modifications. Repeated
calls are no-ops. A finalizer aborts an abandoned live transaction.

After `commit` or `abort`, the txn (and any cursors created against it)
must not be used. Continuing to call `mdb_*` against a freed handle is
undefined behaviour.

## Read-only transactions

Read-only txns are cheap to start and stop, but in a tight loop the
[`reset`](@ref Base.reset(::LMDB.Transaction)) / [`renew`](@ref renew)
pair is cheaper still:

```julia
txn = Transaction(env; flags = LMDB.MDB_RDONLY)
for batch in batches
    Database(txn) do dbi
        for k in batch
            v = get(txn, dbi, k, String, nothing)
            handle(k, v)
        end
    end
    reset(txn)        # release the snapshot but keep the handle
    renew(txn)        # acquire a new snapshot
end
abort(txn)
```

`reset` is only valid on a non-nested read-only transaction. With
`MDB_NOTLS`, its reader slot remains reserved for the handle. `renew` acquires
a new snapshot.

## Sub-transactions

A read-write txn can spawn a child write txn that sees the parent's
uncommitted state. `commit` on the child folds its changes into the
parent; `abort` discards them, but the parent continues:

```julia
Transaction(env) do parent
    Database(parent) do dbi
        put!(parent, dbi, "before", "1")
        try
            Transaction(env; parent = parent) do child
                put!(child, dbi, "during", "2")
                error("oops")             # abort propagates
            end
        catch
        end
        # "before" survives; "during" was rolled back
        @assert get(parent, dbi, "during", String, nothing) === nothing
    end
end
```

The parent must not be used while a child is active. Consult `mdb_txn_begin`
for the additional restrictions on read-only children.

## Reader slots

Each open read txn occupies one reader slot. The default `maxreaders`
is 126. Raise it via `Environment(...; maxreaders = N)` for
high-concurrency read workloads, or call [`reader_check(env)`](@ref) to
reap slots left behind by crashed processes.

Aggressive `for … break` over an `LMDBDict` without GC pressure can
pile up read txns. If that becomes a problem, use
[`walk(f, cur)`](@ref API-Cur-walk) inside an explicit
`Database(txn) do …` block instead.

## Picking flags

The most common patterns:

```julia
# Hot read path: many small lookups, no writes
Transaction(env; flags = LMDB.MDB_RDONLY) do txn ... end

# Bulk import: single transaction across many writes (atomic, fast)
Transaction(env) do txn ... end

# Long-running reader (e.g. background scrubber): reset + renew loop
txn = Transaction(env; flags = LMDB.MDB_RDONLY)
while running
    ...
    reset(txn); renew(txn)
end
```
