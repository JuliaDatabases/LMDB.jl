# [Transactions](@id API-Txn)

```@meta
CurrentModule = LMDB
```

Every database operation runs inside a transaction. Transactions may be
read-only (`MDB_RDONLY`) or read-write; an environment supports many
concurrent readers but only one writer at a time.

## Construction

```@docs
Transaction
start
```

## Lifecycle

```@docs
commit
abort
Base.isopen(::Transaction)
env
```

## Read-only reuse

For read-only transactions, the txn handle can be parked across requests
to skip the begin/abort cost:

```@docs
Base.reset(::Transaction)
renew(::Transaction)
```

## Sub-transactions

Pass `parent = txn` to [`start`](@ref) to nest a child write transaction
inside an open write transaction. The child sees the parent's uncommitted
state; on `commit` the child's changes are folded into the parent, on
`abort` they are discarded.
