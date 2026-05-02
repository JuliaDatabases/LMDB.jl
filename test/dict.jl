using Test, LMDB

@testset "Dictionary-like interface" begin

    # Basic round-trip with String keys, Float64 values.
    mktempdir() do dir
        d = LMDBDict{String, Float64}(dir)
        d["x"] = 5.0
        d["y"] = 12.0
        d["z"] = 3
        @test d["x"] === 5.0
        @test d["y"] === 12.0
        @test d["z"] === 3.0
        @test haskey(d, "x")
        @test !haskey(d, "a")

        # AbstractDict iteration: keys/values/pairs are lazy iterators.
        @test collect(keys(d)) == ["x", "y", "z"]
        @test collect(values(d)) == [5.0, 12.0, 3.0]
        @test collect(d) == ["x"=>5.0, "y"=>12.0, "z"=>3.0]
        @test collect(pairs(d)) == ["x"=>5.0, "y"=>12.0, "z"=>3.0]
        @test length(d) == 3
        @test !isempty(d)
        @test eltype(d) == Pair{String, Float64}
        @test keytype(d) == String
        @test valtype(d) == Float64

        # in(::Pair) — comes free from AbstractDict.
        @test ("x" => 5.0) in d
        @test !(("x" => 99.0) in d)

        # `for` loop yields Pair{K,V}.
        seen = Pair{String,Float64}[]
        for kv in d
            push!(seen, kv)
        end
        @test seen == ["x"=>5.0, "y"=>12.0, "z"=>3.0]

        # delete! / pop! / KeyError on missing.
        delete!(d, "z")
        @test !haskey(d, "z")
        @test_throws KeyError d["z"]
        @test_throws KeyError pop!(d, "z")
        @test pop!(d, "z", :missing) === :missing
        @test pop!(d, "y") === 12.0
        @test !haskey(d, "y")
        @test LMDB.valuesize(d) == sizeof(Float64)*1  # only "x" left

        # `pop!(d)` (no key) pops the lexicographically-first entry.
        @test pop!(d) == ("x" => 5.0)
        @test isempty(d)
        @test_throws ArgumentError pop!(d)
        close(d)
    end

    # Int → Int with a numeric key range.
    mktempdir() do dir
        d = LMDBDict{Int64, Int16}(dir)
        for i in 1:10
            d[i] = i+1
        end
        @test collect(keys(d)) == 1:10
        @test collect(values(d)) == 2:11
        @test length(d) == 10
        @test d[2] === Int16(3)
        @test d[3.0] == 4
        @test eltype(d) == Pair{Int64, Int16}
        @test valtype(d) == Int16
        @test keytype(d) == Int64

        # empty! drops every entry.
        empty!(d)
        @test length(d) == 0
        @test isempty(d)
        @test_throws KeyError d[1]
        close(d)
    end

    # Hierarchical keys: prefix-scan helpers + list_dirs.
    mktempdir() do dir
        d = LMDBDict{String, Vector{Float32}}(dir)
        d["aa/a"] = Float32[1,2,3,4]
        d["aa/b"] = Float32.(2:12)
        d["aa/c"] = [10,11,12]
        d["b"]    = [0,0,0]
        @test d["aa/a"] == 1:4
        @test d["aa/b"] == 2:12
        @test d["aa/c"] == 10:12
        @test d["b"] == [0,0,0]

        @test LMDB.list_dirs(d) == ["aa/", "b"]
        @test LMDB.list_dirs(d, prefix = "aa/") == ["aa/a", "aa/b", "aa/c"]
        @test LMDB.scan_keys(d, prefix = "aa/") == ["aa/a", "aa/b", "aa/c"]
        @test LMDB.scan_values(d, prefix = "aa/") ==
              [Float32[1,2,3,4], Float32.(2:12), Float32[10,11,12]]
        @test LMDB.scan(d, prefix = "aa/") ==
              ["aa/a"=>Float32[1,2,3,4], "aa/b"=>Float32.(2:12),
               "aa/c"=>Float32[10,11,12]]
        @test LMDB.valuesize(d, prefix = "aa/") == sizeof(Float32)*18
        close(d)
    end

    # Iteration leaves no leftover state — a second pass returns the same
    # entries, and an interleaved `length` (which opens a separate read txn)
    # works mid-iteration.
    mktempdir() do dir
        d = LMDBDict{String, Int}(dir)
        d["a"] = 1; d["b"] = 2; d["c"] = 3
        @test collect(d) == ["a"=>1, "b"=>2, "c"=>3]
        @test collect(d) == ["a"=>1, "b"=>2, "c"=>3]
        n = 0
        for _ in d
            n += 1
            @test length(d) == 3
        end
        @test n == 3
        close(d)
    end

    @testset "env kwargs in LMDBDict ctor (#45)" begin
        mktempdir() do dir
            big = Csize_t(8) * 1024^3  # 8 GiB
            d = LMDBDict{String, Int64}(dir; mapsize=big, readers=42, dbs=4)
            @test d.env[:Readers] == 42
            @test LMDB.info(d.env).mapsize == big
            d["x"] = 1
            @test d["x"] === Int64(1)
            close(d)
        end
    end

    @testset "double close is a no-op (#42)" begin
        mktempdir() do dir
            d = LMDBDict{String,Int}(dir)
            d["a"] = 1
            close(d)
            @test (close(d); true)
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

    @testset "String -> Int64 round-trip (#46)" begin
        mktempdir() do dir
            d = LMDBDict{String, Int64}(dir)
            d["aa"] = 2
            d["ab"] = 3
            d["ac"] = 2
            @test d["aa"] === Int64(2)
            @test d["ab"] === Int64(3)
            @test d["ac"] === Int64(2)
            @test collect(d) == ["aa"=>2, "ab"=>3, "ac"=>2]
        end
    end

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

    @testset "Generic AbstractDict machinery: merge!/filter!" begin
        mktempdir() do dir
            d = LMDBDict{String, Int}(dir)
            merge!(d, Dict("a" => 1, "b" => 2, "c" => 3))
            @test sort(collect(keys(d))) == ["a", "b", "c"]
            @test d["b"] == 2

            filter!(p -> isodd(p.second), d)
            @test sort(collect(keys(d))) == ["a", "c"]
            close(d)
        end
    end
end
