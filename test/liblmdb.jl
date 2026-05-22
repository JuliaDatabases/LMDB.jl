using LMDB
using Test

@testset "liblmdb" begin

# @checked: status-returning bindings auto-throw an LMDBError on a
# non-zero return.
mktempdir() do dir
    env_ref = Ref{Ptr{LMDB.MDB_env}}(C_NULL)
    LMDB.mdb_env_create(env_ref)
    env = env_ref[]
    try
        # Opening a *file* (not a directory) when MDB_NOSUBDIR isn't
        # set should fail with a non-zero status that @checked turns
        # into an LMDBError.
        f = touch(joinpath(dir, "not_a_dir"))
        @test_throws LMDBError LMDB.mdb_env_open(env,
            f, Cuint(0), LMDB.mode_t(0o644))
    finally
        LMDB.mdb_env_close(env)
    end
end

# unchecked_*: returns the raw Cint without throwing — caller decides.
mktempdir() do dir
    env_ref = Ref{Ptr{LMDB.MDB_env}}(C_NULL)
    LMDB.mdb_env_create(env_ref)
    env = env_ref[]
    try
        LMDB.mdb_env_open(env, dir, Cuint(0), LMDB.mode_t(0o755))

        txn_ref = Ref{Ptr{LMDB.MDB_txn}}(C_NULL)
        LMDB.mdb_txn_begin(env, C_NULL, Cuint(0), txn_ref)
        txn = txn_ref[]

        dbi_ref = Ref{LMDB.MDB_dbi}(0)
        LMDB.mdb_dbi_open(txn, C_NULL, Cuint(0), dbi_ref)
        dbi = dbi_ref[]

        # Look up a key that doesn't exist — unchecked returns
        # MDB_NOTFOUND, no exception.
        key = "missing"
        val_ref = Ref(LMDB.MDBValue())
        ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
        @test ret == LMDB.MDB_NOTFOUND

        # The checked counterpart throws.
        @test_throws LMDBError LMDB.mdb_get(txn, dbi, key, val_ref)

        LMDB.mdb_txn_abort(txn)
    finally
        LMDB.mdb_env_close(env)
    end
end

end  # @testset "liblmdb"
