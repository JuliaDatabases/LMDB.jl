@testset "Environment" begin

# Defaults and getindex on a freshly constructed env.
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        @test isopen(env)
        @test env[:Readers] == 126
        @test env[:KeySize] == 511
        @test env[:Flags] == 0

        # Manipulate flags via LMDB.set!/LMDB.unset! after open.
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.set!(env, LMDB.MDB_NOSYNC)
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.unset!(env, LMDB.MDB_NOSYNC)
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))

        # LMDB.set!/LMDB.unset! return env for chaining.
        @test LMDB.set!(env, LMDB.MDB_NOSYNC) === env
        @test LMDB.unset!(env, LMDB.MDB_NOSYNC) === env

        # env[:Flags] setindex! used to fall through to a warning (#24).
        @test !LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        env[:Flags] = LMDB.MDB_NOSYNC
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        LMDB.unset!(env, LMDB.MDB_NOSYNC)

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

# High-level LMDB.Environment(path; ...) constructor.
mktempdir() do dir
    big = Csize_t(8) * 1024^3
    env = LMDB.Environment(dir; mapsize = big, maxreaders = 42, maxdbs = 4,
                      flags = LMDB.MDB_NOSYNC | LMDB.MDB_NOTLS)
    try
        @test isopen(env)
        @test env[:Readers] == 42
        @test LMDB.info(env).mapsize == big
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
        @test LMDB.isflagset(env[:Flags], Cuint(LMDB.MDB_NOTLS))
    finally
        close(env)
    end

    # On failure during open, the LMDB.Environment ctor closes the partial env.
    @test_throws LMDBError LMDB.Environment(joinpath(dir, "definitely_does_not_exist"))
end

# do-block form: env is closed on the way out, even if the body throws.
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

# LMDB.Cursor finalizer: an abandoned cursor must be cleaned up so its
# parent txn can commit. (LMDB requires cursors on a write txn to be
# closed before commit; for read txns it's safer too.)
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        LMDB.Transaction(env) do txn
            dbi = LMDB.Database(txn)
            cur = LMDB.Cursor(txn, dbi)
            @test isopen(cur)
            finalize(cur)
            # If the finalizer ran, we can still use the txn.
            LMDB.put!(txn, dbi, "k", "v")
        end
    finally
        close(env)
    end
end

# LMDB.Cursor finalizer is safe even after its parent txn has been
# explicitly committed: write-txn cursors are freed by the txn's
# commit per `lmdb.h`, so `mdb_cursor_close` afterwards would be UB.
# The defensive check in `close(::LMDB.Cursor)` skips the LMDB call once
# the parent txn handle is gone.
mktempdir() do dir
    env = LMDB.Environment(dir)
    try
        txn = LMDB.Transaction(env)
        dbi = LMDB.Database(txn)
        cur = LMDB.Cursor(txn, dbi)
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
# subsequent LMDB.Environment is the canary.
mktempdir() do dir
    env = LMDB.Environment(dir)
    txn = LMDB.Transaction(env)
    @test isopen(txn)
    close(env)                  # would corrupt LMDB state without txn tracking
    @test !isopen(txn)
    finalize(txn)               # finalizer should also be a safe no-op
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

# Parent refs: env(txn) and transaction(cur) return the actual parents.
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

# LMDB.reader_check / LMDB.reader_list / copy
mktempdir() do dir
    LMDB.Environment(dir) do env
        # Fresh env: no stale readers.
        @test LMDB.reader_check(env) == 0

        # LMDB.reader_list always emits a header line listing slot fields.
        txt = LMDB.reader_list(env)
        @test txt isa String
        @test !isempty(txt)

        # Round-trip a copy.
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
