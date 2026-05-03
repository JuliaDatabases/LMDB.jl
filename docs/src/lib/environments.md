# [Environments](@id API-Env)

```@meta
CurrentModule = LMDB
```

An `Environment` wraps an LMDB env handle (`Ptr{MDB_env}`). It is the
top of the handle hierarchy — every transaction, database, and cursor
ultimately lives inside one env.

## Construction

```@docs
Environment
Environment(::AbstractString)
create
environment
```

## Lifecycle

```@docs
Base.open(::Environment, ::String)
Base.close(::Environment)
Base.isopen(::Environment)
sync
path
```

## Configuration

`Environment` exposes its tunables through `getindex` / `setindex!` with
symbol keys (`:Flags`, `:Readers`, `:MapSize`, `:DBs`, `:KeySize`):

```@docs
Base.setindex!(::Environment, ::Integer, ::Symbol)
Base.getindex(::Environment, ::Symbol)
set!
unset!
```

## Inspection

```@docs
info
Base.stat(::Environment)
```

## Backup

```@docs
Base.copy(::Environment, ::AbstractString)
```

## Reader management

```@docs
reader_check
reader_list
```
