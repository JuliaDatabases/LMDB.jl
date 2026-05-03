# LMDB.jl

*A Julia wrapper for [LMDB](http://www.lmdb.tech/doc/), the Lightning
Memory-Mapped Database.*

LMDB is an embedded, memory-mapped, ACID key-value store developed by
Symas for OpenLDAP. It is small, fast, and persists to disk while reading
at near in-memory speeds — limited only by the size of the virtual address
space.

```julia
using Pkg; Pkg.add("LMDB")
```

## Three layers of abstraction

LMDB.jl exposes three layers, each with a clear consumer:

| Layer | Surface | When to use |
|-------|---------|-------------|
| **High-level abstractions** | `LMDBDict <: AbstractDict{K,V}` | "I want a persistent `Dict`." |
| **Julia API** | `Environment`, `Transaction`, `DBI`, `Cursor` | Julian wrappers with explicit transactions and cursors. The recommended surface for most code. |
| **C API** | `LMDB.mdb_*`, `LMDB.MDB_*` | Raw `ccall` bindings + status-code constants. For power users integrating with custom data layouts or shaving allocations on hot paths. |

The C API also includes `MDBValue`, `MDBArg`, and the
[`MDBValueIO`](@ref LMDB.MDBValueIO) extension point — an `IO` view
over `MDB_val` that lets custom value representations plug into all the
typed reads via `Base.read(io, T)`.

The Usage section is organised in increasing order of complexity: start
with [Essentials](@ref) for a working example, then [Dictionary
interface](@ref) for the `LMDBDict` surface, and progress through
[Environments](@ref), [Transactions](@ref), [Databases](@ref),
[Cursors](@ref), and [Duplicate-sort databases](@ref) as you need them.
[Low-level bindings](@ref) covers the `ccall` surface for callers who need
to skip the wrappers.

The API reference mirrors the same structure but lists every exported and
public docstring.

## A 5-line example

```julia
using LMDB
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
@show d["alpha"]
close(d)
```
