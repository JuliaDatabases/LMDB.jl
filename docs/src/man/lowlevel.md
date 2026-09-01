# Low-level bindings

```@meta
CurrentModule = LMDB
```

The C API is an unexported `ccall` interface to `liblmdb`. Refer to it as
`LMDB.mdb_env_create`,
`LMDB.MDB_NOTLS`, `LMDB.MDB_val`. Reach for it when you need to
integrate with a custom data layout, branch on a status code that the
Julia wrappers don't surface, or skip allocations on a hot path.

For the full inventory, see [the API reference](@ref API-LowLevel). What
follows is an overview of how the surface is shaped.

## The auto-throwing convention

Bindings that return 0 on success and a nonzero status on failure are paired
with an `unchecked_*` companion:

```julia
LMDB.mdb_env_open(env, path, flags, mode)            # auto-throws on non-zero
LMDB.unchecked_mdb_env_open(env, path, flags, mode)  # returns the raw Cint
```

Use the bare name when any error should propagate (the common case).
Use the `unchecked_*` companion when you need to inspect the raw status
yourself, for example to distinguish `MDB_NOTFOUND` from a real error:

```julia
val_ref = Ref(LMDB.MDB_val(zero(Csize_t), C_NULL))
ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
ret == LMDB.MDB_NOTFOUND && return nothing
ret == 0 || throw(LMDB.LMDBError(ret))
return read(LMDB.MDBValueIO(val_ref[]), T)
```

This is exactly the pattern `get(txn, dbi, key, T, default)` uses internally.

Bindings that don't return a status (`mdb_strerror`, `mdb_version`,
`mdb_txn_id`, `mdb_cmp`, `mdb_dcmp`, `mdb_env_get_maxkeysize`,
`mdb_cursor_txn`, `mdb_cursor_dbi`, `mdb_cursor_is_db`, `mdb_modload`)
and `Cvoid`-returning ones
(`mdb_env_close`, `mdb_dbi_close`, `mdb_txn_abort`, `mdb_txn_reset`,
`mdb_cursor_close`, `mdb_modunload`, `mdb_modsetup`) are left bare;
there is nothing to check.

`mdb_reader_list` is also paired, but its checked form accepts every
nonnegative callback result and throws only for a negative return.

## ccall glue for `MDB_val *`

LMDB exchanges keys and values through pointers to two-field `MDB_val`
structures containing `(size, data_ptr)`. The bindings declare these C
pointers as `Ref{MDB_val}`, which has pointer ABI without competing with
Base's array-to-`Ptr` conversions. LMDB.jl accepts `String`, contiguous
`AbstractArray`s with bitstype elements, `Base.RefValue` over a bitstype,
bitstype scalars, and a pre-built `Ref{MDB_val}` output argument. Inputs use a
carrier containing both the `MDB_val` and its Julia-owned data; `ccall`
preserves that carrier through the call.

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

A successful read populates a `Ref{MDB_val}` pointing to LMDB-owned memory.
`MDBValueIO` provides an `IO` view of those bytes.

The package ships these defaults:

| `T` | behaviour |
|-----|-----------|
| `String` | copy the remaining bytes into a `String` |
| `Vector{E}` for bitstype `E` | copy the remaining bytes into a new vector |
| Base fixed-width reads | consume `sizeof(T)` bytes |

Add custom representations by overloading `Base.read` on the abstract
`IO`. This is the idiomatic Julia form and keeps the decoder portable
to other byte sources:

```julia
struct AtimedBlob end
function Base.read(io::IO, ::Type{AtimedBlob})
    bytesavailable(io) < 8 && return UInt8[]
    skip(io, 8)
    return read(io, Vector{UInt8})
end

LMDB.get(txn, dbi, key, AtimedBlob, nothing)   # skip 8-byte prefix, copy tail
```

For an `isbitstype` struct `T`, the standard one-liner is enough:

```julia
Base.read(io::IO, ::Type{T}) = read!(io, Ref{T}())[]
```

Every typed read in the Julia wrappers (`get`, `key`, `value`, `item`, typed
`walk`, `pop!`, `replace!`) goes through `read(::MDBValueIO, T)`,
so one method definition makes a custom representation usable across
the package. Because `MDBValueIO <: IO`, the standard `Base` IO
primitives (`position`, `seek`, `skip`, `read(io)`, `read(io,
n::Integer)`, `read!(io, A)`, `bytesavailable`, `eof`) work out of the
box. Structured framed-value decoders read like any other Julia parser.

## Memory ownership rules

- Raw cursor handles do not get the high-level wrapper's lifetime management.
  Close them before committing or aborting their transaction; the bundled LMDB
  can access freed transaction state when a read cursor is closed afterward.
- The `mv_data` pointer of an `MDB_val` produced by a read is owned by LMDB.
  It is valid until the next update operation or the end of the transaction.
  The default `Vector{E}` and `String` `read(::MDBValueIO, T)` methods
  always copy; custom decoders are responsible for doing the same.
- `MDB_RESERVE` storage is valid until the next update or the end of the
  transaction. [`put_reserved!`](@ref) intentionally restricts access to its
  callback; do not retain `buf`.

## Unwrapped LMDB features

A few LMDB features are reachable only through the C API because the
Julia wrappers deliberately don't include them:

- Custom comparators: `LMDB.mdb_set_compare` and
  `LMDB.mdb_set_dupsort` accept a `MDB_cmp_func` callback. Use
  `@cfunction` to lift a Julia function into the right C signature.
- `mdb_set_relfunc` / `mdb_set_relctx`: used by
  `MDB_FIXEDMAP`-style relocations; rarely needed.
- `MDB_GET_MULTIPLE` / `MDB_NEXT_MULTIPLE` cursor ops: reachable by
  passing the constant directly to `LMDB.mdb_cursor_get`. Useful with
  `MDB_DUPFIXED` databases for batched reads.
- LMDB 1.0 incremental backup, encryption/checksum hooks, and
  two-phase-commit helpers are exposed as raw bindings:
  `mdb_env_incr_dump`, `mdb_env_incr_dumpfd`, `mdb_env_incr_loadfd`,
  `mdb_env_set_encrypt`, `mdb_env_set_checksum`, `mdb_txn_prepare`,
  and `mdb_env_rollback`.
