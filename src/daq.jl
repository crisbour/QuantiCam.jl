# ------------------------------------------------------------------------
# Data Acquisition Functions
# ------------------------------------------------------------------------

# capture data from BTPipeOut
function capture_data(qc::QCBoard, number_of_frames::Int)::PixelVector
  # Captures the requested amount of data (size) from the sensor.
  words = number_of_frames * frame_size(qc)
  packet = 1024
  data = zeros(words,1)

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for i = 1:(words ÷ packet)
    while get_wire_out_value(qc, EP_READY) == 0
      # Wait until the transfer from fifo is ready
      @info "Waiting for EP_READY"
    end
    start_idx = (i-1)*packet+1
    end_idx   = i*packet
    @info "Reading packet $start_idx:$end_idx bytes"
    data[start_idx:end_idx] = read_from_block_pipe_out(qc, FIFO_OUT, packet, packet, packet)
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data
end

function focus_image(qc::QCBoard, number_of_frames::Int)
  # Captures the requested amount of data (size) from the sensor.
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)

  words = number_of_frames * qc.config.frame_size
  packet = 512
  data = fill(UInt16(0), qc.config.frame_size)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for j = 1:number_of_frames
    for i = 1:(qc.config.frame_size ÷ packet)
      while get_wire_out_value(qc, EP_READY) == 0
        # Wait until the transfer from fifo is ready
      end
      start_idx = (i-1)*packet+1
      end_idx   = i*packet
      data[start_idx:end_idx] = read_from_block_pipe_out(qc, FIFO_OUT, packet, packet, packet)
    end
    plotIntensityImage(qc, data, 1)
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data # Return last frame
end

function capture_frame(qc::QCBoard)::Matrix{UInt16}
  # Captures the requested amount of data (size) from the sensor.
  words = qc.config.frame_size
  packet = 256
  data_16bits = fill(UInt16(0), words)

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  # FIXME: The frame is not aligned for a reason or another need to fixup the firmware
  dummy_read = read_from_block_pipe_out(qc, FIFO_OUT, packet, frame_size(qc); el_size=element_size(qc))

  while get_wire_out_value(qc, EP_READY) == 0
    # Wait until the transfer from fifo is ready
  end
  @debug "Reading block packet_size=$packet, frame_size=$(frame_size(qc))"
  frame_data = read_from_block_pipe_out(qc, FIFO_OUT, packet, frame_size(qc); el_size=element_size(qc))

  data_16bits = frame_data

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  # Organize rows read from middle outwards in a matrix format
  unwrap(frame_cast(data_16bits, qc.config.rows, qc.config.cols))
end

# TODO: After raw read, extract header and check it's alligned, all data is parts of a single frame and rows decoded end up in the correct position

# TODO: Define byte_select as a type argument of the QCBoard type, such that we make use of multiple dispatch for this function and make use of the correct data layout for the 2 use cases
function capture_frames(
  qc::QCBoard,
  number_of_frames;
  hdf_channel::Union{Channel{T}, Nothing}=nothing,
  plot_channel::Union{Channel{T}, Nothing}=nothing
)::Vector{Matrix{UInt16}} where T
  # Captures the requested amount of data (size) from the sensor.
  words = number_of_frames * qc.config.frame_size
  packet = 256
  data_16bits::Vector{UInt16} = fill(UInt16(0), words)

  # Write config attributes of the camera to the HDF5 group
  if hdf_channel !== nothing
    put!(hdf_channel, AttributesDict(parse_json(to_json(qc.config))))
  end

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  # FIXME: The frame is not aligned for a reason or another need to fixup the firmware
  for i = 1:number_of_frames
    while get_wire_out_value(qc, EP_READY) == 0
      # Wait until the transfer from fifo is ready
    end
    @debug "Reading block packet_size=$packet, frame_size=$(qc.config.frame_size)"
    frame_data = read_from_block_pipe_out(qc, FIFO_OUT, packet, qc.config.frame_size; el_size=element_size(qc))

    # Send frame data to plotting channel, which will handle this concurently
    if plot_channel !== nothing
      put!(plot_channel, frame_data)
    end
    if hdf_channel !== nothing
      frame_matrix = unwrap(frame_cast(frame_data, qc.config.rows, qc.config.cols))
      put!(hdf_channel, frame_matrix)
    end

    data_16bits[(i-1)*qc.config.frame_size+1:i*qc.config.frame_size] = frame_data
  end

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)

  # Organize rows read from middle outwards in a matrix format and partition each frame
  unwrap(frames_cast(data_16bits, qc.config.rows, qc.config.cols, UInt(number_of_frames)))
end

function capture_raw(qc::QCBoard)::Vector{UInt8}
  # Captures the requested amount of data (size) from the sensor.
  bytes = frame_size(qc) * element_size(qc)
  packet = 256
  data_8bits::Vector{UInt16} = fill(UInt16(0), bytes)

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  while get_wire_out_value(qc, EP_READY) == 0
    # Wait until the transfer from fifo is ready
  end
  @debug "Reading block packet_size=$packet, frame_size=$(qc.config.frame_size)"
  data_8bits = read_from_block_pipe_out(qc, FIFO_OUT, packet, bytes)

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)

  frame_check(data_8bits, qc.config.rows, qc.config.cols; el_size=element_size(qc))
  data_8bits
end

# TODO: Save stream to HDF5 file => Build an async HDF5 collector that each function can stream data to

function stream_G2_Tint(qc,number_of_tint; plotter::Channel, hdf5_collector::Channel)
  packet = 64
  tint_frame_size_bytes = 16*4 # 16 bins for each tint g2 curve. 4 bytes for each bin (32 bits)
  tint_rolling_average = 10 #number of tints taken for averaging (SNR)
  g2 = zeros(tint_rolling_average,16)
  data_8bits = fill(UInt8(0), tint_frame_size_bytes)

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  # put!(plot_channel, G2Plot)
  for i in 1:number_of_tint
    while get_wire_out_value(qc, EP_READY) == 0 end
    data_8bits[1:tint_frame_size_bytes] = read_from_block_pipe_out(qc.fpga, FIFO_OUT, packet, tint_frame_size_bytes)

    data_byte_1 = UInt32(data_8bits[1:4:end])
    data_byte_2 = UInt32(data_8bits[2:4:end])
    data_byte_3 = UInt32(data_8bits[3:4:end])
    data_byte_4 = UInt32(data_8bits[4:4:end])
    data_16bits_1 = map((h,l)-> h<<8 | l, zip(data_byte_2, data_byte_1))
    data_16bits_2 = map((h,l)-> h<<8 | l, zip(data_byte_4, data_byte_3))
    data_32bits   = map((h,l)-> h<16 | l, zip(data_16bits_2, data_16bits_1))
    # WARN: header and data might be the other way around -> Check!
    header = data_32bits[2] & 0xfff
    data_noheader = data_32bits[1]
    g2[2:tint_rolling_average,:] = g2[1:tint_rolling_average-1,:]
    g2[1,:] = reinterpret(Float64, data_noheader)/Float64(2^18)

    # TODO: Plot channel should receive data and enum with type of plotting
    put!(plotter, g2)

    # Save to HDF5 file
    put!(hdf5_collector, g2)
  end

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
end

function stream_G2_components(qc::QCBoard, number_of_tint)
  packet = 1024
  tint_frame_size_bytes = 64*qc.config.rows*17*4 #Monitor channel + 16 bins for each tint per pixel. 4 bytes for each bin (32 bits)
  data_8bits = fill(UInt8(0), tint_frame_size_bytes)
  data_32bits = zeros(64*qc.config.rows*17)

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for _ = 1:number_of_tint
    while get_wire_out_value(qc, EP_READY) == 0 end
    data_8bits[1:tint_frame_size_bytes] = read_from_block_pipe_out(qc, FIFO_OUT, packet, tint_frame_size_bytes)

    data_byte_1 = UInt32(data_8bits[1:4:end])
    data_byte_2 = UInt32(data_8bits[2:4:end])
    data_byte_3 = UInt32(data_8bits[3:4:end])
    data_byte_4 = UInt32(data_8bits[4:4:end])
    data_16bits_1 = map((h,l)-> h<<8 | l, zip(data_byte_2, data_byte_1))
    data_16bits_2 = map((h,l)-> h<<8 | l, zip(data_byte_4, data_byte_3))
    data_32bits = map((h,l)-> h<16 | l, zip(data_16bits_2, data_16bits_1))
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data_32bits
end

function capture_intensity_frames_byte_mode(qc::QCBoard,number_of_frames)
  global last_row
  rows = (last_row+1)*2

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  packet = 1024
  frame_size_bytes = rows*128 #frame size plus header
  capture_frames = 10000
  capture_iterations = number_of_frames ÷ capture_frames
  capture_size = capture_frames*frame_size_bytes


  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  ##Setup transfer
  addr, size, bit = qc.bank[FIFO_OUT]
  for i=1:capture_iterations
    # TODO: Write data to file
    #file_header = capture_frames
    #fileID = fopen(sprintf('frame_data_#d.bin', i),'w')
    #fwrite(fileID,file_header,'UInt16')

    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc,EP_READY)
    end
    data_8bits[1:capture_size] = read_from_block_pipe_out(qc.fpga, addr, packet, capture_size, capture_size)
    transfer_ready = 0
  end

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data_8bits
end

function capture_G2_Tint(qc::QCBoard, number_of_tint)
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)

  packet = 64
  tint_frame_size_bytes = 16*4 # 16 bins for each tint g2 curve. 4 bytes for each bin (32 bits)

  # TODO: Write data to file
  #fclose('all')
  #delete('g2_data.bin')
  #fileID = fopen('g2_data.bin','w')
  #fwrite(fileID,number_of_tint,'UInt16')

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  ##Setup transfer
  addr , size, bit = qc.bank[FIFO_OUT]
  for i = 1:number_of_tint
    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc,EP_READY)
    end
    data_8bits[1:tint_frame_size_bytes] = read_from_block_pipe_out(qc.fpga, addr, packet, tint_frame_size_bytes, tint_frame_size_bytes)
    transfer_ready = 0

    #fwrite(fileID,data_8bits,'UInt16')
  end
  #fclose(fileID)

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data_32bits
end

function capture_pixel_G2_components(qc, number_of_tint; hdf5_collector::Channel)
  packet = 1024
  tint_frame_size_bytes = 64*qc.config.rows*17*4 #Monitor channel + 16 bins for each tint per pixel. 4 bytes for each bin (32 bits)
  tint_readout_iterations = floor(number_of_tint/8)
  tint_number = 8*tint_readout_iterations
  readout_size = 8*tint_frame_size_bytes

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for i = 1:tint_readout_iterations
    while get_wire_out_value(qc, EP_READY) end
    data_8bits[1:readout_size] = read_from_block_pipe_out(qc, FIFO_OUT, packet, readout_size)
    transfer_ready = 0

    put!(hdf5_collector, data_8bits)
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)

  data_8bits
end

