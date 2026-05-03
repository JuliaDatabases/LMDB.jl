# Environments

```@meta
CurrentModule = LMDB
```

An `Environment` corresponds to a single LMDB directory on disk and to
the in-process memory map of that directory. Every transaction,
database handle, and cursor lives inside one env.

## Creating and opening

The simplest path is the one-call constructor — it `create`s the
handle, applies optional configuration, and `open`s the directory in a
single call:

```julia
env = Environment("/tmp/mydb"; mapsize    = 1 << 30,   # 1 GiB virtual map
                               maxreaders = 510,
                               maxdbs     = 8,
                               flags      = MDB_NOTLS)
```

If anything fails between `create` and a successful `open`, the
partially constructed env is closed before rethrowing.

The split form is also available, mirroring the LMDB C API:

```julia
env = create()
env[:MapSize] = 1 << 30
env[:Readers] = 510
env[:DBs]     = 8
open(env, "/tmp/mydb"; flags = MDB_NOTLS)
```

The `[:Flags]`/`[:Readers]`/`[:MapSize]`/`[:DBs]` keys map directly to
`mdb_env_set_flags` / `mdb_env_set_maxreaders` / `mdb_env_set_mapsize`
/ `mdb_env_set_maxdbs`. `set!` / `unset!` flip individual flag bits
after the env is open.

`getindex` exposes a few read-only views: `env[:Flags]`,
`env[:Readers]`, and `env[:KeySize]` (the maximum key length, fixed at
compile time of the bundled `LMDB_jll`).

The do-block constructor `environment(f, path; flags, mode)` opens the
env, calls `f(env)`, and closes the env on the way out:

```julia
environment("/tmp/mydb"; flags = MDB_NOTLS) do env
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
| `MDB_WRITEMAP`   | mmap as writable; faster but requires more discipline (no torn writes from other processes) |
| `MDB_NOMEMINIT`  | skip zero-init of new pages |
| `MDB_NOTLS`      | drop thread-local reader slots — needed for multiple read txns on one thread |
| `MDB_NORDAHEAD`  | turn off OS-level read-ahead — better for cold-page workloads |
| `MDB_NOLOCK`     | the caller takes responsibility for locking |

`MDB_RDONLY` can only be set at `open` time — calling `set!(env,
MDB_RDONLY)` on an open env will return `EINVAL`.

## Sizing the map

The `mapsize` is a *virtual* limit on the env's address space, not the
on-disk size. A typical pattern is to pick a generous power of two
(say, 1 GiB or 8 GiB) up front; the on-disk file grows incrementally as
data is written.

If a write txn would exceed `mapsize`, LMDB returns `MDB_MAP_FULL`
(catchable via [`is_map_full(::LMDBError)`](@ref is_map_full)). The
remedy is to close the env, raise `mapsize`, and reopen — no rewrite
of the database is needed.

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

There is also a file-descriptor variant — `copy(env, fd)` — for
streaming the snapshot to a pipe or socket.

## Reader management

Each open read transaction occupies one reader slot. If a process
crashes without releasing its txns, the slots remain reserved until the
env is closed. `reader_check` reaps such stale slots and returns the
count of slots cleared:

```julia
n = reader_check(env)
@info "reaped $n stale readers"
```

`reader_list(env)` returns a human-readable dump of every active slot
(PID, thread, txn id) for diagnosing reader-table contention.
