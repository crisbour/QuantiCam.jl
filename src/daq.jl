# ------------------------------------------------------------------------
# Data Acquisition Functions
# ------------------------------------------------------------------------

# capture data from BTPipeOut
function capture_data(qc::QCBoard, number_of_frames::Int)::Vector{UInt16}
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

  words = number_of_frames * qc.frame_size
  packet = 512
  data = fill(UInt16(0), qc.frame_size)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for j = 1:number_of_frames
    for i = 1:(qc.frame_size ÷ packet)
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

function capture_TCSPC_frames(qc::QCBoard, number_of_frames)::Vector{UInt16}
  # Captures the requested amount of data (size) from the sensor.
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  words = number_of_frames * qc.frame_size
  packet = 1024
  data_16bits = fill(UInt16(0), words)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)

  for i = 1:number_of_frames
    while get_wire_out_value(qc, EP_READY) == 0
      # Wait until the transfer from fifo is ready
    end
    @info "Reading block packet_size=$packet, frame_size=$(qc.frame_size)"
    data_16bits[(i-1)*qc.frame_size+1:i*qc.frame_size] = read_from_block_pipe_out(qc, FIFO_OUT, packet, qc.frame_size)
  end

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data_16bits
end

function stream_intensity_frames(qc::QCBoard, number_of_frames)
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  words = number_of_frames * qc.frame_size
  packet = 1024
  data_16bits = fill(UInt16(0), qc.frame_size)

  ##Setup transfer
  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  for i = 1:number_of_frames
    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc, EP_READY)
    end
    data_16bits[1:qc.frame_size] = read_from_block_pipe_out(qc, FIFO_OUT, packet, qc.frame_size)
    transfer_ready = 0

    plot_intensity_image(qc, data_16bits, 1)
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
end

# TODO: Save stream to HDF5 file => Build an async HDF5 collector that each function can stream data to
function stream_instensity_frames_byte_mode(qc::QCBoard, number_of_frames)
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)
  packet = 1024
  data_8bits = fill(UInt8(0), qc.frame_size)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  for i = 1:number_of_frames
    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc, EP_READY)
    end
    data_8bits[1:qc.frame_size] = read_from_block_pipe_out(qc, FIFO_OUT, packet, qc.frame_size; el_size=1)
    transfer_ready = 0

    plot_intensity_image_byte_mode(qc, data_8bits, 1)
  end
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
end

function stream_G2_Tint(qc,number_of_tint)
  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)

  packet = 64
  tint_frame_size_bytes = 16*4 # 16 bins for each tint g2 curve. 4 bytes for each bin (32 bits)
  tint_rolling_average = 10 #number of tints taken for averaging (SNR)
  g2 = zeros(tint_rolling_average,16)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  ##Setup transfer
  addr, size, bit = qc.bank[FIFO_OUT]

  for i in 1:number_of_tint
    while transfer_ready == 0
        transfer_ready = get_wire_out_value(qc,EP_READY)
    end
    data_8bits[1:tint_frame_size_bytes] = read_from_block_pipe_out(qc.fpga, addr, packet, tint_frame_size_bytes, tint_frame_size_bytes)
    transfer_ready = 0

    data_byte_1 = UInt32(data_8bits[1:4:end])
    data_byte_2 = UInt32(data_8bits[2:4:end])
    data_byte_3 = UInt32(data_8bits[3:4:end])
    data_byte_4 = UInt32(data_8bits[4:4:end])
    data_16bits_1 = map((h,l)-> h<<8 | l, zip(data_byte_2, data_byte_1))
    data_16bits_2 = map((h,l)-> h<<8 | l, zip(data_byte_4, data_byte_3))
    data_32bits   = map((h,l)-> h<16 | l, zip(data_byte_4, data_byte_3))
    header = (data_32bits>>20) & 0xfff
    data_noheader = data_32bits & ((1<<20) - 1)
    g2[2:tint_rolling_average,:] = g2[1:tint_rolling_average-1,:]
    g2[1,:] = Float64(data_noheader)/Float64(2^18)

    qc.plotG2Tint(g2) #send data to plot without header (20b LSBs)
  end

  activate_trigger_in(qc, TRIGGER_END_CAPTURE)
  data_32bits
end



function stream_G2_components(qc::QCBoard, number_of_tint)
  global last_row
  number_of_rows = (last_row+1)*2

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)

  packet = 1024
  tint_frame_size_bytes = 64*number_of_rows*17*4 #Monitor channel + 16 bins for each tint per pixel. 4 bytes for each bin (32 bits)
  data_8bits = fill(UInt8(0), tint_frame_size_bytes)
  data_32bits = zeros(64*number_of_rows*17)

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  ##Setup transfer
  addr, size, bit = qc.bank[FIFO_OUT]
  for i = 1:number_of_tint
    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc.fpga, qc.bank,EP_READY)
    end
    data_8bits[1:tint_frame_size_bytes] = read_from_block_pipe_out(qc.fpga, addr, packet, frame_size_bytes, frame_size_bytes)
    transfer_ready = 0

    data_byte_1 = UInt32(data_8bits[1:4:end])
    data_byte_2 = UInt32(data_8bits[2:4:end])
    data_byte_3 = UInt32(data_8bits[3:4:end])
    data_byte_4 = UInt32(data_8bits[4:4:end])
    data_16bits_1 = map((h,l)-> h<<8 | l, zip(data_byte_2, data_byte_1))
    data_16bits_2 = map((h,l)-> h<<8 | l, zip(data_byte_4, data_byte_3))
    data_32bits = map((h,l)-> h<16 | l, zip(data_byte_4, data_byte_3))
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

    #fwrite(fileID,data_8bits,'UInt16')
    #fclose(fileID)
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

function capture_pixel_G2_components(qc, number_of_tint)
  global last_row
  number_of_rows = (last_row+1)*2

  activate_trigger_in(qc, PIX_RST)
  activate_trigger_in(qc, FIFO_RST)

  packet = 1024
  tint_frame_size_bytes = 64*number_of_rows*17*4 #Monitor channel + 16 bins for each tint per pixel. 4 bytes for each bin (32 bits)
  tint_readout_iterations = floor(number_of_tint/8)
  tint_number = 8*tint_readout_iterations
  readout_size = 8*tint_frame_size_bytes

  # TODO: Write data to file
  #fclose("all")
  #delete("g2_data.bin")
  #fileID = fopen("g2_pixel_data.bin','w")
  #fwrite(fileID,tint_number,"UInt16")

  activate_trigger_in(qc, START_CAPTURE_TRIGGER)
  transfer_ready = 0

  ##Setup transfer
  addr , size, bit = qc.bank[FIFO_OUT]
  for i = 1:tint_readout_iterations
    while(transfer_ready == 0)
        transfer_ready = get_wire_out_value(qc, EP_READY)
    end
    data_8bits[1:readout_size] = read_from_block_pipe_out(qc.fpga, addr, packet, readout_size, readout_size)
    transfer_ready = 0
    #fwrite(fileID,data_8bits,'UInt16')
  end
  #fclose(fileID)
  activate_trigger_in(qc, TRIGGER_END_CAPTURE)

  data_8bits
end

