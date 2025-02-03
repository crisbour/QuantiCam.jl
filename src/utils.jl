using Base.Iterators

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

element_size(qc::QCBoard)::UInt = if qc.byte_select==1 1 else 2 end

# --------------------------------------------------------------------------------
# Parsing frames
# --------------------------------------------------------------------------------

# FIXME: Is there a way to define a supertype for this instead of runtime matching?
const PixelVector = Union{Vector{UInt16}, Vector{UInt8}}

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
      @warn "Frame ID mismatch when parsing; Expecting($frame_id), Got($(row_header.frame_id))"
    end
    if idx != row_header.row_cnt + 1
      @warn "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt))"
    end
    frame[mid_idx - idx + 1, :] = row_pair[1:cols]
    frame[mid_idx + idx, :]     = row_pair[cols+1:2*cols]
  end
  frame
end

function frame_check(raw_frame::PixelVector, rows::UInt, cols::UInt; el_size=1)
  # Statically allocate a matrix of size qc.rows, qc.cols
  frame_id = nothing
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2*el_size))
    row_header::RowPairHeader = parse_header(collect(row_pair))
    if frame_id === nothing
      frame_id = row_header.frame_id
    end
    if frame_id != row_header.frame_id
      @warn "Frame ID mismatch when parsing: Expecting($frame_id), Got($(row_header.frame_id))"
    end
    if idx != row_header.row_cnt + 1
      @warn "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt))"
    end
  end
end
