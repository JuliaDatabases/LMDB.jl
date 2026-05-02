module LMDB_Env
    using LMDB
    using Test

    const dbname = "testdb"

    # Open environemnt
    env = create()
    @test env.handle != C_NULL
    @test env[:Readers] == 126
    @test env[:KeySize] == 511
    @test env[:Flags] == 0

    # Manipulate flags
    @test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    set!(env, LMDB.MDB_NOSYNC)
    @test isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    unset!(env, LMDB.MDB_NOSYNC)
    @test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))

    # Parameters
    @test (env[:Readers] = 100) == 100
    @test (env[:MapSize] = 1000^2) == 1000^2
    @test (env[:DBs] = 10) == 10
    @test env[:Readers] == 100

    # Map sizes >4 GiB must not silently truncate (issue #38).
    big_mapsize = Csize_t(5) * 1024 * 1024 * 1024
    @test (env[:MapSize] = big_mapsize) == big_mapsize

    # :Flags setindex! used to fall through to a warn(...) that no longer
    # exists, throwing UndefVarError (issue #24).
    env[:Flags] = LMDB.MDB_NOSYNC
    @test isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    unset!(env, LMDB.MDB_NOSYNC)

    # Unknown options used to be silently swallowed.
    @test_throws ArgumentError env[:Bogus] = 1

    # open db
    isdir(dbname) || mkdir(dbname)
    try
        ret = open(env, dbname)
        @test ret[1] == 0

        # stat(env) returns the main DB's stats; before any puts, there are
        # no entries and a positive page size.
        s = stat(env)
        @test s isa LMDB.MDB_stat
        @test s.ms_psize > 0
        @test s.ms_entries == 0

        # Close environment
        close(env)
        @test !isopen(env)

        # do block
        create() do env
            set!(env, LMDB.MDB_NOSYNC)
            open(env, dbname)
            @test isopen(env)
        end
    finally
        rm(dbname, recursive=true)
    end

    # reader_check / reader_list / copy
    mktempdir() do dir
        environment(dir) do env
            # Fresh env: no stale readers.
            @test reader_check(env) == 0

            # reader_list always emits a header line listing slot fields.
            txt = reader_list(env)
            @test txt isa String
            @test !isempty(txt)

            # Round-trip a copy.
            start(env) do txn
                open(txn) do dbi
                    LMDB.put!(txn, dbi, "k", "v")
                end
            end
            mktempdir() do dst
                copy(env, dst)
                environment(dst) do env2
                    start(env2) do txn
                        open(txn) do dbi
                            @test LMDB.tryget(txn, dbi, "k", String) == "v"
                        end
                    end
                end
            end
            mktempdir() do dst
                copy(env, dst; compact=true)
                environment(dst) do env2
                    start(env2) do txn
                        open(txn) do dbi
                            @test LMDB.tryget(txn, dbi, "k", String) == "v"
                        end
                    end
                end
            end
        end
    end
end
