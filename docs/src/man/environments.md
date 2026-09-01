# Environments

```@meta
CurrentModule = LMDB
```

An `Environment` corresponds to a single LMDB directory on disk and to
the in-process memory map of that directory. Every transaction,
database handle, and cursor lives inside one env.

## Creating and opening

`Environment(path; kwargs...)` allocates the handle, applies the requested
settings, and opens the environment:

```julia
env = Environment("/tmp/mydb"; mapsize    = 1 << 30,   # 1 GiB virtual map
                               pagesize   = 8192,
                               maxreaders = 510,
                               maxdbs     = 8,
                               flags      = LMDB.MDB_NOTLS)
```

If setup or opening fails, the allocated handle is closed before rethrowing.

Before the env is open, `pagesize` maps to `mdb_env_set_pagesize`.
The `[:Flags]` / `[:Readers]` / `[:MapSize]` / `[:PageSize]` / `[:DBs]`
setindex! keys map to `mdb_env_set_flags` / `mdb_env_set_maxreaders` /
`mdb_env_set_mapsize` / `mdb_env_set_pagesize` / `mdb_env_set_maxdbs`,
and `set!` / `unset!` flip individual flag bits after open.

`getindex` exposes a few read-only views: `env[:Flags]`,
`env[:Readers]`, and `env[:KeySize]` (the maximum key length for the
environment's configured page size).

The do-block form `Environment(f, path; kwargs...)` opens the env,
calls `f(env)`, and closes on the way out:

```julia
Environment("/tmp/mydb"; flags = LMDB.MDB_NOTLS) do env
    # use env
end
```

## Common environment flags

`flags` accepts a bitwise-or of:

| flag | meaning |
|------|---------|
| `MDB_RDONLY`     | open the env in read-only mode |
| `MDB_NOSUBDIR`   | `path` is a single file, not a directory |
| `MDB_NOSYNC`     | don't `fsync` on commit (faster, less durable) |
| `MDB_NOMETASYNC` | `fsync` data but not metadata |
| `MDB_WRITEMAP`   | write directly to the memory map; incompatible with nested transactions |
| `MDB_NOMEMINIT`  | skip zero-init of new pages |
| `MDB_NOTLS`      | tie reader slots to transactions rather than threads |
| `MDB_NORDAHEAD`  | turn off OS-level read-ahead |
| `MDB_NOLOCK`     | the caller takes responsibility for locking |

`MDB_RDONLY` can only be set at `open` time. Calling `set!(env,
LMDB.MDB_RDONLY)` on an open env will return `EINVAL`.

## Sizing the map

`mapsize` reserves virtual address space and limits database growth; it is not
the initial on-disk size. Choose a value large enough for expected growth.

LMDB 1.0 also lets you choose the DB page size with `pagesize`. The
default is the OS page size; larger values can allow larger keys and
`MDB_DUPSORT` data items. After opening, `stat(env).psize` reports the
actual page size and `env[:KeySize]` reports the corresponding maximum
key size.

If a write transaction exceeds `mapsize`, LMDB returns `MDB_MAP_FULL`.
Increase the map with no active transactions; reopening the environment is
not required.

## Inspection

```julia
ei = info(env)
@show ei.mapsize, ei.last_pgno, ei.numreaders

s = stat(env)
@show s.psize, s.depth, s.entries
```

[`info`](@ref) and [`stat`](@ref Base.stat(::LMDB.Environment)) both
return `NamedTuple`s; see their docstrings for the field layout.

## Backup

[`copy(env, path)`](@ref Base.copy(::LMDB.Environment, ::AbstractString))
takes a hot, transactionally consistent snapshot of the environment to
another directory. With `compact = true`, free-space pages are omitted
and the destination is approximately the size of the live data set:

```julia
copy(env, "/backup/mydb-snapshot"; compact = true)
```

A file-descriptor variant, `copy(env, fd)`, streams the snapshot to a
pipe or socket.

## Reader management

Each open read transaction uses a reader slot. `reader_check` clears slots
left by dead processes and returns the number cleared:

```julia
n = reader_check(env)
@info "reaped $n stale readers"
```

`reader_list(env)` returns LMDB's human-readable reader-table dump.
