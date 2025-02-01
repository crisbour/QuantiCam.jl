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
  ledOut::UInt32=0
  for i=1:8
    if ledArray[i]
      ledOut |= 1 << (i-1)
    end
  end
  @info "Fire up leds..."
  OpalKelly.set_wire_in_value(fpga, 0, ledOut)
  OpalKelly.update_wire_ins(fpga)
  sleep(1)
  finalize(fpga)
  # TODO: Check that fpga is destructed when going out of scope
end
