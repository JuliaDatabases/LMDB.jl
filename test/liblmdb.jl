reader_list_stop(::Ptr{Cchar}, ::Ptr{Cvoid})::Cint = Cint(1)

@testset "C interface" begin

# Status-returning bindings throw on errors.
mktempdir() do dir
    env_ref = Ref{Ptr{LMDB.MDB_env}}(C_NULL)
    LMDB.mdb_env_create(env_ref)
    env = env_ref[]
    try
        f = touch(joinpath(dir, "not_a_dir"))
        @test_throws LMDBError LMDB.mdb_env_open(env,
            f, Cuint(0), LMDB.mode_t(0o644))
    finally
        LMDB.mdb_env_close(env)
    end
end

# Unchecked bindings expose the raw status.
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

        key = "missing"
        val_ref = Ref(LMDB.MDBValue())
        ret = LMDB.unchecked_mdb_get(txn, dbi, key, val_ref)
        @test ret == LMDB.MDB_NOTFOUND

        @test_throws LMDBError LMDB.mdb_get(txn, dbi, key, val_ref)

        LMDB.mdb_txn_abort(txn)
    finally
        LMDB.mdb_env_close(env)
    end
end

# `mdb_reader_list` uses negative-error/nonnegative-success semantics.
mktempdir() do dir
    LMDB.Environment(dir) do env
        cb = @cfunction(reader_list_stop, Cint, (Ptr{Cchar}, Ptr{Cvoid}))
        @test LMDB.mdb_reader_list(env, cb, C_NULL) == 1
        @test LMDB.unchecked_mdb_reader_list(env, cb, C_NULL) == 1
    end
end

end
