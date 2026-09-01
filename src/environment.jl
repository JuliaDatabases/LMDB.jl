@public Environment, sync, set!, unset!, info, path,
        reader_check, reader_list

"""An LMDB environment containing one or more databases."""
mutable struct Environment
    handle::Ptr{MDB_env}
    path::String
    # LMDB requires transactions to end before their environment is closed.
    # Weak references let transactions remain eligible for finalization.
    txns::Vector{WeakRef}
end

Base.unsafe_convert(::Type{Ptr{MDB_env}}, e::Environment) = e.handle

"Return the path that was used to open the environment."
path(env::Environment) = env.path

"Return whether the environment is open."
isopen(env::Environment) = env.handle != C_NULL

"""
    Environment(path::AbstractString; mapsize=nothing, pagesize=nothing,
                maxreaders=nothing, maxdbs=nothing, flags=0,
                mode=0o755) -> Environment

Create and open an LMDB environment. `path` normally names an existing
directory; with `MDB_NOSUBDIR`, it names the data file. The optional limits
and page size are set before `mdb_env_open` is called.
"""
function Environment(path::AbstractString; mapsize::Union{Integer,Nothing} = nothing,
                     pagesize::Union{Integer,Nothing} = nothing,
                     maxreaders::Union{Integer,Nothing} = nothing,
                     maxdbs::Union{Integer,Nothing} = nothing,
                     flags::Integer = zero(Cuint),
                     mode::Integer = mode_t(0o755))
    env_ref = Ref{Ptr{MDB_env}}()
    mdb_env_create(env_ref)
    env = Environment(env_ref[], "", WeakRef[])
    finalizer(close, env)
    try
        pagesize   === nothing || (env[:PageSize] = pagesize)
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

Open the environment, call `f`, and close it afterward, including when `f`
throws. Return the result of `f`.
"""
function Environment(f::Function, path::AbstractString; kwargs...)
    env = Environment(path; kwargs...)
    try
        f(env)
    finally
        close(env)
    end
end

"""Close the environment and release its memory map. Repeated calls are no-ops."""
function close(env::Environment)
    env.handle == C_NULL && return nothing
    # End tracked transactions before invalidating all child handles.
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

"""Flush the environment's data buffers to disk."""
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


"""
    env[option] = value

Set `:Flags`, `:Readers`, `:MapSize`, `:PageSize`, or `:DBs`.
"""
function setindex!(env::Environment, val::Integer, option::Symbol)
    if option == :Flags
        set!(env, Cuint(val))
    elseif option == :Readers
        mdb_env_set_maxreaders(env, Cuint(val))
    elseif option == :MapSize
        # The C API takes `size_t`; `Cuint` would truncate maps larger than 4 GiB.
        mdb_env_set_mapsize(env, mdb_size_t(val))
    elseif option == :PageSize
        mdb_env_set_pagesize(env, Cint(val))
    elseif option == :DBs
        mdb_env_set_maxdbs(env, Cuint(val))
    else
        throw(ArgumentError("Unsupported environment option :$option (supported: :Flags, :Readers, :MapSize, :PageSize, :DBs)"))
    end
end

"""
    env[option]

Return `:Flags`, `:Readers`, or `:KeySize`.
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
| `last_pgno`  | id of the last used page                     |
| `last_txnid` | id of the most recent committed txn          |
| `maxreaders` | max concurrent reader slots                  |
| `numreaders` | maximum reader slots used                    |

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

Copy the LMDB environment to an existing empty directory at `path`. With
`compact=true`, omit free pages and renumber the copied pages sequentially.

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

Clear reader slots left by dead processes and return the number cleared.

Wraps `mdb_reader_check`.
"""
function reader_check(env::Environment)
    dead = Ref{Cint}(0)
    mdb_reader_check(env, dead)
    return Int(dead[])
end

# Append each reader-table line to the `IOBuffer` passed as `ctx`.
function reader_list_cb(msg::Ptr{Cchar}, ctx::Ptr{Cvoid})::Cint
    io = unsafe_pointer_to_objref(ctx)::IOBuffer
    write(io, unsafe_string(msg))
    return Cint(0)
end

"""
    reader_list(env::Environment) -> String

Return LMDB's human-readable reader-table listing.

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
