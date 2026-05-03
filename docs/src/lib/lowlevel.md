# [Low-level bindings](@id API-LowLevel)

```@meta
CurrentModule = LMDB
```

The tier-1 surface is a flat namespace of `ccall` bindings (`LMDB.mdb_*`),
opaque handle types (`LMDB.MDB_env`, `LMDB.MDB_txn`, `LMDB.MDB_cursor`),
plain structs (`LMDB.MDB_val`, `LMDB.MDB_stat`, `LMDB.MDB_envinfo`), the
cursor-op `@cenum` (`LMDB.MDB_cursor_op`), and `LMDB.MDB_*` flag/status
constants.

Everything is public-but-unexported: refer to it as `LMDB.mdb_env_create`,
`LMDB.MDB_NOTLS`, `LMDB.MDB_val`. The bindings in this section auto-throw
on a non-zero status; for callers that need to inspect the raw status
code, an `unchecked_*` companion is paired with each.

## The auto-throw convention

Every status-returning binding in `liblmdb.jl` is paired with an
`unchecked_*` companion at definition time. Use the bare name when any
error should propagate (the common case); use `unchecked_*` when you
need to inspect the raw `Cint` yourself — e.g. distinguishing
`MDB_NOTFOUND` from a real error:

```julia
val_ref = Ref(LMDB.MDB_val(zero(Csize_t), C_NULL))
ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
ret == LMDB.MDB_NOTFOUND && return nothing
ret == 0 || throw(LMDB.LMDBError(ret))
```

Bindings that return non-status data (`mdb_strerror`, `mdb_version`,
`mdb_txn_id`, `mdb_cmp`, `mdb_dcmp`, `mdb_env_get_maxkeysize`,
`mdb_env_get_userctx`, `mdb_cursor_txn`, `mdb_cursor_dbi`) and
`Cvoid`-returning ones (`mdb_env_close`, `mdb_dbi_close`,
`mdb_txn_abort`, `mdb_txn_reset`, `mdb_cursor_close`) are left bare —
there is nothing to check.

## Customisation point: `MDBValueIO`

`tryget` / `get` / `key` / `value` / `item` / typed `walk` / `pop!` /
`replace!` all funnel through `read(::MDBValueIO, T)` to decode an
`MDB_val` into a Julia value. Define a `Base.read` method on
`MDBValueIO` to plug in a custom representation — see [Cursors](@ref)
for a worked example.

```@docs
MDBValueIO
```

## Helpers

```@docs
isflagset
version
```

## Raw bindings

The bindings are listed below by topic. Every name in this section is
reachable as `LMDB.<name>`; status-returning ones additionally expose
`LMDB.unchecked_<name>`.

### Types

```julia
LMDB.MDB_env       # opaque
LMDB.MDB_txn       # opaque
LMDB.MDB_cursor    # opaque
LMDB.MDB_dbi       # = Cuint
LMDB.MDB_val       # struct { mv_size::Csize_t; mv_data::Ptr{Cvoid} }
LMDB.MDB_stat      # struct (page sizes, depth, leaf/branch/overflow page counts, entries)
LMDB.MDB_envinfo   # struct (mapaddr, mapsize, last_pgno, last_txnid, maxreaders, numreaders)
LMDB.MDB_cursor_op # @cenum: MDB_FIRST … MDB_PREV_MULTIPLE (19 variants)
```

### Environment

```julia
mdb_env_create
mdb_env_open
mdb_env_close
mdb_env_copy        mdb_env_copy2
mdb_env_copyfd      mdb_env_copyfd2
mdb_env_stat        mdb_env_info
mdb_env_sync
mdb_env_set_flags   mdb_env_get_flags
mdb_env_get_path    mdb_env_get_fd
mdb_env_set_mapsize
mdb_env_set_maxreaders   mdb_env_get_maxreaders
mdb_env_set_maxdbs
mdb_env_get_maxkeysize
mdb_env_set_userctx      mdb_env_get_userctx
mdb_env_set_assert
```

### Transaction

```julia
mdb_txn_begin
mdb_txn_env
mdb_txn_id
mdb_txn_commit
mdb_txn_abort
mdb_txn_reset
mdb_txn_renew
```

### Database (DBI)

```julia
mdb_dbi_open
mdb_dbi_close
mdb_dbi_flags
mdb_drop
mdb_stat
mdb_set_compare    mdb_set_dupsort
mdb_set_relfunc    mdb_set_relctx
```

### Data access

```julia
mdb_get
mdb_put
mdb_del
```

### Cursor

```julia
mdb_cursor_open
mdb_cursor_close
mdb_cursor_renew
mdb_cursor_txn
mdb_cursor_dbi
mdb_cursor_get
mdb_cursor_put
mdb_cursor_del
mdb_cursor_count
```

### Comparators / readers / version

```julia
mdb_cmp     mdb_dcmp
mdb_reader_list
mdb_reader_check
mdb_version
mdb_strerror
```

## Constants

| group | constants |
|------|-----------|
| Env flags | `MDB_FIXEDMAP`, `MDB_NOSUBDIR`, `MDB_NOSYNC`, `MDB_RDONLY`, `MDB_NOMETASYNC`, `MDB_WRITEMAP`, `MDB_MAPASYNC`, `MDB_NOTLS`, `MDB_NOLOCK`, `MDB_NORDAHEAD`, `MDB_NOMEMINIT` |
| DB flags | `MDB_REVERSEKEY`, `MDB_DUPSORT`, `MDB_INTEGERKEY`, `MDB_DUPFIXED`, `MDB_INTEGERDUP`, `MDB_REVERSEDUP`, `MDB_CREATE` |
| Write flags | `MDB_NOOVERWRITE`, `MDB_NODUPDATA`, `MDB_CURRENT`, `MDB_RESERVE`, `MDB_APPEND`, `MDB_APPENDDUP`, `MDB_MULTIPLE` |
| Copy flag | `MDB_CP_COMPACT` |
| Status codes | `MDB_SUCCESS=0`, `MDB_KEYEXIST`, `MDB_NOTFOUND`, `MDB_PAGE_NOTFOUND`, `MDB_CORRUPTED`, `MDB_PANIC`, `MDB_VERSION_MISMATCH`, `MDB_INVALID`, `MDB_MAP_FULL`, `MDB_DBS_FULL`, `MDB_READERS_FULL`, `MDB_TLS_FULL`, `MDB_TXN_FULL`, `MDB_CURSOR_FULL`, `MDB_PAGE_FULL`, `MDB_MAP_RESIZED`, `MDB_INCOMPATIBLE`, `MDB_BAD_RSLOT`, `MDB_BAD_TXN`, `MDB_BAD_VALSIZE`, `MDB_BAD_DBI` |
