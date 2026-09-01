@testset "DupSort" begin

# Exercise navigation within and between duplicate sets.
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn; flags = LMDB.MDB_DUPSORT) do dbi
                LMDB.put!(txn, dbi, "k1", "a")
                LMDB.put!(txn, dbi, "k1", "b")
                LMDB.put!(txn, dbi, "k1", "c")
                LMDB.put!(txn, dbi, "k2", "x")
                LMDB.put!(txn, dbi, "k2", "y")

                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, String) == "k1"
                    @test LMDB.value(cur, String) == "a"
                    @test LMDB.next_dup!(cur, String) == "b"
                    @test LMDB.next_dup!(cur, String) == "c"
                    @test LMDB.next_dup!(cur, String) === nothing

                    @test LMDB.next_nodup!(cur, String) == "k2"
                    @test LMDB.value(cur, String) == "x"
                    @test LMDB.next_dup!(cur, String) == "y"

                    @test LMDB.seek_first_dup!(cur, String) == "x"
                    @test LMDB.seek_last_dup!(cur, String) == "y"
                    @test LMDB.prev_dup!(cur, String) == "x"

                    @test LMDB.prev_nodup!(cur, String) == "k1"
                    @test LMDB.value(cur, String) == "c"
                end

                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, "k1", String) == "k1"
                    @test count(cur) == 3
                end

                LMDB.delete!(txn, dbi, "k1", "b")
                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, "k1", String) == "k1"
                    @test LMDB.value(cur, String) == "a"
                    @test LMDB.next_dup!(cur, String) == "c"
                    @test LMDB.next_dup!(cur, String) === nothing
                end
            end
        end
    end
end

end
