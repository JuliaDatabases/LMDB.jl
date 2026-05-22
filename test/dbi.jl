using LMDB
using Test

# Fixtures for the typed-read extension-point tests below. Defined at
# module scope because `const` and `struct` aren't allowed inside a
# `@testset` block.
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

@testset "DBI" begin

key = 10
val = "key value is "

# Procedural style + block style smoke test, exercising String, Int, and
# Vector{Int} round-trips through put!/get/delete!.
mktempdir() do dbname
    env = create()
    try
        open(env, dbname)
        txn = start(env)
        dbi = open(txn)
        put!(txn, dbi, key+1, val*string(key+1))
        put!(txn, dbi, key, val*string(key))
        put!(txn, dbi, key+2, key+2)
        put!(txn, dbi, key+3, [key, key+1, key+2])
        @test isopen(txn)
        commit(txn)
        @test !isopen(txn)
        close(env, dbi)
        @test !isopen(dbi)
    finally
        close(env)
    end
    @test !isopen(env)

    # Block style
    create() do env
        set!(env, LMDB.MDB_NOSYNC)
        open(env, dbname)
        start(env) do txn
            open(txn, flags = Cuint(LMDB.MDB_REVERSEKEY)) do dbi
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

# tryget / get-with-default / stat(txn, dbi) — fresh env so the entry
# count is deterministic.
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                LMDB.put!(txn, dbi, "k1", "v1")
                LMDB.put!(txn, dbi, "k2", "v2")

                @test LMDB.tryget(txn, dbi, "k1", String) == "v1"
                @test LMDB.tryget(txn, dbi, "missing", String) === nothing
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

# put_reserved!: callback-style MDB_RESERVE write.
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                # Write a 16-byte value where bytes 0..7 are a UInt64
                # header and bytes 8..15 are payload. The buffer hands
                # back is the LMDB-allocated mmap page; we fill it
                # in place — no intermediate Vector.
                LMDB.put_reserved!(txn, dbi, "framed", 16) do buf
                    @test buf isa Vector{UInt8}
                    @test length(buf) == 16
                    unsafe_store!(Ptr{UInt64}(pointer(buf)),
                                  htol(UInt64(0xdeadbeef)))
                    for i in 1:8
                        buf[8 + i] = UInt8(i)
                    end
                end
                raw = LMDB.tryget(txn, dbi, "framed", Vector{UInt8})
                @test length(raw) == 16
                @test ltoh(reinterpret(UInt64, raw[1:8])[1]) ==
                      UInt64(0xdeadbeef)
                @test raw[9:16] == UInt8[1, 2, 3, 4, 5, 6, 7, 8]

                # Return value: whatever the callback returns.
                rv = LMDB.put_reserved!(txn, dbi, "rv", 4) do buf
                    fill!(buf, 0xab)
                    :sentinel
                end
                @test rv === :sentinel
            end
        end
    end
end

# delete!: Bool-returning, idempotent on MDB_NOTFOUND.
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                LMDB.put!(txn, dbi, "k1", "v1")
                LMDB.put!(txn, dbi, "k2", "v2")

                # Present key → true, returns and entry is gone.
                @test LMDB.delete!(txn, dbi, "k1") === true
                @test LMDB.tryget(txn, dbi, "k1", String) === nothing

                # Missing key → false, no exception.
                @test LMDB.delete!(txn, dbi, "ghost") === false
                @test LMDB.delete!(txn, dbi, "k1") === false  # already gone

                # Idempotent: a second delete on the same key is a no-op.
                @test LMDB.delete!(txn, dbi, "k2") === true
                @test LMDB.delete!(txn, dbi, "k2") === false
            end
        end
    end
end

# replace! / pop!
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                # replace! on a missing key returns nothing and creates the entry.
                @test LMDB.replace!(txn, dbi, "k", "v1") === nothing
                @test LMDB.tryget(txn, dbi, "k", String) == "v1"

                # replace! on an existing key returns the old value.
                @test LMDB.replace!(txn, dbi, "k", "v2") == "v1"
                @test LMDB.tryget(txn, dbi, "k", String) == "v2"

                # pop! returns the value and deletes.
                @test LMDB.pop!(txn, dbi, "k", String) == "v2"
                @test LMDB.tryget(txn, dbi, "k", String) === nothing
                # pop! on a missing key returns nothing.
                @test LMDB.pop!(txn, dbi, "k", String) === nothing
            end
        end
    end
end

# Round-trip a custom bitstype through put!/tryget/walk using only the
# IO-based extension point (`Base.read(io::IO, ::Type{Point2D})`,
# defined at module scope above).
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                LMDB.put!(txn, dbi, "origin", Point2D(0f0, 0f0))
                LMDB.put!(txn, dbi, "p1",     Point2D(1.5f0, 2.5f0))

                @test LMDB.tryget(txn, dbi, "p1", Point2D)     == Point2D(1.5f0, 2.5f0)
                @test LMDB.tryget(txn, dbi, "origin", Point2D) == Point2D(0f0, 0f0)
                @test get(txn, dbi, "p1", Point2D)             == Point2D(1.5f0, 2.5f0)

                # The Vector{E} overload also works for any bitstype E,
                # without the user defining anything extra.
                @test LMDB.tryget(txn, dbi, "p1", Vector{Point2D}) ==
                      [Point2D(1.5f0, 2.5f0)]

                # Typed walk decodes both K and V through Base.read.
                seen = Pair{String,Point2D}[]
                LMDB.open(txn, dbi) do cur
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

# Framed values: a custom `Base.read` can use the IO interface
# (`skip`, `position`) to step past a header before decoding the
# payload. Exercises the IO contract from inside user code (see
# `FramedU64` / `FRAME_MAGIC` at module scope).
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                LMDB.put_reserved!(txn, dbi, "framed", 12) do buf
                    unsafe_store!(Ptr{UInt32}(pointer(buf)), FRAME_MAGIC)
                    unsafe_store!(Ptr{UInt64}(pointer(buf) + 4), htol(UInt64(0x1234_5678)))
                end
                @test LMDB.tryget(txn, dbi, "framed", FramedU64) ==
                      FramedU64(0x1234_5678)
            end
        end
    end
end

# Non-Array AbstractArray inputs (e.g. `ReinterpretArray`, contiguous
# `SubArray`) flow through `cconvert(Ptr{MDB_val}, ::AbstractArray)`.
mktempdir() do dir
    environment(dir) do env
        start(env) do txn
            open(txn) do dbi
                # ReinterpretArray view onto a backing UInt64 vector.
                ra_key = reinterpret(UInt8, UInt64[0xdeadbeefcafef00d])
                @test !(ra_key isa Array)
                LMDB.put!(txn, dbi, ra_key, "v-reinterpret")
                @test LMDB.tryget(txn, dbi, ra_key, String) == "v-reinterpret"
                @test LMDB.tryget(txn, dbi, collect(ra_key), String) == "v-reinterpret"

                # Contiguous SubArray.
                backing = collect(0x01:0x10)
                sv_key = view(backing, 4:8)
                @test !(sv_key isa Array)
                LMDB.put!(txn, dbi, sv_key, "v-subarray")
                @test LMDB.tryget(txn, dbi, sv_key, String) == "v-subarray"
                @test LMDB.tryget(txn, dbi, collect(sv_key), String) == "v-subarray"
            end
        end
    end
end

end  # @testset "DBI"
