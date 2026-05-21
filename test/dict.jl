using Test, LMDB
@testset "Dictionary-like interface" begin
p1 = tempname()
#Test dict with string keys, float64 values
mkpath(p1)
d = LMDBDict{String, Float64}(p1)
d["x"] = 5.0
d["y"] = 12.0
d["z"] = 3
@test d["x"] === 5.0
@test d["y"] === 12.0
@test d["z"] === 3.0
@test haskey(d,"x")
@test !haskey(d,"a")
@test keys(d) == ["x", "y", "z"]
@test values(d) == [5.0, 12.0, 3.0]
@test collect(d) == ["x"=>5.0, "y"=>12.0, "z"=>3.0]
@test LMDB.valuesize(d) == sizeof(Float64)*3
delete!(d,"z")
@test !haskey(d,"z")
@test_throws LMDB.LMDBError d["z"]

#Test int key and values
p2 = tempname()
mkpath(p2)
d = LMDBDict{Int64, Int16}(p2)
for i in 1:10
    d[i] = i+1
end
@test keys(d) == 1:10
@test values(d) == 2:11
@test d[2] === Int16(3)
@test d[3.0] == 4
@test eltype(d) == Int16
@test keytype(d) == Int64

#Some extra tests for string dicts
p3 = tempname()
mkpath(p3)
d = LMDBDict{String, Vector{Float32}}(p3)
d["aa/a"] = Float32[1,2,3,4]
d["aa/b"] = Float32.(2:12)
d["aa/c"] = [10,11,12]
d["b"] = [0,0,0]
@test d["aa/a"] == 1:4
@test d["aa/b"] == 2:12
@test d["aa/c"] == 10:12
@test d["b"] == [0,0,0]
@test LMDB.list_dirs(d) == ["aa/", "b"]
@test LMDB.list_dirs(d,prefix="aa/") == ["aa/a", "aa/b", "aa/c"]
@test LMDB.valuesize(d,prefix="aa/") == sizeof(Float32)*18

@testset "Tests for get and get!" begin
    mktempdir() do dir
        d = LMDBDict{String, String}(dir)
        @test !haskey(d, "foo")
        @test get(d, "foo", "bar") == "bar"
        @test !haskey(d, "foo")
        @test get!(d, "foo", "bar") == "bar"
        @test haskey(d, "foo")
        @test d["foo"] == "bar"
        @test get(d, "foo", "hello") == "bar"
        @test d["foo"] == "bar"
        @test get!(d, "foo", "hello") == "bar"
        @test d["foo"] == "bar"
    end
    mktempdir() do dir
        d = LMDBDict{String, String}(dir)
        @test !haskey(d, "foo")
        @test get(() -> "bar", d, "foo") == "bar"
        @test !haskey(d, "foo")
        @test get!(() -> "bar", d, "foo") == "bar"
        @test haskey(d, "foo")
        @test d["foo"] == "bar"
        @test get(() -> "hello", d, "foo") == "bar"
        @test d["foo"] == "bar"
        @test get!(() -> "hello", d, "foo") == "bar"
        @test d["foo"] == "bar"
    end
end

@testset "String -> Int64 round-trip (#46)" begin
    mktempdir() do dir
        d = LMDBDict{String, Int64}(dir)
        d["aa"] = 2
        d["ab"] = 3
        d["ac"] = 2
        @test d["aa"] === Int64(2)
        @test d["ab"] === Int64(3)
        @test d["ac"] === Int64(2)
        # Force a GC pass between the writes and the reads. Before the
        # GC.@preserve fix this would alias unrelated memory.
        GC.gc(); GC.gc()
        @test d["aa"] === Int64(2)
        @test d["ab"] === Int64(3)
    end
end

@testset "Vector value owns its memory (#41)" begin
    mktempdir() do dir
        d = LMDBDict{String, Vector{Float32}}(dir)
        d["k"] = Float32[1,2,3,4]
        v = d["k"]
        close(d)
        GC.gc(); GC.gc()
        @test v == Float32[1,2,3,4]
    end
end

@testset "LMDBDict mapsize kwarg (#45)" begin
    mktempdir() do dir
        d = LMDBDict{String, String}(dir; mapsize = 64 * 1024 * 1024)
        d["k"] = "v"
        @test d["k"] == "v"
    end
end

end
