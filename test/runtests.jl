using Test, LMDB

# Pull the wrapper types and the env-level operations into the test
# scope under their bare names; the rest of the API is reached through
# the `LMDB.` qualifier just as user code would.
using LMDB: Environment, Transaction, DBI, Cursor,
            set!, unset!, sync, info, path,
            reader_check, reader_list

@testset "LMDB" verbose=true begin
    @test LMDB.version() >= v"0.9.35"

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
