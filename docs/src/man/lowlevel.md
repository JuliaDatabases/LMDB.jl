# Low-level bindings

```@meta
CurrentModule = LMDB
```

The C API is the raw `ccall` interface to `liblmdb`. It is
public-but-unexported: refer to it as `LMDB.mdb_env_create`,
`LMDB.MDB_NOTLS`, `LMDB.MDB_val`. Use this layer when you need to
integrate with a custom data layout, branch on a status code that the
Julia API doesn't surface, or skip allocations on a hot path.

For the full inventory, see [the API reference](@ref API-LowLevel). What
follows is a tour of how the layer is shaped.

## The auto-throwing convention

Every status-returning binding is paired with an `unchecked_*`
companion at definition time:

```julia
LMDB.mdb_env_open(env, path, flags, mode)            # auto-throws on non-zero
LMDB.unchecked_mdb_env_open(env, path, flags, mode)  # returns the raw Cint
```

Use the bare name when any error should propagate (the common case).
Use the `unchecked_*` companion when you need to inspect the raw status
yourself — e.g. distinguishing `MDB_NOTFOUND` from a real error:

```julia
val_ref = Ref(LMDB.MDB_val(zero(Csize_t), C_NULL))
ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
ret == LMDB.MDB_NOTFOUND && return nothing
ret == 0 || throw(LMDB.LMDBError(ret))
return read(LMDB.MDBValueIO(val_ref[]), T)
```

This is exactly the pattern [`tryget`](@ref) uses internally.

Bindings that don't return a status (`mdb_strerror`, `mdb_version`,
`mdb_txn_id`, `mdb_cmp`, `mdb_dcmp`, `mdb_env_get_maxkeysize`,
`mdb_cursor_txn`, `mdb_cursor_dbi`) and `Cvoid`-returning ones
(`mdb_env_close`, `mdb_dbi_close`, `mdb_txn_abort`, `mdb_txn_reset`,
`mdb_cursor_close`) are left bare — there is nothing to check.

## ccall glue: passing values to `Ptr{MDB_val}`

LMDB exchanges keys and values through a `Ptr{MDB_val}` argument: a
two-field struct of `(size, data_ptr)` plus an out-pointer for the
ccall to fill in. LMDB.jl ships `Base.cconvert` overloads on
`Ptr{MDB_val}` that route any of `String`, `AbstractArray` (with
bitstype element type), `Base.RefValue` over a bitstype, any bitstype
scalar, or a pre-built `Ref{MDB_val}` (used as an out-param) into a
self-rooted argument that `ccall`'s automatic `GC.@preserve` keeps alive
across the call. Callers never need to write `Ref(...)` or
`GC.@preserve` for input arguments.

```julia
import LMDB

env_ref = Ref{Ptr{LMDB.MDB_env}}(C_NULL)
LMDB.mdb_env_create(env_ref)                          # auto-throws
env = env_ref[]
LMDB.mdb_env_set_mapsize(env, Csize_t(1 << 30))
LMDB.mdb_env_open(env, "/tmp/mydb",
                  LMDB.MDB_NOTLS | LMDB.MDB_NORDAHEAD,
                  LMDB.mode_t(0o644))

txn_ref = Ref{Ptr{LMDB.MDB_txn}}()
LMDB.mdb_txn_begin(env, C_NULL, Cuint(0), txn_ref)
txn = txn_ref[]

dbi_ref = Ref{LMDB.MDB_dbi}()
LMDB.mdb_dbi_open(txn, C_NULL, Cuint(0), dbi_ref)
dbi = dbi_ref[]

LMDB.mdb_put(txn, dbi, "key", "value", Cuint(0))     # cconvert handles strings
LMDB.mdb_txn_commit(txn)
LMDB.mdb_env_close(env)
```

## Decoding `MDB_val`: the [`MDBValueIO`](@ref) extension point

A successful read populates a `Ref{MDB_val}` whose `mv_data` points
into the LMDB-owned mmap. `MDBValueIO` is a thin `IO` view over that
buffer; `Base.read(io, T)` decodes it into a Julia value of type `T`.

The package ships these defaults:

| `T` | behaviour |
|-----|-----------|
| `String` | one `unsafe_string` over the remaining bytes |
| `Vector{E}` for bitstype `E` | one alloc + `unsafe_copyto!`; the buffer is Julia-owned |
| any bitstype scalar `T` | one `unsafe_load` of `sizeof(T)` bytes — zero allocations |

Custom representations are added by overloading `Base.read` on the
abstract `IO` (the idiomatic Julia form — keeps the decoder portable
to other byte sources):

```julia
struct AtimedBlob end
function Base.read(io::IO, ::Type{AtimedBlob})
    bytesavailable(io) < 8 && return UInt8[]
    skip(io, 8)
    return read(io, Vector{UInt8})
end

LMDB.tryget(txn, dbi, key, AtimedBlob)   # skip 8-byte prefix, copy tail
```

For an `isbitstype` struct `T`, the standard one-liner is enough:

```julia
Base.read(io::IO, ::Type{T}) = read!(io, Ref{T}())[]
```

This is the analogue of heed's `BytesDecode<'txn>` trait. Every typed
read in the Julia API — `tryget`, `get`, `key`, `value`, `item`, typed
`walk`, `pop!`, `replace!` — funnels through `read(::MDBValueIO, T)`,
so a single method opt-in is enough to make a custom representation
usable across the package. Because `MDBValueIO <: IO`, all the standard
`Base` IO primitives (`position`, `seek`, `skip`, `read(io)`,
`read(io, n::Integer)`, `read!(io, A)`, `bytesavailable`, `eof`) work
out of the box, which makes structured framed-value decoders read
exactly like any other Julia parser.

## Memory ownership rules

- The `mv_data` pointer of an `MDB_val` produced by a *read* is into
  LMDB's mmap. It is **valid only for the producing transaction's
  lifetime** — copy out anything you want to retain past commit.
  The default `Vector{E}` and `String` `read(::MDBValueIO, T)` methods
  always copy; custom decoders are responsible for doing the same.
- The `mv_data` pointer of an `MDB_val` produced by a `MDB_RESERVE`
  *write* points into the LMDB write buffer and is **valid only inside
  the surrounding write transaction**. [`put_reserved!`](@ref) wraps
  this; don't escape its `buf` argument.

## Unwrapped LMDB features

A few LMDB features are reachable only through the C API because the
Julia API deliberately doesn't include them:

- **Custom comparators.** `LMDB.mdb_set_compare` /
  `LMDB.mdb_set_dupsort` accept a `MDB_cmp_func` callback. Use
  `@cfunction` to lift a Julia function into the right C signature.
- **`mdb_set_relfunc` / `mdb_set_relctx`.** Used by
  `MDB_FIXEDMAP`-style relocations; rarely needed.
- **`MDB_GET_MULTIPLE` / `MDB_NEXT_MULTIPLE` cursor ops.** Reachable by
  passing the constant directly to `LMDB.mdb_cursor_get`. Useful with
  `MDB_DUPFIXED` databases for batched reads.
