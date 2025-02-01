using OpalKelly

# set voltages
function set_voltage(qc::QCBoard, voltage_name::BankEnum, voltage_value::Real)
  voltage_set = nothing
  if voltage_name == VBD
    qc.VBD = voltage_value
    if voltage_value > 16
      voltage_value = 16
      voltage_set = UInt16(floor(voltage_value * (1000 / 4.95)))
    else
      voltage_set = UInt16(floor(voltage_value * (1000 / 4.95)))
    end
  elseif voltage_name == VEB
    qc.VEB = voltage_value
    if voltage_value > 1.2
      voltage_value = 1.2
      voltage_set = UInt16(floor(voltage_value * (1000 / 2)))
    else
      voltage_set = UInt16(floor(voltage_value * (1000 / 2)))
    end
  elseif voltage_name == VQ
    qc.VQ = voltage_value
    if voltage_value > 1.5
      voltage_value = 1.5
      voltage_set = UInt16(floor(voltage_value * (1000)))
    else
      voltage_set = UInt16(floor(voltage_value * (1000)))
    end
  elseif voltage_name == VNBL
    qc.VNBL = voltage_value
    if voltage_value > 1.2
      voltage_value = 1.2
      voltage_set = UInt16(floor(voltage_value * (850 / 2)))
    else
      voltage_set = UInt16(floor(voltage_value * (850 / 2)))
    end
  else
    # Conversion for VHV DAC and other DACs
    @warn "Voltage name unrecognised"
    return
  end
  # Wire In
  set_wire_in_value(qc, voltage_name, voltage_set)
  # Prog DAC
  prog_DAC(qc, PROGSETDAC)
  voltage_set
end

update_wire_ins(qc::QCBoard) = @show_error OpalKelly.update_wire_ins(qc.fpga)
update_wire_outs(qc::QCBoard) = @show_error OpalKelly.update_wire_outs(qc.fpga)

"""
Read data in blocks of element size
NOTE: Element is constrained at the moment for efficiency, but can be extended if needed
...
Arguments
- `qc::QCBoard`: The QuantiCam Board handler
- `pipename::BankEnum`: The pipe enum definition of the address we want to address
- `blksize::Integer`: Size of the block used for reading out the FIFO in bursts
- `bsize::Integer`: Elements to read (2 bytes per element)
- `psize::Union{Nothinh,Integer}`: Packet size for subdivided reads
- `el_size::UInt`: Size of one element in bytes = {1,2}
...
"""
function read_from_block_pipe_out(qc::QCBoard, pipename::BankEnum, blksize::Integer, frame_size::Integer; psize::Union{Nothing,UInt}=nothing, el_size=2)::Vector{UInt16}
  @assert el_size == 1 || el_size == 2 "Element size not supported"
  data_8bits::Vector{UInt8} = fill(UInt8(0), frame_size*el_size)
  # Check that bank exists
  if !haskey(qc.bank, pipename)
    @error "No pipe by the name $pipename exists"
  else
    (addr, size, bit) = convert(Tuple, qc.bank[pipename])
    # Read {1,2} bytes per element
    data_8bits = OKExtended.read_from_block_pipe_out(qc.fpga, addr, blksize, frame_size*el_size)
  end

  # Parse bytes in element size vector
  if el_size == 2
    data_8bits_high = UInt16.(data_8bits[2:2:end])
    data_8bits_low = UInt16.(data_8bits[1:2:end])
    # Note `map` needs an anonymous function to recognise the argument as tuple
    map(((h, l),) -> h << 8 | l, zip(data_8bits_high, data_8bits_low))
  else
    data_8bits
  end

end

# WARN: Do we need this? It's not used anywhere
function read_from_pipe_out(qc::QCBoard, pipename::BankEnum, blksize::UInt; el_size::UInt=1)::Vector{UInt16}
  # Check bank index was set
  @assert el_size == 1 || el_size == 2 "Element size not supported"

  if !haskey(qc.bank, pipename)
    @error "No pipe by the name $pipename exists"
  else
    (addr, size, bit) = convert(Tuple, qc.bank[pipename])
    data_8bits = OKExtended.read_from_pipe_out(qc.fpga, addr, blksize)
    #pipevalue = OKExtended.read_from_pipe_out(qc.fpga, addr, blocksize*4, blocksize*4)
  end

  # Parse bytes in element size vector
  if el_size == 2
    data_8bits_high = UInt16.(data_8bits[2:2:end])
    data_8bits_low = UInt16.(data_8bits[1:2:end])
    # Note `map` needs an anonymous function to recognise the argument as tuple
    map(((h, l),) -> h << 8 | l, zip(data_8bits_high, data_8bits_low))
  else
    data_8bits
  end
end

function prog_DAC(qc::QCBoard, ProgResetDACName::BankEnum)
  # Reset trigger for DACs
  activate_trigger_in(qc, ProgResetDACName)
end

function ramp_DAC(qc::QCBoard, wirename::BankEnum, returnwirename::BankEnum, finalvalue, pausetime, abs_step)
  # Increment or Decrement DAC voltages with a pause on each step

  # Get current value
  @show_error update_wire_outs(qc)
  currentvalue = get_wire_out_value(qc, returnwirename)

  if (currentvalue > finalvalue)
    # Decrementing
    step = -abs_step
  else
    # Incrementing
    step = abs_step
  end

  # Loop to get to final value
  for voltage = currentvalue:step:finalvalue
    set_wire_in_value(qc, wirename, voltage)
    update_wire_ins(qc)

    prog_DAC(qc, PROGSETDAC)
    VHV_Ret = get_wire_out_value(qc, returnwirename)
    sleep(pausetime)
  end
end

function reset_DAC(qc::QCBoard, ProgResetDACName::BankEnum)
  # Reset trigger for DACs
  activate_trigger_in(qc, ProgResetDACName)
  update_wire_ins(qc)
  update_wire_outs(qc)
end

function activate_trigger_in(qc::QCBoard, wirename::BankEnum)
  # Toggle trigger
  if !haskey(qc.bank, wirename)
    # Check bank index was set
    @error "No wire by the name $wirename exists"
  else
    (addr, size, bit) = convert(Tuple, qc.bank[wirename])
    # Trigger bit zero for programme / bit one for reset
    @show_error OpalKelly.activate_trigger_in(qc.fpga, addr, bit)
  end
end

function is_triggered(qc::QCBoard, trigname)
  #UNTITLED2 Summary of this function goes here
  #   Detailed explanation goes here
  if !haskey(qc.bank, trigname)
    # Check bank index was set
    @error "No Trigger by the name $trigname exists"
  else
    (addr, size, bit) = convert(Tuple, qc.bank[trigname])
    sz = 2^(size) - 1
    mask = UInt16(sz << bit)

    update_trigger_outs(qc)
    trig = is_triggered(qc.fpga, addr, mask)
  end
  trig
end

function set_wire_in_value(qc::QCBoard, wirename::BankEnum, data::Unsigned)
  # Parse register bank to get addr, size and starting bit from the bank
  # Get data from that wireout and pass back
  if !haskey(qc.bank, wirename)
    # Check bank index was set
    @error "No wire by the name $wirename exists"
  else
    # If setting a data value to a bit not at zero then need to parse it
    # bit by bit.
    (addr, size, bit) = convert(Tuple, qc.bank[wirename])
    sz = 2^(size) - 1
    mask = UInt32(sz << bit)
    d = data << bit
    @show_error OpalKelly.set_wire_in_value(qc.fpga, addr, d, mask)
    update_wire_ins(qc)
  end
end

function get_wire_out_value(qc::QCBoard, wirename::BankEnum)
  # Parse register bank to get addr, size and starting bit from the bank
  # Get data from that wireout and pass back
  # Check bank index was set
  data = 0
  if !haskey(qc.bank, wirename)
    # Check bank index was set
    @error "No wire by the name $wirename exists"
  else
    update_wire_outs(qc)

    (addr, size, bit) = convert(Tuple, qc.bank[wirename])
    readvalue = OpalKelly.get_wire_out_value(qc.fpga, addr)
    mask = UInt32(2^size - 1)
    data_shift = readvalue >> bit
    data = data_shift & mask

    # Write to log
    @debug "Wireout $wirename is value $data"
  end
  data
end

# --------------------------------------------------------------------------------
# Utils
# --------------------------------------------------------------------------------

function flatten(largeArray::Array{T,2})::Array{T,1} where {T}
  # Flatten data array
  vcat(largeArray...)
end
