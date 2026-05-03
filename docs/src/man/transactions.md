# Transactions

```@meta
CurrentModule = LMDB
```

Every LMDB operation runs inside a transaction. Transactions are either
**read-only** (any number can run concurrently) or **read-write** (one
at a time per environment).

## Starting a transaction

```julia
txn = start(env)                          # read-write
txn = start(env; flags = MDB_RDONLY)      # read-only
```

LMDB can hold one writer plus an unlimited number of readers
concurrently. Read txns do not block writers and vice versa.

The do-block form is the recommended shape — it commits on normal
return and aborts on throw:

```julia
result = start(env) do txn
    open(txn) do dbi
        put!(txn, dbi, "k", "v")
        tryget(txn, dbi, "k", String)
    end
end                                       # commits if no throw
```

## Commit / abort

`commit(txn)` writes the txn's modifications to disk and frees the
handle. `abort(txn)` discards them. Both are idempotent — calling them
twice (or on a never-started txn) is a silent no-op. `Transaction`'s
finalizer calls `abort`, so an abandoned write txn eventually releases
LMDB's exclusive write mutex.

After `commit` or `abort`, the txn (and any cursors created against it)
must not be used. Continuing to call `mdb_*` against a freed handle is
undefined behaviour.

## Read-only transactions

Read-only txns are cheap to start and stop, but for tight loops the
[`reset`](@ref Base.reset(::LMDB.Transaction)) / [`renew`](@ref renew)
pair is even cheaper:

```julia
txn = start(env; flags = MDB_RDONLY)
for batch in batches
    open(txn) do dbi
        for k in batch
            v = tryget(txn, dbi, k, String)
            handle(k, v)
        end
    end
    reset(txn)        # release the reader slot but keep the handle
    renew(txn)        # acquire a fresh slot — sees newly-committed writes
end
abort(txn)
```

`reset` is only valid on read-only txns; `renew` fetches a new snapshot
of the database. Without `renew`, the parked txn would not see writes
committed in the meantime.

## Sub-transactions

A read-write txn can spawn a child write txn that sees the parent's
uncommitted state. `commit` on the child folds its changes into the
parent; `abort` discards them, but the parent continues:

```julia
start(env) do parent
    open(parent) do dbi
        put!(parent, dbi, "before", "1")
        try
            start(env; parent = parent) do child
                put!(child, dbi, "during", "2")
                error("oops")             # abort propagates
            end
        catch
        end
        # "before" survives; "during" was rolled back
        @assert tryget(parent, dbi, "during", String) === nothing
    end
end
```

LMDB does not support nested *read-only* txns — pass a write txn as the
parent.

## Reader slots

Each open read txn occupies one reader slot. The default `maxreaders`
is small (126); raise it via `Environment(...; maxreaders = N)` for
high-concurrency read workloads, or call [`reader_check(env)`](@ref) to
reap slots left behind by crashed processes.

Aggressive `for … break` over an `LMDBDict` without GC pressure can
pile up read txns; the explicit
[`walk(f, cur)`](@ref API-Cur-walk) form inside an `open(txn) do …`
block is leak-free.

## Picking flags

The most common patterns:

```julia
# Hot read path — many small lookups, no writes
start(env; flags = MDB_RDONLY) do txn ... end

# Bulk import — single transaction across many writes (atomic, fast)
start(env) do txn ... end

# Long-running reader (e.g. background scrubber) — reset + renew loop
txn = start(env; flags = MDB_RDONLY)
while running
    ...
    reset(txn); renew(txn)
end
```
