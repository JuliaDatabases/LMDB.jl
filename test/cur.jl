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
            ks = typeof(key)[]
            LMDB.walk(cur) do k_ref, _
                push!(ks, read(LMDB.MDBValueIO(k_ref[]), typeof(key)))
            end
            @test issetequal(ks, [11, 10])
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

    # Block style: parent accessors return the actual handles, not synthetic ones.
    environment(dbname) do env
        start(env) do txn
            open(txn) do dbi
                open(txn, dbi) do cur
                    @test transaction(cur) === txn
                    @test database(cur) === dbi
                    @test LMDB.seek!(cur, key, typeof(key)) == key
                    v = LMDB.value(cur, String)
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
                            push!(ks, read(LMDB.MDBValueIO(k_ref[]), String))
                        end
                        @test ks == ["a", "b", "c"]

                        # walk from a starting key
                        ks2 = String[]
                        LMDB.walk(cur; from="b") do k_ref, _
                            push!(ks2, read(LMDB.MDBValueIO(k_ref[]), String))
                        end
                        @test ks2 == ["b", "c"]

                        # walk from a key past the last entry — no callbacks.
                        ks3 = String[]
                        LMDB.walk(cur; from="z") do k_ref, _
                            push!(ks3, read(LMDB.MDBValueIO(k_ref[]), String))
                        end
                        @test isempty(ks3)

                        # typed walk: each ref decoded via read(MDBValueIO, K)
                        # / read(MDBValueIO, V).
                        kv = Pair{String, String}[]
                        LMDB.walk(cur, String, String) do k, v
                            push!(kv, k => v)
                        end
                        @test kv == ["a" => "1", "b" => "2", "c" => "3"]

                        # typed walk respects the false-stops contract.
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
                            push!(ks, read(LMDB.MDBValueIO(k_ref[]), String))
                        end
                        @test isempty(ks)
                    end
                end
            end
        end
    end

    # Cursor.delete!: removes the entry the cursor is on; LMDB advances to
    # the next entry. Throws on an unpositioned cursor (EINVAL), unlike the
    # txn-based `delete!(txn, dbi, key)` which is Bool-returning on
    # MDB_NOTFOUND.
    mktempdir() do dir
        environment(dir) do env
            start(env) do txn
                open(txn) do dbi
                    LMDB.put!(txn, dbi, "a", "1")
                    LMDB.put!(txn, dbi, "b", "2")

                    LMDB.open(txn, dbi) do cur
                        @test LMDB.seek!(cur, "a", String) == "a"
                        LMDB.delete!(cur)             # removes "a", cursor now on "b"
                        LMDB.delete!(cur)             # removes "b"
                        @test_throws LMDBError LMDB.delete!(cur)  # no live entry
                    end
                    @test LMDB.tryget(txn, dbi, "a", String) === nothing
                    @test LMDB.tryget(txn, dbi, "b", String) === nothing
                end
            end
        end
    end
end
