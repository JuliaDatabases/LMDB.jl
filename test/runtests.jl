using Test, LMDB

@testset "LMDB" verbose=true begin
    @test LMDB.version()[1] >= v"0.9.15"

    # LMDBError
    ex = LMDBError(Cint(0))
    @test_throws LMDBError throw(ex)
    @test ex.code == 0

    include("liblmdb.jl")
    include("environment.jl")
    include("database.jl")
    include("cursor.jl")
    include("dupsort.jl")
    include("dictionary.jl")
    include("integration.jl")
end
