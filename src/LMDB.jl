module LMDB

import Base: open, close, getindex, setindex!, put!, pop!, replace!, reset,
             isopen, count, delete!, keys, get, show, stat, copy,
             empty!, length, isempty, iterate, haskey
import Base.Iterators: drop

# `public name1, name2, ...` on 1.11+, no-op on 1.10.
macro public(names)
    @static if VERSION >= v"1.11"
        syms = names isa Symbol ? (names,) :
               Meta.isexpr(names, :tuple) ? names.args :
               error("@public expects a symbol or a comma-separated list of symbols")
        return esc(Expr(:public, syms...))
    else
        return nothing
    end
end

include("error.jl")

# C API
include("liblmdb.jl")

include("common.jl")

# Julia wrappers
include("env.jl")
include("txn.jl")
include("dbi.jl")
include("cur.jl")

# High-level abstractions
include("dicts.jl")

end # module
