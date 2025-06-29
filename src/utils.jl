using Base.Iterators
using ResultTypes

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

# =================================================================================
# Parsing frames
# =================================================================================

# TODO: Replace string error with EvalError or ParseError with the suitable hooks
function frame_cast(raw_frame::PixelVector, rows::UInt, cols::UInt)::Result{Matrix{UInt16}, ErrorException}#::Matrix{UInt16}#
  # Statically allocate a matrix of size qc.rows, qc.cols
  frame = Matrix{UInt16}(undef, rows, cols)
  frame_id = nothing
  mid_idx = rows ÷ 2
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2))
    row_header::RowPairHeader = @try parse_header(collect(row_pair))
    if frame_id === nothing
      frame_id = row_header.frame_id
    end
    if frame_id != row_header.frame_id
      @error "Frame ID mismatch when parsing: Expecting($frame_id), Got($(row_header.frame_id)); Header: $row_header"
      return ErrorResult(Matrix{UInt16}, "Frame ID mismatch when parsing: Expecting($frame_id), Got($(row_header.frame_id)); Header: $row_header")
    end
    if idx != row_header.row_cnt + 1
      @error "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt+1)); Header: $row_header"
      return ErrorResult(Matrix{UInt16}, "Row ID mismatch when parsing: Expecting($idx), Got($(row_header.row_cnt)); Header: $row_header")
    end
    frame[mid_idx - idx + 1, :] = row_pair[1:cols]
    frame[mid_idx + idx, :]     = row_pair[cols+1:2*cols]
  end
  return frame
end


function frames_cast(raw_frames::PixelVector, rows::UInt, cols::UInt, number_of_frames::UInt)::Result{Vector{Matrix{UInt16}}, ErrorException}#::Vector{Matrix{UInt16}} #
  frames::Vector{Matrix{UInt16}} = []
  for raw_frame in partition(raw_frames, rows*cols)
    new_frame = @try frame_cast(collect(raw_frame), rows, cols)
    push!(frames, new_frame)
  end
  if length(frames) != number_of_frames
    @error "Number of frames parsed: $(length(frames)) != Number of frames expected: $number_of_frames"
    return ErrorResult(Vector{Matrix{UInt16}}, "Number of frames parsed: $(length(frames)) != Number of frames expected: $number_of_frames")
  end
  return frames
end

function frame_check(raw_frame::PixelVector, rows::UInt, cols::UInt; el_size=1)
  # Statically allocate a matrix of size qc.rows, qc.cols
  frame_id = nothing
  # Parsing 2 sibling columns at a time, each with elements size = {1, 2} bytes based on byte_select
  for (idx, row_pair) in enumerate(partition(raw_frame, cols*2))
    row_header::RowPairHeader = @try parse_header(collect(row_pair))
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

# =================================================================================
# Inspection functions
# =================================================================================

# WARN: This might be quite inefficient to reshape the bytes in row_pairs, then extract only 4 bytes per row_pair
# -> Instead do a stripe indexing to extract the header
# -> This could be the other reason that the hdf5_channel is backpressuring the readout
function extract_headers(raw_frame::PixelVector, rows::UInt, cols::UInt)::Vector{Vector{UInt8}}
  map(row_pair -> extract_header(row_pair) , partition_row_pairs(raw_frame, rows, cols))
end

function partition_row_pairs(raw_frame::PixelVector, rows::UInt, cols::UInt)::Vector{Vector{UInt16}}
  el_size = if eltype(raw_frame) isa UInt8
    1
  elseif eltype(raw_frame) isa UInt16
    2
  else
    @error "Unsupoorted element type for: $(typeof(raw_frame))"
  end
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

# =================================================================================
# ErrorLogger readout
# =================================================================================
function read_errors(qc::QCBoard)
  # Read the errors from the FPGA
  error_ready = get_wire_out_value(qc, ERROR_READY)
  if error_ready == 0
    #@info"No errors found in the FPGA"
    return
  end
  errors = UInt8.(QuantiCam.read_from_pipe_out(qc, QuantiCam.ERROR_FIFO, UInt64(32);el_size=UInt64(1)))
  # Convert each element for `error` to type QuantiCamError
  errors_casted = map(error -> QuantiCamError(error), errors)
  for error_bundle in partition(errors_casted, 4) # Partition the errors into 4 byte chunks
      error_bundle = collect(error_bundle) # Convert to Vector for easier manipulation
      while !isempty(error_bundle) && error_bundle[end] == NO_ERROR
        pop!(error_bundle) # Remove the last NO_ERROR element
      end
      # NOTE: ERROR_READOUT_FIFO_FULL is not an error, but a signal that the FIFO is full
      # and it's useful to see alongside the other errors
      if !isempty(error_bundle) && error_bundle[1] != ERROR_READOUT_FIFO_FULL
        @warn "Error found in the FPGA: $(error_bundle)"
      end
  end
end


# =================================================================================
# Misc, functions ported from MATLAB that shouldn't be needed
# or not sure what they are useful for
# =================================================================================

# FIXME: This shouldn't be necessary, but the functionality is provided here in case a fixup is not developed for the random frame shifted
#=
function check_frame_stream(qc::QCBoard, data::Vector{Matrix{T}})::Vector{Matrix{T}} where T <: Union{UInt8, UInt16}
  pixels = frame_size(qc)

  #TODO: read from HDF5 file or channel
  data_read = read(channel)

  number_of_frames = data_read.number_of_frames
  data = data_read.data

  #look for start of the first complete frame (first transfer will probably be a
  #partial frame which will skew all the other frames by a certain number of
  #pixels
  for index = 1:pixels
      if(data(index) == 0 && data(index+1) == 0 && data(index+2) == 0 && data(index + pixels - 256) == 0 && data(index + pixels - 255) == 95 && data(index + pixels - 254) == 0)
          start_index = index+1;
          break
      end
  end

  frame_data = data(start_index:end)
  remaining_frames = floor(size(frame_data,1)/pixels)

  frame = uint8(frame_data((i-1)*pixels+1:i*pixels))
end
=#
