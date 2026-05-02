module LMDB_CUR
    using LMDB
    using Test

    const dbname = "testdb"
    key = 10
    val = "key value is "

    # Create dir
    mkdir(dbname)

    # Procedural style
    env = create()
    try
        open(env, dbname)
        txn = start(env)
        dbi = open(txn)
        commit(txn)

        txn = start(env)
        cur = open(txn, dbi)
        try
            @test 0 == put!(cur, key+1, val*string(key+1))
            @test 0 == put!(cur, key, val*string(key))
            @test issetequal(collect(keys(cur, typeof(key))), [11, 10])
        finally
            close(cur)
            commit(txn)
        end
        @test !isopen(cur)
        @test !isopen(txn)
    finally
        close(env)
    end
    @test !isopen(env)

    # Block style
    environment(dbname) do env # open environment
        start(env) do txn # start transaction
            open(txn) do dbi # open database
                open(txn, dbi) do cur # open cursor
                    curtxn = transaction(cur)
                    @test curtxn.handle == txn.handle
                    curdbi = database(cur)
                    @test curdbi.handle == dbi.handle
                    v = get(cur, key, String)
                    println("Got value for key $(key): $(v)")
                    @test val*string(key) == v
                end
            end
        end
    end

    # Remove db dir
    rm(dbname, recursive=true)

    # Cursor positioning + walk primitives.
    mktempdir() do dir
        environment(dir) do env
            start(env) do txn
                open(txn) do dbi
                    LMDB.put!(txn, dbi, "a", "1")
                    LMDB.put!(txn, dbi, "b", "2")
                    LMDB.put!(txn, dbi, "c", "3")

                    LMDB.open(txn, dbi) do cur
                        @test LMDB.seek!(cur, String) == "a"
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

                        # walk over everything
                        ks = String[]
                        LMDB.walk(cur) do k_ref, _
                            push!(ks, LMDB.mbd_unpack(String, k_ref))
                        end
                        @test ks == ["a", "b", "c"]

                        # walk from a starting key
                        ks2 = String[]
                        LMDB.walk(cur; from="b") do k_ref, _
                            push!(ks2, LMDB.mbd_unpack(String, k_ref))
                        end
                        @test ks2 == ["b", "c"]

                        # walk from a key past the last entry — no callbacks.
                        ks3 = String[]
                        LMDB.walk(cur; from="z") do k_ref, _
                            push!(ks3, LMDB.mbd_unpack(String, k_ref))
                        end
                        @test isempty(ks3)
                    end
                end
            end
        end
    end

    # seek!/next! on an empty database returns nothing.
    mktempdir() do dir
        environment(dir) do env
            start(env) do txn
                open(txn) do dbi
                    LMDB.open(txn, dbi) do cur
                        @test LMDB.seek!(cur, String) === nothing
                        @test LMDB.seek_last!(cur, String) === nothing
                        @test LMDB.seek!(cur, "x", String) === nothing
                        @test LMDB.seek_range!(cur, "x", String) === nothing

                        ks = String[]
                        LMDB.walk(cur) do k_ref, _
                            push!(ks, LMDB.mbd_unpack(String, k_ref))
                        end
                        @test isempty(ks)
                    end
                end
            end
        end
    end
end
