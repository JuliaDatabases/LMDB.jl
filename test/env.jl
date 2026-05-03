using LMDB
using Test

@testset "Environment" begin

# Open environment
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

# MapSize must accept values that don't fit in Cuint (#38, PR #37, #40).
big = Csize_t(8) * 1024^3  # 8 GiB
@test (env[:MapSize] = big) == big

# Setting :Flags via setindex! used to fall through to a warning (#24).
@test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
env[:Flags] = LMDB.MDB_NOSYNC
@test isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
unset!(env, LMDB.MDB_NOSYNC)

# Unknown options error instead of silently warning + returning bogus values.
@test_throws ArgumentError env[:Bogus] = 1
@test_throws ArgumentError env[:Bogus]

# Open a DB on the env, then close it.
mktempdir() do dir
    ret = open(env, dir)
    @test ret[1] == 0

    # stat(env) returns the main DB's stats; before any puts, there are
    # no entries and a positive page size.
    s = stat(env)
    @test s isa NamedTuple
    @test s.psize > 0
    @test s.entries == 0

    # Close environment
    close(env)
    @test !isopen(env)

    # do block
    create() do env
        set!(env, LMDB.MDB_NOSYNC)
        open(env, dir)
        @test isopen(env)
    end
end

# High-level Environment(path; ...) constructor.
mktempdir() do dir
    big = Csize_t(8) * 1024^3
    env = Environment(dir; mapsize = big, maxreaders = 42, maxdbs = 4,
                      flags = MDB_NOSYNC | MDB_NOTLS)
    try
        @test isopen(env)
        @test env[:Readers] == 42
        @test info(env).mapsize == big
        @test isflagset(env[:Flags], Cuint(MDB_NOSYNC))
        @test isflagset(env[:Flags], Cuint(MDB_NOTLS))
    finally
        close(env)
    end

    # On failure during open, the Environment ctor closes the partial env.
    @test_throws LMDBError Environment(joinpath(dir, "definitely_does_not_exist"))
end

# Finalizers: an abandoned write txn must be aborted by GC so a later
# write txn doesn't block on LMDB's exclusive write mutex. If the
# finalizer doesn't fire, `start(env)` below would deadlock.
mktempdir() do dir
    env = Environment(dir)
    try
        # Open a write txn and let it become unreachable without commit/abort.
        let txn = start(env)
            @test isopen(txn)
        end
        GC.gc(); GC.gc()
        # If the finalizer aborted the abandoned txn, this succeeds.
        txn2 = start(env)
        try
            dbi = open(txn2)
            LMDB.put!(txn2, dbi, "k", "v")
        finally
            commit(txn2)
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
        start(env) do txn
            dbi = open(txn)
            let cur = LMDB.open(txn, dbi)
                @test isopen(cur)
            end  # cur out of scope
            GC.gc(); GC.gc()
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
        txn = start(env)
        dbi = open(txn)
        cur = LMDB.open(txn, dbi)
        LMDB.put!(txn, dbi, "k", "v")
        commit(txn)             # invalidates write-txn cursors
        @test !isopen(txn)
        cur = nothing           # drop the binding
        GC.gc(); GC.gc()        # finalizer should be a no-op
    finally
        close(env)
    end
end

# Parent refs: env(txn) and transaction(cur) return the actual parents.
mktempdir() do dir
    env = Environment(dir)
    try
        start(env) do txn
            @test LMDB.env(txn) === env
            dbi = open(txn)
            LMDB.open(txn, dbi) do cur
                @test LMDB.transaction(cur) === txn
            end
        end
    finally
        close(env)
    end
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

end  # @testset "Environment"
