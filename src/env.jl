export Environment, create, environment,
       sync, set!, unset!, info,
       reader_check, reader_list
@public path

"""
A DB environment supports multiple databases, all residing in the same shared-memory map.

Wrapping a raw `Ptr{MDB_env}` in `Environment(h)` takes ownership of the
handle. The handle is closed when the wrapper is garbage-collected, unless
`close` was already called explicitly. Closing is idempotent.
"""
mutable struct Environment
    handle::Ptr{MDB_env}
    path::String
    # Live transactions, tracked weakly so they remain GC-able. `close`
    # walks this list to abort any still-open txn before calling
    # `mdb_env_close`; otherwise LMDB corrupts state shared across envs.
    txns::Vector{WeakRef}
    function Environment(h::Ptr{MDB_env} = C_NULL)
        e = new(h, "", WeakRef[])
        finalizer(close, e)
        return e
    end
end

Base.unsafe_convert(::Type{Ptr{MDB_env}}, e::Environment) = e.handle

"Return the path that was used in `open`"
path(env::Environment) = env.path

"Check if environment is open"
isopen(env::Environment) = env.handle != C_NULL

"Create an LMDB environment handle"
function create()
    env_ref = Ref{Ptr{MDB_env}}()
    mdb_env_create(env_ref)
    return Environment(env_ref[])
end

"Wrapper of `create` for `do` construct"
function create(f::Function)
    env = create()
    try
        f(env)
    finally
        close(env)
    end
end

"""Open an environment handle

`open` function accepts folowing parameters:
* `env` db environment object
* `path` directory in which the database files reside
* `flags` defines special options for the environment
* `mode` UNIX permissions to set on created files

*Note:* A database directory must exist and be writable.
"""
function open(env::Environment, path::String; flags::Integer=zero(Cuint),
              mode::Integer = mode_t(0o755))
    env.path = path
    mdb_env_open(env, path, Cuint(flags), mode_t(mode))
end

"Wrapper of `open` for `do` construct"
function environment(f::Function, path::String; flags::Integer=zero(Cuint),
                     mode::Integer = mode_t(0o755))
    env = create()
    try
        open(env, path; flags = Cuint(flags), mode = mode_t(mode))
        f(env)
    finally
        close(env)
    end
end

"""
    Environment(path::AbstractString; mapsize=nothing, maxreaders=nothing,
                maxdbs=nothing, flags=0, mode=0o755) -> Environment

One-call equivalent of `create()`, optional `setindex!` for `MapSize`,
`Readers`, or `DBs`, and `open(env, path)`. Mirrors py-lmdb's
`Environment(path, **kwargs)` and lmdb-rs's `EnvironmentBuilder.open(path)`.

If anything fails between `create` and a successful `open`, the partially
constructed environment is closed before rethrowing.
"""
function Environment(path::AbstractString; mapsize::Union{Integer,Nothing} = nothing,
                     maxreaders::Union{Integer,Nothing} = nothing,
                     maxdbs::Union{Integer,Nothing} = nothing,
                     flags::Integer = zero(Cuint),
                     mode::Integer = mode_t(0o755))
    env = create()
    try
        mapsize    === nothing || (env[:MapSize] = mapsize)
        maxreaders === nothing || (env[:Readers] = maxreaders)
        maxdbs     === nothing || (env[:DBs]     = maxdbs)
        open(env, String(path); flags = Cuint(flags), mode = mode_t(mode))
    catch
        close(env)
        rethrow()
    end
    return env
end

"""Close the environment and release the memory map.

Idempotent: calling `close` on an already-closed `Environment` is a
silent no-op, matching the convention of `close(::IO)`. That makes
finalizers safe to run after an explicit close.
"""
function close(env::Environment)
    env.handle == C_NULL && return zero(Cint)
    # LMDB requires all transactions to be closed before `mdb_env_close`;
    # otherwise it leaves shared lockfile/heap state corrupted and the
    # next env-open in the process can crash inside `mdb_txn_renew0`.
    for wr in env.txns
        t = wr.value
        t isa Transaction && t.handle != C_NULL && abort(t)
    end
    empty!(env.txns)
    mdb_env_close(env)
    env.handle = C_NULL
    env.path = ""
    return zero(Cint)
end

"""Flush the data buffers to disk"""
function sync(env::Environment, force::Bool = false)
    fval = force ? 1 : 0
    mdb_env_sync(env, fval)
    return zero(Cint)
end

"""Set environment flags"""
function set!(env::Environment, flag::Integer)
    mdb_env_set_flags(env, Cuint(flag), one(Cint))
    return flag
end

"""Unset environment flags"""
function unset!(env::Environment, flag::Integer)
    mdb_env_set_flags(env, Cuint(flag), zero(Cint))
    return flag
end


"""Set environment flags and parameters

`setindex!` accepts folowing parameters:
* `env` db environment object
* `option` symbol which indicates parameter. Currently supported parameters:
    * Flags
    * Readers
    * MapSize
    * DBs
* `value` parameter value

**Note:** Consult LMDB documentation for particual values of environment parameters and flags.
"""
function setindex!(env::Environment, val::Integer, option::Symbol)
    if option == :Flags
        set!(env, Cuint(val))
    elseif option == :Readers
        mdb_env_set_maxreaders(env, Cuint(val))
    elseif option == :MapSize
        # MDB_env_set_mapsize takes a size_t; using Cuint truncates >4 GiB
        # maps on 64-bit platforms (issue #38, PRs #37 / #40).
        mdb_env_set_mapsize(env, Csize_t(val))
    elseif option == :DBs
        mdb_env_set_maxdbs(env, Cuint(val))
    else
        throw(ArgumentError("Unsupported environment option :$option (supported: :Flags, :Readers, :MapSize, :DBs)"))
    end
end

"""Get environment flags and parameters

`getindex` accepts folowing parameters:
* `env` db environment object
* `option` symbol which indicates parameter. Currently supported parameters:
    * Flags
    * Readers
    * KeySize

**Note:** Consult LMDB documentation for particual values of environment parameters and flags.
"""
function getindex(env::Environment, option::Symbol)
    value = Ref{Cuint}(0)
    if option == :Flags
        mdb_env_get_flags(env, value)
    elseif option == :Readers
        mdb_env_get_maxreaders(env, value)
    elseif option == :KeySize
        value[] = mdb_env_get_maxkeysize(env)
    else
        throw(ArgumentError("unknown environment option `:$(option)` " *
            "(supported: :Flags, :Readers, :KeySize)"))
    end
    return value[]
end

"""
    info(env::Environment) -> NamedTuple

Return a `NamedTuple` describing the env's mmap and reader slots:

| field        | meaning                                      |
|--------------|----------------------------------------------|
| `mapaddr`    | address the mmap is fixed at, or `C_NULL`    |
| `mapsize`    | configured map size in bytes                 |
| `last_pgno`  | high-water-mark page number (monotonic)      |
| `last_txnid` | id of the most recent committed txn          |
| `maxreaders` | max concurrent reader slots                  |
| `numreaders` | live reader slots in use                     |

Returns a zero-filled NamedTuple if the env is already closed.
"""
function info(env::Environment)
    ei_ref = Ref{MDB_envinfo}()
    if !isopen(env)
        return (mapaddr = C_NULL, mapsize = 0, last_pgno = 0, last_txnid = 0,
                maxreaders = 0, numreaders = 0)
    end
    mdb_env_info(env, ei_ref)
    ei = ei_ref[]
    return (mapaddr   = ei.me_mapaddr,
            mapsize   = Int(ei.me_mapsize),
            last_pgno = Int(ei.me_last_pgno),
            last_txnid = Int(ei.me_last_txnid),
            maxreaders = Int(ei.me_maxreaders),
            numreaders = Int(ei.me_numreaders))
end

"""
    stat(env::Environment) -> NamedTuple

Statistics for the env's main DB. See `stat(txn, dbi)` for the field layout.
"""
function stat(env::Environment)
    s_ref = Ref{MDB_stat}()
    mdb_env_stat(env, s_ref)
    return _stat_namedtuple(s_ref[])
end

"""
    copy(env::Environment, path::AbstractString; compact=false)

Copy the LMDB environment to a directory at `path`. With `compact=true`,
omit free-space pages so the destination is approximately as small as the
live data set. The destination directory must already exist (and on most
filesystems must be empty).

Wraps `mdb_env_copy` / `mdb_env_copy2`.
"""
function copy(env::Environment, path::AbstractString; compact::Bool = false)
    if compact
        mdb_env_copy2(env, String(path), MDB_CP_COMPACT)
    else
        mdb_env_copy(env, String(path))
    end
    return path
end

"""
    copy(env::Environment, fd::Integer; compact=false)

Copy the LMDB environment into the open file descriptor `fd` (typically a
pipe or socket). With `compact=true`, omit free-space pages.

Wraps `mdb_env_copyfd` / `mdb_env_copyfd2`.
"""
function copy(env::Environment, fd::Integer; compact::Bool = false)
    if compact
        mdb_env_copyfd2(env, Cint(fd), MDB_CP_COMPACT)
    else
        mdb_env_copyfd(env, Cint(fd))
    end
    return fd
end

"""
    reader_check(env::Environment) -> Int

Check for stale readers (transactions started by processes that have died
without releasing them) and reap their slots. Returns the number of slots
that were cleared. Useful in long-running services to recover from
abnormally-terminated readers.

Wraps `mdb_reader_check`.
"""
function reader_check(env::Environment)
    dead = Ref{Cint}(0)
    mdb_reader_check(env, dead)
    return Int(dead[])
end

# Callback for `mdb_reader_list`: appends the message to the IOBuffer
# referenced through `ctx`. Returns 0 to continue, non-zero to stop.
function _reader_list_cb(msg::Ptr{Cchar}, ctx::Ptr{Cvoid})::Cint
    io = unsafe_pointer_to_objref(ctx)::IOBuffer
    write(io, unsafe_string(msg))
    return Cint(0)
end

"""
    reader_list(env::Environment) -> String

Return a human-readable listing of the environment's reader slots: one
header line plus one line per active reader (PID, thread ID, transaction
ID). Useful for diagnosing reader-table contention.

Wraps `mdb_reader_list`.
"""
function reader_list(env::Environment)
    io = IOBuffer()
    cb = @cfunction(_reader_list_cb, Cint, (Ptr{Cchar}, Ptr{Cvoid}))
    GC.@preserve io begin
        mdb_reader_list(env, cb, pointer_from_objref(io))
    end
    return String(take!(io))
end

function show(io::IO, env::Environment)
    print(io,"Environment is ", isopen(env) ? (isempty(env.path) ? "created" : "opened") : "closed")
    if !isempty(env.path)
        print(io,"\nDB path: $(path(env))")
        ei = info(env)
        print(io,"\nSize of the data memory map: $(ei.mapsize)")
        print(io,"\nID of the last used page: $(ei.last_pgno)")
        print(io,"\nID of the last committed transaction: $(ei.last_txnid)")
        print(io,"\nMax reader slots in the environment: $(ei.maxreaders)")
        print(io,"\nMax reader slots used in the environment: $(ei.numreaders)")
    end
end
