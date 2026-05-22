using LMDB
using Test

@testset "common" begin

@test LMDB.version()[1] >= v"0.9.15"

# LMDBError
ex = LMDBError(Cint(0))
@test_throws LMDBError throw(ex)
@test ex.code == 0

end  # @testset "common"
