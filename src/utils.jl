function check_fpga_exists(fpga::FPGA)::Bool
  # Check FGPA exists
  num_fpga = get_device_count(fpga)
  if num_fpga < 1
    @error "No FPGA is plugged in!"
    return false
  else
    return true
  end
end

macro show_error(expr)
  return quote
    err = $(esc(expr))
    if err isa OpalKelly.ErrorCode && err != OpalKelly.ok_NoError
      file = $(esc(__source__.file))
      line = $(esc(__source__.line))
      @error "ERROR: $err" line=line file=file
    end
  end
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
