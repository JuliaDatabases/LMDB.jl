# Fixtures must be at module scope because `struct` and `const` cannot be local.
struct Point2D
    x::Float32
    y::Float32
end
Base.read(io::IO, ::Type{Point2D}) = read!(io, Ref{Point2D}())[]

struct FramedU64
    value::UInt64
end
const FRAME_MAGIC = htol(UInt32(0xCAFEF00D))
function Base.read(io::IO, ::Type{FramedU64})
    magic = read(io, UInt32)
    magic == FRAME_MAGIC || error("bad magic 0x$(string(magic, base=16))")
    pos_before = position(io)
    skip(io, 0)
    @assert position(io) == pos_before
    FramedU64(ltoh(read(io, UInt64)))
end


@testset "Database" begin

key = 10
val = "key value is "

# Exercise manual and do-block lifecycles with several value representations.
mktempdir() do dbname
    env = LMDB.Environment(dbname)
    try
        txn = LMDB.Transaction(env)
        dbi = LMDB.Database(txn)
        put!(txn, dbi, key+1, val*string(key+1))
        put!(txn, dbi, key, val*string(key))
        put!(txn, dbi, key+2, key+2)
        put!(txn, dbi, key+3, [key, key+1, key+2])
        @test isopen(txn)
        LMDB.commit(txn)
        @test !isopen(txn)
        close(env, dbi)
        @test !isopen(dbi)
    finally
        close(env)
    end
    @test !isopen(env)

    LMDB.Environment(dbname; flags = LMDB.MDB_NOSYNC) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn; flags = Cuint(LMDB.MDB_REVERSEKEY)) do dbi
                k = key
                value = get(txn, dbi, k, String)
                @test value == val*string(k)
                delete!(txn, dbi, k)
                k += 1
                value = get(txn, dbi, k, String)
                @test value == val*string(k)
                delete!(txn, dbi, k, value)
                @test_throws LMDBError get(txn, dbi, k, String)
                k += 1
                value = get(txn, dbi, k, Int)
                @test value == k
                k += 1
                value = get(txn, dbi, k, Vector{Int})
                @test value == [key, key+1, key+2]
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "k1", "v1")
                LMDB.put!(txn, dbi, "k2", "v2")

                @test get(txn, dbi, "k1", String, nothing) == "v1"
                @test get(txn, dbi, "missing", String, nothing) === nothing
                @test get(txn, dbi, "k2", String, "fallback") == "v2"
                @test get(txn, dbi, "missing", String, "fallback") == "fallback"

                s = LMDB.stat(txn, dbi)
                @test s isa NamedTuple
                @test s.entries == 2
                @test s.psize > 0
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                # Fill reserved LMDB storage with a header and payload.
                LMDB.put_reserved!(txn, dbi, "framed", 16) do buf
                    @test buf isa Vector{UInt8}
                    @test length(buf) == 16
                    unsafe_store!(Ptr{UInt64}(pointer(buf)),
                                  htol(UInt64(0xdeadbeef)))
                    for i in 1:8
                        buf[8 + i] = UInt8(i)
                    end
                end
                raw = get(txn, dbi, "framed", Vector{UInt8}, nothing)
                @test length(raw) == 16
                @test ltoh(reinterpret(UInt64, raw[1:8])[1]) ==
                      UInt64(0xdeadbeef)
                @test raw[9:16] == UInt8[1, 2, 3, 4, 5, 6, 7, 8]

                rv = LMDB.put_reserved!(txn, dbi, "rv", 4) do buf
                    fill!(buf, 0xab)
                    :sentinel
                end
                @test rv === :sentinel
                @test_throws ArgumentError LMDB.put_reserved!(_ -> nothing, txn, dbi,
                                                               "bad", -1)
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "k1", "v1")
                LMDB.put!(txn, dbi, "k2", "v2")

                @test LMDB.delete!(txn, dbi, "k1") === true
                @test get(txn, dbi, "k1", String, nothing) === nothing

                @test LMDB.delete!(txn, dbi, "ghost") === false
                @test LMDB.delete!(txn, dbi, "k1") === false

                @test LMDB.delete!(txn, dbi, "k2") === true
                @test LMDB.delete!(txn, dbi, "k2") === false
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                @test LMDB.replace!(txn, dbi, "k", "v1") === nothing
                @test get(txn, dbi, "k", String, nothing) == "v1"

                @test LMDB.replace!(txn, dbi, "k", "v2") == "v1"
                @test get(txn, dbi, "k", String, nothing) == "v2"

                @test LMDB.pop!(txn, dbi, "k", String) == "v2"
                @test get(txn, dbi, "k", String, nothing) === nothing
                @test LMDB.pop!(txn, dbi, "k", String) === nothing
            end
        end
    end
end

# Round-trip a custom bitstype through put!/get/walk using only the
# IO-based extension point (`Base.read(io::IO, ::Type{Point2D})`,
# defined at module scope above).
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "origin", Point2D(0f0, 0f0))
                LMDB.put!(txn, dbi, "p1",     Point2D(1.5f0, 2.5f0))

                @test get(txn, dbi, "p1", Point2D, nothing)     == Point2D(1.5f0, 2.5f0)
                @test get(txn, dbi, "origin", Point2D, nothing) == Point2D(0f0, 0f0)
                @test get(txn, dbi, "p1", Point2D)             == Point2D(1.5f0, 2.5f0)

                @test get(txn, dbi, "p1", Vector{Point2D}, nothing) ==
                      [Point2D(1.5f0, 2.5f0)]

                seen = Pair{String,Point2D}[]
                LMDB.Cursor(txn, dbi) do cur
                    LMDB.walk(cur, String, Point2D) do k, v
                        push!(seen, k => v)
                    end
                end
                @test sort(seen; by = first) ==
                      ["origin" => Point2D(0f0, 0f0),
                       "p1"     => Point2D(1.5f0, 2.5f0)]
            end
        end
    end
end

# Exercise `position` and `skip` from a custom decoder.
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put_reserved!(txn, dbi, "framed", 12) do buf
                    unsafe_store!(Ptr{UInt32}(pointer(buf)), FRAME_MAGIC)
                    unsafe_store!(Ptr{UInt64}(pointer(buf) + 4), htol(UInt64(0x1234_5678)))
                end
                @test get(txn, dbi, "framed", FramedU64, nothing) ==
                      FramedU64(0x1234_5678)
            end
        end
    end
end

# Pointer-compatible contiguous array wrappers can be stored without copying.
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                ra_key = reinterpret(UInt8, UInt64[0xdeadbeefcafef00d])
                @test !(ra_key isa Array)
                LMDB.put!(txn, dbi, ra_key, "v-reinterpret")
                @test get(txn, dbi, ra_key, String, nothing) == "v-reinterpret"
                @test get(txn, dbi, collect(ra_key), String, nothing) == "v-reinterpret"
                @test_throws ArgumentError get(txn, dbi, ra_key, Vector{String},
                                                nothing)

                backing = collect(0x01:0x10)
                sv_key = view(backing, 4:8)
                @test !(sv_key isa Array)
                LMDB.put!(txn, dbi, sv_key, "v-subarray")
                @test get(txn, dbi, sv_key, String, nothing) == "v-subarray"
                @test get(txn, dbi, collect(sv_key), String, nothing) == "v-subarray"

                noncontiguous = view(reshape(UInt8.(1:9), 3, 3), 1:2, 1:2)
                @test_throws ArgumentError LMDB.put!(txn, dbi, noncontiguous, "bad")
                @test_throws ArgumentError LMDB.put!(txn, dbi, ["not", "bits"], "bad")
            end
        end
    end
end

@testset "Database handle lifecycle" begin
    mktempdir() do dir
        LMDB.Environment(dir; maxdbs = 1) do env
            LMDB.Transaction(env) do txn
                dbi = LMDB.Database(txn, "named"; flags = LMDB.MDB_CREATE)
                LMDB.drop(txn, dbi; delete = true)
                @test !isopen(dbi)
            end
        end
    end
end

end
