module LMDB_DBI
    using LMDB
    using Test

    const dbname = "testdb"
    key = 10
    val = "key value is "

    # Create dir
    mkdir(dbname)
    try

        # Procedural style
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
                    println("Got value for key $(k): $(value)")
                    @test value == val*string(k)
                    delete!(txn, dbi, k)
                    k += 1
                    value = get(txn, dbi, k, String)
                    println("Got value for key $(k): $(value)")
                    @test value == val*string(k)
                    delete!(txn, dbi, k, value)
                    @test_throws LMDBError get(txn, dbi, k, String)
                    k += 1
                    value = get(txn, dbi, k, Int)
                    println("Got value for key $(k): $(value)")
                    @test value == k
                    k += 1
                    value = get(txn, dbi, k, Vector{Int})
                    println("Got value for key $(k): $(value)")
                    @test value == [key, key+1, key+2]
                end
            end
        end

    finally
        rm(dbname, recursive=true)
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
                    @test s isa LMDB.MDB_stat
                    @test s.ms_entries == 2
                    @test s.ms_psize > 0
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
end
