# [Dictionary interface](@id API-Dict)

The high-level interface: a single `AbstractDict{K,V}` over an LMDB environment.

```@meta
CurrentModule = LMDB
```

## `LMDBDict`

```@docs
LMDBDict
```

`LMDBDict <: AbstractDict{K,V}`, so it picks up `Base`'s generic
methods on top of the lookup/mutation primitives.

Reads (`getindex`, `haskey`, `get`, `get!`, `length`, `isempty`,
`iterate`, `keys`, `values`, `pairs`) are dispatched into LMDB.
`getindex` and `pop!` throw `KeyError` on miss to match `Base.Dict`.

Writes (`setindex!`, `delete!`, `pop!`, `empty!`) likewise. `delete!`
silently no-ops on a missing key, matching `Base.delete!`'s "if any"
contract.

`merge!`, `mergewith!`, and `filter!` are specialized to use one write
transaction. `Dict(d)` creates an in-memory copy. `empty(d)`, `copy(d)`, and
out-of-place operations that require `empty(d)` throw because a new
`LMDBDict` needs a filesystem path.

`LMDBDict` iterates in lexicographic key order, which is stricter than
`Base.Dict`'s no-order promise.

## Lifecycle

`close(::LMDBDict)` closes the underlying env (and the default Database).
Idempotent, and also called from the finalizer.

## Prefix-scan helpers

LMDB-namespaced extensions for hierarchical-key schemes that don't fit
the polymorphic `AbstractDict` contract:

```@docs
LMDB.scan
LMDB.scan_keys
LMDB.scan_values
LMDB.list_dirs
LMDB.valuesize
```
