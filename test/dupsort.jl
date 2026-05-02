module LMDB_DupSort
    using LMDB
    using Test

    # DupSort: a single key can hold multiple sorted values. Verify the
    # dup-aware cursor ops navigate within and across keys correctly, and
    # that delete!(txn, dbi, key, val) removes one specific dup.
    mktempdir() do dir
        environment(dir) do env
            start(env) do txn
                open(txn, flags = Cuint(LMDB.MDB_DUPSORT)) do dbi
                    LMDB.put!(txn, dbi, "k1", "a")
                    LMDB.put!(txn, dbi, "k1", "b")
                    LMDB.put!(txn, dbi, "k1", "c")
                    LMDB.put!(txn, dbi, "k2", "x")
                    LMDB.put!(txn, dbi, "k2", "y")

                    LMDB.open(txn, dbi) do cur
                        # Position at first entry; walk through k1's dups.
                        @test LMDB.seek!(cur, String) == "k1"
                        @test LMDB.value(cur, String) == "a"
                        @test LMDB.next_dup!(cur, String) == "b"
                        @test LMDB.next_dup!(cur, String) == "c"
                        @test LMDB.next_dup!(cur, String) === nothing  # no more dups

                        # Jump to next key, skipping any remaining dups (none here).
                        @test LMDB.next_nodup!(cur, String) == "k2"
                        @test LMDB.value(cur, String) == "x"
                        @test LMDB.next_dup!(cur, String) == "y"

                        # Reset to first dup of current key.
                        @test LMDB.seek_first_dup!(cur, String) == "x"
                        @test LMDB.seek_last_dup!(cur, String) == "y"
                        @test LMDB.prev_dup!(cur, String) == "x"

                        # prev_nodup! moves back to the last dup of the previous key.
                        @test LMDB.prev_nodup!(cur, String) == "k1"
                        @test LMDB.value(cur, String) == "c"
                    end

                    # Count dups for k1 via cursor count().
                    LMDB.open(txn, dbi) do cur
                        @test LMDB.seek!(cur, "k1", String) == "k1"
                        @test count(cur) == 3
                    end

                    # Dup-aware delete: delete!(txn, dbi, key, val) removes only
                    # that one duplicate.
                    LMDB.delete!(txn, dbi, "k1", "b")
                    LMDB.open(txn, dbi) do cur
                        @test LMDB.seek!(cur, "k1", String) == "k1"
                        @test LMDB.value(cur, String) == "a"
                        @test LMDB.next_dup!(cur, String) == "c"  # "b" is gone
                        @test LMDB.next_dup!(cur, String) === nothing
                    end
                end
            end
        end
    end
end
