module LMDB_Integration
    using LMDB
    using Test

    # Power-user pattern: open an env via the Environment kwargs ctor, run
    # a write txn through tier-2, then a read txn through a cursor walk
    # using only tier-2 + raw MDB_val refs (the shape cuTile.DiskCache
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
                s = LMDB.stat(txn, d)
                (d, Int(s.ms_psize))
            end
            @test psize > 0

            # Populate.
            start(env) do txn
                for i in 1:5
                    LMDB.put!(txn, dbi, "key$(i)", "value$(i)")
                end
            end

            # Tier-2 read txn + cursor walk over the LMDB-owned mmap, like
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
        finally
            close(env)
        end
    end
end
