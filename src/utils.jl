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

element_size(qc::QCBoard)::UInt = if qc.byte_select 1 else 2 end
