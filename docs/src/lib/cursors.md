# [Cursors](@id API-Cur)

```@meta
CurrentModule = LMDB
```

A `Cursor` is a positioned iterator over the entries in a `DBI`. Cursors
are bound to a transaction; closing the txn invalidates the cursor.

## Construction

```@docs
Cursor
Base.open(::Transaction, ::DBI)
Base.close(::Cursor)
Base.isopen(::Cursor)
renew(::Transaction, ::Cursor)
transaction
database
```

## Navigation

```@docs
seek!
seek_last!
seek_range!
next!
prev!
```

## Current-position accessors

```@docs
key
value
item
```

## [Bulk walk](@id API-Cur-walk)

```@docs
walk
```

## [DUPSORT navigation](@id API-Cur-DUPSORT)

These are only meaningful when the database was opened with
`MDB_DUPSORT`. See [Duplicate-sort databases](@ref) for the data model.

```@docs
seek_first_dup!
seek_last_dup!
next_dup!
prev_dup!
next_nodup!
prev_nodup!
```

## Mutation

```@docs
Base.put!(::Cursor, ::Any, ::Any)
Base.delete!(::Cursor)
Base.count(::Cursor)
```
