using Test, LMDB

@testset "LMDB" verbose=true begin
    include("common.jl")
    include("liblmdb.jl")
    include("env.jl")
    include("dbi.jl")
    include("cur.jl")
    include("dupsort.jl")
    include("dict.jl")
    include("integration.jl")
end
