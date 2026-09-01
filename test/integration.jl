# Model cuTile's decoder, which extends `Base.read(::IO, ...)` without naming
# `LMDB.MDBValueIO`.
struct AtimedBlob end
const ATIME_PREFIX = 8

function Base.read(io::IO, ::Type{AtimedBlob})
    bytesavailable(io) < ATIME_PREFIX && return UInt8[]
    skip(io, ATIME_PREFIX)
    return read(io, Vector{UInt8})
end

pack_atimed(atime::UInt64, payload::Vector{UInt8}) = begin
    out = Vector{UInt8}(undef, ATIME_PREFIX + length(payload))
    GC.@preserve out unsafe_store!(Ptr{UInt64}(pointer(out)), htol(atime))
    copyto!(out, ATIME_PREFIX + 1, payload, 1, length(payload))
    out
end

@testset "Integration" begin

# Exercise the wrapper and raw `MDB_val` callback paths used by cuTile.DiskCache.
mktempdir() do dir
    env = LMDB.Environment(dir;
                      mapsize    = 1 << 28,
                      maxreaders = 64,
                      flags      = LMDB.MDB_NOTLS | LMDB.MDB_NORDAHEAD)
    try
        dbi, psize = LMDB.Transaction(env) do txn
            d = LMDB.Database(txn)
            (d, LMDB.stat(txn, d).psize)
        end
        @test psize > 0

        LMDB.Transaction(env) do txn
            for i in 1:5
                LMDB.put!(txn, dbi, "key$(i)", "value$(i)")
            end
        end

        # Read sizes directly from LMDB-owned values, as in an eviction scan.
        entries = Tuple{String, Int}[]
        LMDB.Transaction(env; flags = LMDB.MDB_RDONLY) do txn
            LMDB.Cursor(txn, dbi) do cur
                LMDB.walk(cur) do k_ref, v_ref
                    kv = k_ref[]; vv = v_ref[]
                    k = unsafe_string(Ptr{UInt8}(kv.mv_data), kv.mv_size)
                    push!(entries, (k, Int(vv.mv_size)))
                end
            end
        end
        @test length(entries) == 5
        @test first.(entries) == ["key$i" for i in 1:5]
        @test all(e -> e[2] == sizeof("value1"), entries)

        LMDB.Transaction(env; flags = LMDB.MDB_RDONLY) do txn
            @test get(txn, dbi, "key3", String, nothing) == "value3"
            @test get(txn, dbi, "ghost", String, nothing) === nothing
        end

        # cuTile's batch deletion uses the Bool result to count evictions.
        deleted = 0
        LMDB.Transaction(env) do txn
            for k in ["key1", "ghost", "key3"]
                LMDB.delete!(txn, dbi, k) && (deleted += 1)
            end
        end
        @test deleted == 2
        LMDB.Transaction(env; flags = LMDB.MDB_RDONLY) do txn
            @test get(txn, dbi, "key1", String, nothing) === nothing
            @test get(txn, dbi, "key2", String, nothing) == "value2"
            @test get(txn, dbi, "key3", String, nothing) === nothing
        end

        # Decode a framed value through the abstract-IO extension point.
        payload = Vector{UInt8}("cubin-bytes-here")
        atime = UInt64(0xdeadbeefcafebabe)
        LMDB.Transaction(env) do txn
            LMDB.put!(txn, dbi, "framed", pack_atimed(atime, payload))
        end
        LMDB.Transaction(env; flags = LMDB.MDB_RDONLY) do txn
            @test get(txn, dbi, "framed", AtimedBlob, nothing) == payload
            @test get(txn, dbi, "ghost",  AtimedBlob, nothing) === nothing
        end
    finally
        close(env)
    end
end

end
