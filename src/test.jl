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
