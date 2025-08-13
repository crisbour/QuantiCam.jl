using Test
using QuantiCam
using OpalKelly
using Serde
using HDF5
using Base: close

@testset "Check the FrontPanel API works as expected" begin
    @test get_api_version_major() == 5
    @test get_api_version_minor() == 2
end

@testset "Test FPGA construction" begin
    # Define empty bitfile
    fpga = FPGA("")
    OpalKelly.getlibrary(fpga)
    @test OpalKelly.get_device_count(fpga) >= 0
end

function leds_test()
    bitfile = joinpath(@__DIR__, "../hw/First.bit")
    fpga = FPGA(bitfile)
    @info "FPGA init..."
    OpalKelly.init_board!(fpga)
    ledArray = bitrand(8)
    ledOut::UInt32 = 0
    for i = 1:8
        if ledArray[i]
            ledOut |= 1 << (i - 1)
        end
    end
    @info "Fire up leds..."
    OpalKelly.set_wire_in_value(fpga, 0, ledOut)
    OpalKelly.update_wire_ins(fpga)
    sleep(1)
    finalize(fpga)
    # TODO: Check that fpga is destructed when going out of scope
end

# --------------------------------------------------------------------
# HDF5 Collector Tests
# --------------------------------------------------------------------

@testset "Test HDF5 Collector" begin
    using Base.Threads
    A_stream = collect(reshape(1:400, (2, 10, 20)))
    path = tempname() * ".h5"
    hdf5_task, hdf5_channel =
        hdf5_collector_init(path, Matrix{Int}; description = "Test hdf5 file")

    # Crate dataset group
    group_config = GroupConfig("test_group", size(A_stream)[1], "Test group for data")
    put!(hdf5_channel, group_config)

    # Write attributes for the group
    @serde @default_value struct TestAttributes
        attr1::Int     | 54
        attr2::String  | "test string attribute"
        attr3::Float64 | 1.54272
        attr4::Bool    | true
        #attr5::Vector{UInt8} | hex2bytes("FFFFFFFF")
    end
    put!(hdf5_channel, parse_json(to_json(deser_json(TestAttributes, "{}"))))

    # Write data to the group
    put!(hdf5_channel, A_stream[1, :, :])
    put!(hdf5_channel, A_stream[2, :, :])

    # FIXME: I'm not sure it's a good idea to rely on user to use correctly the sequence of commands,
    # I.e. instead of using Terminate and leaving an orphan task, there should be a RefCell for channel sender,
    # maybe bind channel also to the master task
    put!(hdf5_channel, QuantiCam.Terminate())
    wait(hdf5_task)

    # Tests
    fid = h5open(path, "r")
    @test length(HDF5.get_datasets(fid)) == 3
    group = fid["test_group"]
    @test read_attribute(group, "attr1") == 54
    @test read_attribute(group, "attr2") == "test string attribute"
    @test read_attribute(group, "attr3") == 1.54272
    @test read_attribute(group, "attr4") == true
    #@test read_attribute(group, "attr5") == hex2bytes("FFFFFFFF")
    @test read_dataset(group, "frames") == A_stream

    close(fid)

    # Cleanup
    rm(path, force = true)
end
