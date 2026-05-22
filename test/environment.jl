@testset "Environment" begin

# Defaults and getindex on a freshly constructed env.
mktempdir() do dir
    env = Environment(dir)
    try
        @test isopen(env)
        @test env[:Readers] == 126
        @test env[:KeySize] == 511
        @test env[:Flags] == 0

        # Manipulate flags via set!/unset! after open.
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        set!(env, LMDB.MDB_NOSYNC)
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        unset!(env, LMDB.MDB_NOSYNC)
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))

        # set!/unset! return env for chaining.
        @test set!(env, LMDB.MDB_NOSYNC) === env
        @test unset!(env, LMDB.MDB_NOSYNC) === env

        # env[:Flags] setindex! used to fall through to a warning (#24).
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        env[:Flags] = LMDB.MDB_NOSYNC
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        unset!(env, LMDB.MDB_NOSYNC)

        # Unknown options error instead of silently warning + returning bogus values.
        @test_throws ArgumentError env[:Bogus] = 1
        @test_throws ArgumentError env[:Bogus]

        # stat(env) returns the main DB's stats; before any puts, there are
        # no entries and a positive page size.
        s = stat(env)
        @test s isa NamedTuple
        @test s.psize > 0
        @test s.entries == 0
    finally
        close(env)
        @test !isopen(env)
    end
end

# High-level Environment(path; ...) constructor.
mktempdir() do dir
    big = Csize_t(8) * 1024^3
    env = Environment(dir; mapsize = big, maxreaders = 42, maxdbs = 4,
                      flags = LMDB.MDB_NOSYNC | LMDB.MDB_NOTLS)
    try
        @test isopen(env)
        @test env[:Readers] == 42
        @test info(env).mapsize == big
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOTLS))
    finally
        close(env)
    end

    # On failure during open, the Environment ctor closes the partial env.
    @test_throws LMDBError Environment(joinpath(dir, "definitely_does_not_exist"))
end

# do-block form: env is closed on the way out, even if the body throws.
mktempdir() do dir
    closed_env = Environment(dir) do env
        @test isopen(env)
        env
    end
    @test !isopen(closed_env)

    @test_throws ErrorException Environment(dir) do env
        @test isopen(env)
        error("boom")
    end
end

# Finalizing an abandoned write txn must abort it; otherwise the next
# write txn deadlocks on LMDB's exclusive write mutex. We call `finalize`
# directly because on Julia 1.10+ `GC.gc()` may defer finalizers to a
# separate task, so it isn't a reliable trigger from a test.
mktempdir() do dir
    env = Environment(dir)
    try
        txn = Transaction(env)
        @test isopen(txn)
        finalize(txn)
        txn2 = Transaction(env)  # deadlocks here if the finalizer didn't abort txn
        try
            dbi = DBI(txn2)
            LMDB.put!(txn2, dbi, "k", "v")
        finally
            LMDB.commit(txn2)
        end
    finally
        close(env)
    end
end

# Cursor finalizer: an abandoned cursor must be cleaned up so its
# parent txn can commit. (LMDB requires cursors on a write txn to be
# closed before commit; for read txns it's safer too.)
mktempdir() do dir
    env = Environment(dir)
    try
        Transaction(env) do txn
            dbi = DBI(txn)
            cur = Cursor(txn, dbi)
            @test isopen(cur)
            finalize(cur)
            # If the finalizer ran, we can still use the txn.
            LMDB.put!(txn, dbi, "k", "v")
        end
    finally
        close(env)
    end
end

# Cursor finalizer is safe even after its parent txn has been
# explicitly committed: write-txn cursors are freed by the txn's
# commit per `lmdb.h`, so `mdb_cursor_close` afterwards would be UB.
# The defensive check in `close(::Cursor)` skips the LMDB call once
# the parent txn handle is gone.
mktempdir() do dir
    env = Environment(dir)
    try
        txn = Transaction(env)
        dbi = DBI(txn)
        cur = Cursor(txn, dbi)
        LMDB.put!(txn, dbi, "k", "v")
        LMDB.commit(txn)        # invalidates write-txn cursors
        @test !isopen(txn)
        finalize(cur)           # finalizer should be a safe no-op
    finally
        close(env)
    end
end

# close(env) must abort any still-open child txns before calling
# `mdb_env_close`; otherwise LMDB corrupts shared state and a later
# env-open in the same process crashes inside `mdb_txn_renew0`. The
# subsequent Environment is the canary.
mktempdir() do dir
    env = Environment(dir)
    txn = Transaction(env)
    @test isopen(txn)
    close(env)                  # would corrupt LMDB state without txn tracking
    @test !isopen(txn)
    finalize(txn)               # finalizer should also be a safe no-op
end
mktempdir() do dir
    env = Environment(dir; mapsize = Csize_t(8) * 1024^3, maxreaders = 42, maxdbs = 4)
    Transaction(env) do txn
        DBI(txn) do dbi
            LMDB.put!(txn, dbi, "k", "v")
        end
    end
    close(env)
end

# Parent refs: env(txn) and transaction(cur) return the actual parents.
mktempdir() do dir
    env = Environment(dir)
    try
        Transaction(env) do txn
            @test LMDB.env(txn) === env
            dbi = DBI(txn)
            Cursor(txn, dbi) do cur
                @test LMDB.transaction(cur) === txn
            end
        end
    finally
        close(env)
    end
end

# reader_check / reader_list / copy
mktempdir() do dir
    Environment(dir) do env
        # Fresh env: no stale readers.
        @test reader_check(env) == 0

        # reader_list always emits a header line listing slot fields.
        txt = reader_list(env)
        @test txt isa String
        @test !isempty(txt)

        # Round-trip a copy.
        Transaction(env) do txn
            DBI(txn) do dbi
                LMDB.put!(txn, dbi, "k", "v")
            end
        end
        mktempdir() do dst
            copy(env, dst)
            Environment(dst) do env2
                Transaction(env2) do txn
                    DBI(txn) do dbi
                        @test LMDB.tryget(txn, dbi, "k", String) == "v"
                    end
                end
            end
        end
        mktempdir() do dst
            copy(env, dst; compact=true)
            Environment(dst) do env2
                Transaction(env2) do txn
                    DBI(txn) do dbi
                        @test LMDB.tryget(txn, dbi, "k", String) == "v"
                    end
                end
            end
        end
    end
end

end
