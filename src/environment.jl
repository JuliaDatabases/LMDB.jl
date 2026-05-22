@public Environment, sync, set!, unset!, info, path,
        reader_check, reader_list

"""
A DB environment supports multiple databases, all residing in the same shared-memory map.

The handle is closed when the wrapper is garbage-collected, unless `close`
was already called explicitly. Closing is idempotent.
"""
mutable struct Environment
    handle::Ptr{MDB_env}
    path::String
    # Live transactions, tracked weakly so they remain GC-able. `close`
    # walks this list to abort any still-open txn before calling
    # `mdb_env_close`; otherwise LMDB corrupts state shared across envs.
    txns::Vector{WeakRef}
end

Base.unsafe_convert(::Type{Ptr{MDB_env}}, e::Environment) = e.handle

"Return the path that was used to open the environment."
path(env::Environment) = env.path

"Check if environment is open"
isopen(env::Environment) = env.handle != C_NULL

"""
    Environment(path::AbstractString; mapsize=nothing, maxreaders=nothing,
                maxdbs=nothing, flags=0, mode=0o755) -> Environment

Open the LMDB environment at `path`. The directory must already exist
and be writable. The configuration kwargs go through
`mdb_env_set_mapsize`, `mdb_env_set_maxreaders`, and `mdb_env_set_maxdbs`;
`flags` is forwarded to `mdb_env_open`. If anything fails before the
open completes, the half-open env is closed before the exception
propagates.

The shape matches py-lmdb's `Environment(path, **kwargs)` and lmdb-rs's
`EnvironmentBuilder.open(path)`.
"""
function Environment(path::AbstractString; mapsize::Union{Integer,Nothing} = nothing,
                     maxreaders::Union{Integer,Nothing} = nothing,
                     maxdbs::Union{Integer,Nothing} = nothing,
                     flags::Integer = zero(Cuint),
                     mode::Integer = mode_t(0o755))
    env_ref = Ref{Ptr{MDB_env}}()
    mdb_env_create(env_ref)
    env = Environment(env_ref[], "", WeakRef[])
    finalizer(close, env)
    try
        mapsize    === nothing || (env[:MapSize] = mapsize)
        maxreaders === nothing || (env[:Readers] = maxreaders)
        maxdbs     === nothing || (env[:DBs]     = maxdbs)
        env.path = String(path)
        mdb_env_open(env, env.path, Cuint(flags), mode_t(mode))
    catch
        close(env)
        rethrow()
    end
    return env
end

"""
    Environment(f::Function, path::AbstractString; kwargs...) -> result

`do`-block form. Opens the env, runs `f(env)`, and closes it on the
way out whether or not `f` throws. Returns whatever `f` returns.
"""
function Environment(f::Function, path::AbstractString; kwargs...)
    env = Environment(path; kwargs...)
    try
        f(env)
    finally
        close(env)
    end
end

"""Close the environment and release the memory map.

Idempotent: calling `close` on an already-closed `Environment` is a
silent no-op, matching the convention of `close(::IO)`. That makes
finalizers safe to run after an explicit close.
"""
function close(env::Environment)
    env.handle == C_NULL && return nothing
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
    return nothing
end

"""Flush the data buffers to disk"""
function sync(env::Environment, force::Bool = false)
    fval = force ? 1 : 0
    mdb_env_sync(env, fval)
    return nothing
end

"""Set environment flags. Returns `env` to allow chaining."""
function set!(env::Environment, flag::Integer)
    mdb_env_set_flags(env, Cuint(flag), one(Cint))
    return env
end

"""Unset environment flags. Returns `env` to allow chaining."""
function unset!(env::Environment, flag::Integer)
    mdb_env_set_flags(env, Cuint(flag), zero(Cint))
    return env
end


"""Set environment flags and parameters

`setindex!` accepts following parameters:
* `env` db environment object
* `option` symbol which indicates parameter. Currently supported parameters:
    * Flags
    * Readers
    * MapSize
    * DBs
* `value` parameter value

**Note:** Consult LMDB documentation for particular values of environment parameters and flags.
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

`getindex` accepts following parameters:
* `env` db environment object
* `option` symbol which indicates parameter. Currently supported parameters:
    * Flags
    * Readers
    * KeySize

**Note:** Consult LMDB documentation for particular values of environment parameters and flags.
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
    return stat_namedtuple(s_ref[])
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
function reader_list_cb(msg::Ptr{Cchar}, ctx::Ptr{Cvoid})::Cint
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
    cb = @cfunction(reader_list_cb, Cint, (Ptr{Cchar}, Ptr{Cvoid}))
    GC.@preserve io begin
        mdb_reader_list(env, cb, pointer_from_objref(io))
    end
    return String(take!(io))
end

function Base.show(io::IO, env::Environment)
    state = !isopen(env) ? "closed" :
            isempty(env.path) ? "created" : "opened"
    print(io, "Environment(", state)
    isempty(env.path) || print(io, ", ", repr(env.path))
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", env::Environment)
    state = !isopen(env) ? "closed" :
            isempty(env.path) ? "created" : "opened"
    print(io, "Environment is ", state)
    isempty(env.path) && return
    ei = info(env)
    print(io, "\nDB path: ", path(env))
    print(io, "\nSize of the data memory map: ", ei.mapsize)
    print(io, "\nID of the last used page: ", ei.last_pgno)
    print(io, "\nID of the last committed transaction: ", ei.last_txnid)
    print(io, "\nMax reader slots in the environment: ", ei.maxreaders)
    print(io, "\nMax reader slots used in the environment: ", ei.numreaders)
end
