using Base.Iterators

export element_size

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

element_size(qc::QCBoard)::UInt = if qc.config.byte_select==1 1 else 2 end

# --------------------------------------------------------------------------------
# Parsing frames
# --------------------------------------------------------------------------------

function frame_cast(raw_frame::PixelVector, rows::UInt, cols::UInt)::Matrix{UInt16}
  # Statically allocate a matrix of size qc.rows, qc.cols
  frame = Matrix{UInt16}(undef, rows, cols)
  frame_id = nothing
  mid_idx = rows ÷ 2
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2))
    row_header::RowPairHeader = parse_header(collect(row_pair))
    if frame_id === nothing
      frame_id = row_header.frame_id
    end
    if frame_id != row_header.frame_id
      @warn "Frame ID mismatch when parsing: Expecting($frame_id), Got($(row_header.frame_id)); Header: $row_header"
    end
    if idx != row_header.row_cnt + 1
      @warn "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt)); Header: $row_header"
    end
    frame[mid_idx - idx + 1, :] = row_pair[1:cols]
    frame[mid_idx + idx, :]     = row_pair[cols+1:2*cols]
  end
  frame
end

function extract_headers(raw_frame::PixelVector, rows::UInt, cols::UInt)::Vector{Vector{UInt8}}
  map(row_pair -> extract_header(row_pair) , partition_row_pairs(raw_frame, rows, cols))
end

function partition_row_pairs(raw_frame::PixelVector, rows::UInt, cols::UInt)::Vector{Vector{UInt16}}
  frame = Vector{Vector{UInt16}}(undef, rows ÷ 2)
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2))
    frame[idx] = row_pair
  end
  frame
end

function partition_row_pairs(raw_frame::Vector{UInt8}, rows::UInt, cols::UInt; el_size=1)::Vector{Vector{UInt8}}
  frame = Vector{Vector{UInt8}}(undef, rows ÷ 2)
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2*el_size))
    frame[idx] = row_pair
  end
  frame
end

function frames_cast(raw_frames::PixelVector, rows::UInt, cols::UInt, number_of_frames::UInt)::Vector{Matrix{UInt16}}
  frames::Vector{Matrix{UInt16}} = []
  for raw_frame in partition(raw_frames, rows*cols)
    new_frame = frame_cast(raw_frame, rows, cols)
    push!(frames, new_frame)
  end
  frames
end

function frame_check(raw_frame::PixelVector, rows::UInt, cols::UInt; el_size=1)
  # Statically allocate a matrix of size qc.rows, qc.cols
  frame_id = nothing
  # Parsing 2 sibling columns at a time, each with elements size = {1, 2} bytes based on byte_select
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2))
    row_header::RowPairHeader = parse_header(collect(row_pair))
    if frame_id === nothing
      frame_id = row_header.frame_id
    end
    if frame_id != row_header.frame_id
      @warn "Frame ID mismatch when parsing: Expecting($frame_id), Got($(row_header.frame_id)); Header: $row_header"
    end
    if idx != row_header.row_cnt + 1
      @warn "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt)); Header: $row_header for parition(frame, $(cols*2*el_size))"
    end
  end
end
