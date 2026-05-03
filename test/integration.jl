using LMDB
using Test

# cuTile-shaped framed value: 8-byte LE atime prefix, then the payload.
# Defined at file scope to demonstrate the `Base.read(::IO, …)`
# extension contract and to regression-guard it (a downstream package
# — cuTile's DiskCache — relies on being able to plug in its own
# decoder against the abstract `IO`, without depending on
# `LMDB.MDBValueIO` in its own type signatures).
struct AtimedBlob end
const _ATIME_PREFIX = 8

function Base.read(io::IO, ::Type{AtimedBlob})
    bytesavailable(io) < _ATIME_PREFIX && return UInt8[]
    skip(io, _ATIME_PREFIX)
    return read(io, Vector{UInt8})
end

pack_atimed(atime::UInt64, payload::Vector{UInt8}) = begin
    out = Vector{UInt8}(undef, _ATIME_PREFIX + length(payload))
    GC.@preserve out unsafe_store!(Ptr{UInt64}(pointer(out)), htol(atime))
    copyto!(out, _ATIME_PREFIX + 1, payload, 1, length(payload))
    out
end

@testset "Integration" begin

# Power-user pattern: open an env via the Environment kwargs ctor, run
# a write txn through the Julia API, then a read txn through a cursor walk
# using only the Julia API + raw MDB_val refs (the shape cuTile.DiskCache
# follows). Regression guard: ensures no future change breaks the
# `walk(...) do k_ref, v_ref` zero-copy idiom.
mktempdir() do dir
    env = Environment(dir;
                      mapsize    = 1 << 28,
                      maxreaders = 64,
                      flags      = MDB_NOTLS | MDB_NORDAHEAD)
    try
        dbi, psize = start(env) do txn
            d = open(txn)
            (d, LMDB.stat(txn, d).psize)
        end
        @test psize > 0

        # Populate.
        start(env) do txn
            for i in 1:5
                LMDB.put!(txn, dbi, "key$(i)", "value$(i)")
            end
        end

        # Julia-API read txn + cursor walk over the LMDB-owned mmap, like
        # cuTile's eviction scan: zero allocations beyond the per-entry
        # tuple.
        entries = Tuple{String, Int}[]
        start(env; flags = MDB_RDONLY) do txn
            LMDB.open(txn, dbi) do cur
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

        # tryget vs is_notfound — common cuTile-shaped read path.
        start(env; flags = MDB_RDONLY) do txn
            @test LMDB.tryget(txn, dbi, "key3", String) == "value3"
            @test LMDB.tryget(txn, dbi, "ghost", String) === nothing
        end

        # Batch delete: present keys return true, missing return false,
        # no exception on either path. cuTile's `_delete_batch!` uses
        # the Bool to count actual evictions.
        deleted = 0
        start(env) do txn
            for k in ["key1", "ghost", "key3"]
                LMDB.delete!(txn, dbi, k) && (deleted += 1)
            end
        end
        @test deleted == 2
        start(env; flags = MDB_RDONLY) do txn
            @test LMDB.tryget(txn, dbi, "key1", String) === nothing
            @test LMDB.tryget(txn, dbi, "key2", String) == "value2"
            @test LMDB.tryget(txn, dbi, "key3", String) === nothing
        end

        # MDBValueIO extension: write an 8-byte-prefixed framed value
        # and read it back via `tryget(..., AtimedBlob)`, getting the
        # payload tail with one alloc + skip + copy, no slicing.
        payload = Vector{UInt8}("cubin-bytes-here")
        atime = UInt64(0xdeadbeefcafebabe)
        start(env) do txn
            LMDB.put!(txn, dbi, "framed", pack_atimed(atime, payload))
        end
        start(env; flags = MDB_RDONLY) do txn
            @test LMDB.tryget(txn, dbi, "framed", AtimedBlob) == payload
            @test LMDB.tryget(txn, dbi, "ghost",  AtimedBlob) === nothing
        end
    finally
        close(env)
    end
end

end  # @testset "Integration"
