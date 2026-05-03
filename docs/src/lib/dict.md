# [Dictionary interface](@id API-Dict)

The tier-3 surface: a single `AbstractDict{K,V}` over an LMDB environment.

```@meta
CurrentModule = LMDB
```

## `LMDBDict`

```@docs
LMDBDict
```

`LMDBDict` is `<: AbstractDict{K,V}`, so it transparently picks up
`Base`'s generic methods on top of the lookup/mutation primitives:

- **Reads.** `getindex`, `haskey`, `get`, `get!`, `length`, `isempty`,
  `iterate`, `keys`, `values`, `pairs`. All defined on `Base`-side
  signatures and dispatched into LMDB; `getindex` and `pop!` throw
  `KeyError` on miss to match `Base.Dict`.
- **Writes.** `setindex!`, `delete!`, `pop!`, `empty!`. `delete!`
  silently no-ops on a missing key (matching `Base.delete!`'s "if any"
  contract).
- **Generic.** Everything `AbstractDict` derives — `merge!`, `merge`,
  `mergewith!`, `filter!`, `filter`, `==`, `isequal`, `hash`,
  `in(::Pair, d)`, `copy(d)` — applies for free.

`LMDBDict` iterates in lexicographic key order, which is stronger than
`Base.Dict`'s no-order promise.

## Lifecycle

`close(::LMDBDict)` closes the underlying env (and the default DBI).
Idempotent — also called from the finalizer.

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
