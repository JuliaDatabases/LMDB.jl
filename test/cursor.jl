@testset "Cursor" begin

key = 10
val = "key value is "

# Exercise manual and do-block cursor lifecycles.
mktempdir() do dbname
    env = LMDB.Environment(dbname)
    try
        txn = LMDB.Transaction(env)
        dbi = LMDB.Database(txn)
        LMDB.commit(txn)

        txn = LMDB.Transaction(env)
        cur = LMDB.Cursor(txn, dbi)
        try
            @test 0 == put!(cur, key+1, val*string(key+1))
            @test 0 == put!(cur, key, val*string(key))
            ks = typeof(key)[]
            LMDB.walk(cur) do k_ref, _
                push!(ks, read(LMDB.MDBValueIO(k_ref[]), typeof(key)))
            end
            @test issetequal(ks, [11, 10])
        finally
            close(cur)
            LMDB.commit(txn)
        end
        @test !isopen(cur)
        @test !isopen(txn)
    finally
        close(env)
    end
    @test !isopen(env)

    LMDB.Environment(dbname) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.transaction(cur) === txn
                    @test LMDB.database(cur) === dbi
                    @test LMDB.seek!(cur, key, typeof(key)) == key
                    v = LMDB.value(cur, String)
                    @test val*string(key) == v
                end
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "a", "1")
                LMDB.put!(txn, dbi, "b", "2")
                LMDB.put!(txn, dbi, "c", "3")

                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, String) == "a"
                    @test LMDB.mdb_cursor_is_db(cur) == 0
                    @test LMDB.value(cur, String) == "1"
                    @test LMDB.key(cur, String) == "a"
                    @test LMDB.item(cur, String, String) == ("a" => "1")

                    @test LMDB.next!(cur, String) == "b"
                    @test LMDB.value(cur, String) == "2"

                    @test LMDB.seek_last!(cur, String) == "c"
                    @test LMDB.prev!(cur, String) == "b"

                    @test LMDB.seek!(cur, "a", String) == "a"
                    @test LMDB.seek!(cur, "missing", String) === nothing

                    @test LMDB.seek_range!(cur, "ab", String) == "b"
                    @test LMDB.seek_range!(cur, "z", String) === nothing

                    ks = String[]
                    LMDB.walk(cur) do k_ref, _
                        push!(ks, read(LMDB.MDBValueIO(k_ref[]), String))
                    end
                    @test ks == ["a", "b", "c"]

                    ks2 = String[]
                    LMDB.walk(cur; from="b") do k_ref, _
                        push!(ks2, read(LMDB.MDBValueIO(k_ref[]), String))
                    end
                    @test ks2 == ["b", "c"]

                    ks3 = String[]
                    LMDB.walk(cur; from="z") do k_ref, _
                        push!(ks3, read(LMDB.MDBValueIO(k_ref[]), String))
                    end
                    @test isempty(ks3)

                    kv = Pair{String, String}[]
                    LMDB.walk(cur, String, String) do k, v
                        push!(kv, k => v)
                    end
                    @test kv == ["a" => "1", "b" => "2", "c" => "3"]

                    seen = Pair{String, String}[]
                    LMDB.walk(cur, String, String) do k, v
                        push!(seen, k => v)
                        k == "b" ? false : nothing
                    end
                    @test seen == ["a" => "1", "b" => "2"]
                end
            end
        end
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, String) === nothing
                    @test LMDB.seek_last!(cur, String) === nothing
                    @test LMDB.seek!(cur, "x", String) === nothing
                    @test LMDB.seek_range!(cur, "x", String) === nothing

                    ks = String[]
                    LMDB.walk(cur) do k_ref, _
                        push!(ks, read(LMDB.MDBValueIO(k_ref[]), String))
                    end
                    @test isempty(ks)
                end
            end
        end
    end
end

# Cursor deletion reports `EINVAL` rather than `MDB_NOTFOUND` when unpositioned.
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "a", "1")
                LMDB.put!(txn, dbi, "b", "2")

                LMDB.Cursor(txn, dbi) do cur
                    @test LMDB.seek!(cur, "a", String) == "a"
                    LMDB.delete!(cur)
                    LMDB.delete!(cur)
                    @test_throws LMDBError LMDB.delete!(cur)
                end
                @test get(txn, dbi, "a", String, nothing) === nothing
                @test get(txn, dbi, "b", String, nothing) === nothing
            end
        end
    end
end

end
