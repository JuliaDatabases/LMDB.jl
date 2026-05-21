using Test

@testset "LMDB" for t in ["common", "liblmdb", "env", "dbi", "cur", "dupsort",
                          "dict", "integration"]
    fp = "$t.jl"
    include(fp)
end
