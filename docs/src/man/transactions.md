# Transactions

```@meta
CurrentModule = LMDB
```

Every LMDB operation runs inside a transaction. Transactions are either
read-only (any number can run concurrently) or read-write (one at a
time per environment).

## Starting a transaction

```julia
txn = Transaction(env)                          # read-write
txn = Transaction(env; flags = LMDB.MDB_RDONLY) # read-only
```

LMDB can hold one writer plus an unlimited number of readers
concurrently. Read txns do not block writers and vice versa.

The do-block form commits on normal return and aborts on throw:

```julia
result = Transaction(env) do txn
    DBI(txn) do dbi
        put!(txn, dbi, "k", "v")
        get(txn, dbi, "k", String, nothing)
    end
end                                       # commits if no throw
```

## Commit / abort

`commit(txn)` writes the txn's modifications to disk and frees the
handle; `abort(txn)` discards them. Both are idempotent: calling them
twice, or on a never-started txn, is a silent no-op. `Transaction`'s
finalizer calls `abort`, so an abandoned write txn eventually releases
LMDB's exclusive write mutex.

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
    DBI(txn) do dbi
        for k in batch
            v = get(txn, dbi, k, String, nothing)
            handle(k, v)
        end
    end
    reset(txn)        # release the reader slot but keep the handle
    renew(txn)        # acquire a fresh slot; sees newly-committed writes
end
abort(txn)
```

`reset` is only valid on read-only txns. `renew` fetches a fresh
database snapshot. Without it, the parked txn won't see writes that
landed in the meantime.

## Sub-transactions

A read-write txn can spawn a child write txn that sees the parent's
uncommitted state. `commit` on the child folds its changes into the
parent; `abort` discards them, but the parent continues:

```julia
Transaction(env) do parent
    DBI(parent) do dbi
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

LMDB does not support nested *read-only* txns; the parent must be a
write txn.

## Reader slots

Each open read txn occupies one reader slot. The default `maxreaders`
is small (126). Raise it via `Environment(...; maxreaders = N)` for
high-concurrency read workloads, or call [`reader_check(env)`](@ref) to
reap slots left behind by crashed processes.

Aggressive `for … break` over an `LMDBDict` without GC pressure can
pile up read txns. If that becomes a problem, use
[`walk(f, cur)`](@ref API-Cur-walk) inside an explicit
`DBI(txn) do …` block instead.

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
