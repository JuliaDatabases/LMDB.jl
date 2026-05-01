import LMDB.MDBValue
using LMDB
using Test

    @test LMDB.version()[1] >= v"0.9.15"

    # LMDBError
    ex = LMDBError(Cint(0))
    @test_throws LMDBError throw(ex)
    @test ex.code == 0

    # MDBValue
    val = "abcd" # string
    mdb_val_ref = Ref(MDBValue(val));
    mdb_val = mdb_val_ref[]
    # @test val == unsafe_string(convert(Ptr{UInt8}, mdb_val.data), mdb_val.size)
    @test val == LMDB.mbd_unpack(String, mdb_val_ref)

    val = [1233] # dense array
    T = eltype(val)
    val_size = sizeof(val)
    mdb_val_ref = Ref(MDBValue(val));
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == LMDB.mbd_unpack(Vector{Int}, mdb_val_ref)

    val = [0x0003, 0xff45]
    val_size = sizeof(val)
    T = eltype(val)
    mdb_val_ref = Ref(MDBValue(val));
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == LMDB.mbd_unpack(Vector{UInt16}, mdb_val_ref)

    struct TestType
        i::Int
        j::Char
    end
    val = TestType(1,'a') # struct
    val_size = sizeof(val)
    T = typeof(val)
    @test_throws MethodError MDBValue(val)
    val = [val]
    mdb_val_ref = Ref(MDBValue(val));
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == LMDB.mbd_unpack(Vector{T}, mdb_val_ref)
    @test val[1] == LMDB.mbd_unpack(T, mdb_val_ref)
