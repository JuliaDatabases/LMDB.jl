@testset "Threads" begin

# Begin read-only and write transactions in one environment from several
# threads at once. A child process gives the test threads however the suite
# itself was started.
script = """
using LMDB
mktempdir() do dir
    env = LMDB.Environment(dir; mapsize = 1 << 26,
                           flags = LMDB.MDB_NOSYNC | LMDB.MDB_NOTLS)
    try
        @sync for flags in (LMDB.MDB_RDONLY, LMDB.MDB_RDONLY, LMDB.MDB_RDONLY, 0)
            Threads.@spawn for _ in 1:50_000
                LMDB.Transaction(Returns(nothing), env; flags)
            end
        end
    finally
        close(env)
    end
end
"""
cmd = `$(Base.julia_cmd()) --startup-file=no --threads=4 --project=$(Base.active_project()) -e $script`
@test success(pipeline(cmd; stderr))

end
