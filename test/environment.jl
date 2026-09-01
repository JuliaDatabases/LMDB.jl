@testset "Environment" begin

mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        @test isopen(env)
        @test env[:Readers] == 126
        @test env[:KeySize] == LMDB.mdb_env_get_maxkeysize(env)
        @test env[:KeySize] > 0
        @test env[:Flags] == 0

        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.set!(env, LMDB.MDB_NOSYNC)
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.unset!(env, LMDB.MDB_NOSYNC)
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))

        @test LMDB.set!(env, LMDB.MDB_NOSYNC) === env
        @test LMDB.unset!(env, LMDB.MDB_NOSYNC) === env

        # Regression for #24: setting :Flags must not fall through.
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        env[:Flags] = LMDB.MDB_NOSYNC
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.unset!(env, LMDB.MDB_NOSYNC)

        @test_throws ArgumentError env[:Bogus] = 1
        @test_throws ArgumentError env[:Bogus]

        s = stat(env)
        @test s isa NamedTuple
        @test s.psize > 0
        @test s.entries == 0
    finally
        close(env)
        @test !isopen(env)
    end
end

mktempdir() do dir
    big = Csize_t(8) * 1024^3
    env = LMDB.Environment(dir; mapsize = big, pagesize = 8192,
                      maxreaders = 42, maxdbs = 4,
                      flags = LMDB.MDB_NOSYNC | LMDB.MDB_NOTLS)
    try
        @test isopen(env)
        @test env[:Readers] == 42
        @test LMDB.info(env).mapsize == big
        @test LMDB.stat(env).psize == 8192
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOTLS))
    finally
        close(env)
    end

    # The constructor must close the allocated handle if opening fails.
    @test_throws LMDBError LMDB.Environment(joinpath(dir, "definitely_does_not_exist"))
end

mktempdir() do dir
    closed_env = LMDB.Environment(dir) do env
        @test isopen(env)
        env
    end
    @test !isopen(closed_env)

    @test_throws ErrorException LMDB.Environment(dir) do env
        @test isopen(env)
        error("boom")
    end
end

# Finalizing an abandoned write txn must abort it; otherwise the next
# write txn deadlocks on LMDB's exclusive write mutex. We call `finalize`
# directly because on Julia 1.10+ `GC.gc()` may defer finalizers to a
# separate task, so it isn't a reliable trigger from a test.
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        txn = LMDB.Transaction(env)
        @test isopen(txn)
        finalize(txn)
        txn2 = LMDB.Transaction(env)  # deadlocks here if the finalizer didn't abort txn
        try
            dbi = LMDB.Database(txn2)
            LMDB.put!(txn2, dbi, "k", "v")
        finally
            LMDB.commit(txn2)
        end
    finally
        close(env)
    end
end

# Finalizing a cursor must not invalidate its transaction.
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        LMDB.Transaction(env) do txn
            dbi = LMDB.Database(txn)
            cur = LMDB.Cursor(txn, dbi)
            @test isopen(cur)
            finalize(cur)
            LMDB.put!(txn, dbi, "k", "v")
        end
    finally
        close(env)
    end
end

# Transactions close their cursors before ending.
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        txn = LMDB.Transaction(env)
        dbi = LMDB.Database(txn)
        cur = LMDB.Cursor(txn, dbi)
        LMDB.put!(txn, dbi, "k", "v")
        LMDB.commit(txn)
        @test !isopen(txn)
        @test !isopen(cur)
        finalize(cur)
    finally
        close(env)
    end
end

# Work around LMDB's post-transaction cursor-close use-after-free.
mktempdir() do dir
    LMDB.Environment(dir) do env
        txn = LMDB.Transaction(env; flags = LMDB.MDB_RDONLY)
        dbi = LMDB.Database(txn)
        cur = LMDB.Cursor(txn, dbi)
        LMDB.commit(txn)
        @test !isopen(txn)
        @test !isopen(cur)
        close(cur)
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        txn = LMDB.Transaction(env; flags = LMDB.MDB_RDONLY)
        dbi = LMDB.Database(txn)
        cur = LMDB.Cursor(txn, dbi)
        LMDB.abort(txn)
        @test !isopen(txn)
        @test !isopen(cur)
    end
end

# Renewing a cursor transfers cleanup responsibility to the new transaction.
mktempdir() do dir
    LMDB.Environment(dir) do env
        LMDB.Transaction(env) do txn
            dbi = LMDB.Database(txn)
            LMDB.put!(txn, dbi, "k", "v")
        end
        txn1 = LMDB.Transaction(env; flags = LMDB.MDB_RDONLY)
        dbi = LMDB.Database(txn1)
        cur = LMDB.Cursor(txn1, dbi)
        reset(txn1)
        txn2 = LMDB.Transaction(env; flags = LMDB.MDB_RDONLY)
        LMDB.renew(txn2, cur)
        @test LMDB.transaction(cur) === txn2
        LMDB.abort(txn1)
        @test isopen(cur)
        @test LMDB.seek!(cur, String) == "k"
        LMDB.commit(txn2)
        @test !isopen(cur)
    end
end

# LMDB requires child transactions to end before `mdb_env_close`.
mktempdir() do dir
    env = LMDB.Environment(dir)
    txn = LMDB.Transaction(env)
    dbi = LMDB.Database(txn)
    cur = LMDB.Cursor(txn, dbi)
    @test isopen(txn)
    close(env)
    @test !isopen(txn)
    @test !isopen(cur)
    finalize(txn)
end
mktempdir() do dir
    env = LMDB.Environment(dir; mapsize = Csize_t(8) * 1024^3, maxreaders = 42, maxdbs = 4)
    LMDB.Transaction(env) do txn
        LMDB.Database(txn) do dbi
            LMDB.put!(txn, dbi, "k", "v")
        end
    end
    close(env)
end

mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        LMDB.Transaction(env) do txn
            @test LMDB.env(txn) === env
            dbi = LMDB.Database(txn)
            LMDB.Cursor(txn, dbi) do cur
                @test LMDB.transaction(cur) === txn
            end
        end
    finally
        close(env)
    end
end

mktempdir() do dir
    LMDB.Environment(dir) do env
        @test LMDB.reader_check(env) == 0

        txt = LMDB.reader_list(env)
        @test txt isa String
        @test !isempty(txt)

        LMDB.Transaction(env) do txn
            LMDB.Database(txn) do dbi
                LMDB.put!(txn, dbi, "k", "v")
            end
        end
        mktempdir() do dst
            copy(env, dst)
            LMDB.Environment(dst) do env2
                LMDB.Transaction(env2) do txn
                    LMDB.Database(txn) do dbi
                        @test get(txn, dbi, "k", String, nothing) == "v"
                    end
                end
            end
        end
        mktempdir() do dst
            copy(env, dst; compact=true)
            LMDB.Environment(dst) do env2
                LMDB.Transaction(env2) do txn
                    LMDB.Database(txn) do dbi
                        @test get(txn, dbi, "k", String, nothing) == "v"
                    end
                end
            end
        end
    end
end

end
