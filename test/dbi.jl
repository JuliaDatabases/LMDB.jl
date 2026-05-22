using LMDB
using Test

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
