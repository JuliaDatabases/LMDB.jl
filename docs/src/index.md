# LMDB.jl

*A Julia wrapper for [LMDB](http://www.lmdb.tech/doc/), the Lightning
Memory-Mapped Database.*

LMDB is an embedded, memory-mapped, ACID key-value store developed by
Symas for OpenLDAP. It persists to disk while reading at near in-memory
speeds, limited only by the size of the virtual address space.

```julia
using Pkg; Pkg.add("LMDB")
```

## Using LMDB.jl

LMDB.jl exposes the same database through three surfaces:

| Surface | What it offers | When to use |
|---------|----------------|-------------|
| High-level interface | `LMDBDict <: AbstractDict{K,V}` | When you want a persistent `Dict`. |
| Julia wrappers | `Environment`, `Transaction`, `Database`, `Cursor` | When you want explicit transactions and cursors with Julia-shaped wrappers. |
| C API | `LMDB.mdb_*`, `LMDB.MDB_*` | Raw `ccall` bindings and status-code constants, for custom data layouts or when you want to skip allocations on hot paths. |

`MDBValue`, `MDBArg`, and the [`MDBValueIO`](@ref LMDB.MDBValueIO)
type sit between the C API and the Julia wrappers. `MDBValueIO` is an
`IO` view over `MDB_val`; defining `Base.read(io, T)` on it is how you
teach the typed reads about a custom value type.

The Usage section starts simple and gets more involved. [Essentials](@ref)
has a working example, [Dictionary interface](@ref) covers `LMDBDict`,
and [Environments](@ref), [Transactions](@ref), [Databases](@ref),
[Cursors](@ref), and [Duplicate-sort databases](@ref) cover the wrappers.
[Low-level bindings](@ref) is the raw `ccall` surface.

The API reference follows the same structure and lists every exported
and public docstring.

## A 5-line example

```julia
using LMDB
d = LMDBDict{String, Vector{Float32}}("/tmp/mydb")
d["alpha"]  = Float32[1, 2, 3]
@show d["alpha"]
close(d)
```
