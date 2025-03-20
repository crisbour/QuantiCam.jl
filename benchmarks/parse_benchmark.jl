using BenchmarkTools
using Base.Iterators
using QuantiCam


const PixelVector = Union{Vector{UInt16}, Vector{UInt8}}

struct RowPairHeader
  marker::UInt8
  frame_id::UInt8
  row_cnt::UInt8
end

# The header is written in big endian
function parse_header(row_pair::PixelVector)::RowPairHeader
  # Header decoding in little endian:
  # |31    24|23    16|15       8|7      0|
  # | Marker | Frame  | Reserved | Row    |
  # But data is streamed in big endian (network fashion)
  header_bytes = extract_header(row_pair)
  #@assert header_bytes[2] == 0 "Expected the reserved byte in the headr to always be 0"
  if header_bytes[2] != 0
    # No error to be thrown in benchmark
  end
  RowPairHeader(header_bytes[4], header_bytes[3], header_bytes[1])
end

function extract_header(row_pair::Vector{UInt16})::Vector{UInt8}
  reinterpret(UInt8, row_pair[1:2])
end

function extract_header(row_pair::Vector{UInt8})::Vector{UInt8}
  row_pair[1:4]
end

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
      # No error to be thrown in benchmark
    end
    if idx != row_header.row_cnt + 1
      # No error to be thrown in benchmark
    end
    frame[mid_idx - idx + 1, :] = row_pair[1:cols]
    frame[mid_idx + idx, :]     = row_pair[cols+1:2*cols]
  end
  frame
end

function cast_frames(raw_frames::Vector{T}, number_of_frames=1000; rows=192, cols=128)::Vector{Matrix{T}} where T <: Union{UInt8, UInt16}
  frames::Vector{Matrix{T}} = []
  for raw_frame in partition(raw_frames, rows*cols)
    new_frame = frame_cast(collect(raw_frame), UInt(rows), UInt(cols))
    push!(frames, new_frame)
  end
  if length(frames) != number_of_frames
    @error "Number of frames parsed: $(length(frames)) != Number of frames expected: $number_of_frames"
  end
  frames
end


function rand_valid_frame(::Type{T}, rows=192, cols=128)::Vector{T} where T <: Union{UInt8, UInt16}
  frame = rand(T, rows*cols)
  frame_id = 0x01
  for idx in 1:rows ÷ 2
    frame[(idx-1)*2*cols+1:(idx-1)*2*cols+4] .= [UInt8(idx-1), 0x00, frame_id, 0x80]
  end
  frame
end

function duplicate_frame(raw_frame::PixelVector, n::Int)::PixelVector
    return vcat([raw_frame for _ in 1:n]...)
end

@info "# Benchmarking frame casting for UInt8 with 1000 frames"
@info "No checks"
@btime cast_frames(data, 1000) setup=(data=rand(UInt8, 128*192*1000))
@info "Checks with valid frame"
@btime QuantiCam.frames_cast(data, UInt(192), UInt(128), UInt(1000)) setup=(data=duplicate_frame(rand_valid_frame(UInt8),1000))
@info "Checks with invalid frame"
@btime QuantiCam.frames_cast(data, UInt(192), UInt(128), UInt(1000)) setup=(data=duplicate_frame(rand(UInt8, 192*128),1000))

@info "Benchmarking frame casting for UInt16 with 1000 frames"
@info "No checks"
@btime cast_frames(data, 1000) setup=(data=rand(UInt16, 128*192*1000))
@info "Checks with valid frame"
@btime QuantiCam.frames_cast(data, UInt(192), UInt(128), UInt(1000)) setup=(data=duplicate_frame(rand_valid_frame(UInt16),1000))
@info "Checks with invalid frame"
@btime QuantiCam.frames_cast(data, UInt(192), UInt(128), UInt(1000)) setup=(data=duplicate_frame(rand(UInt8, 192*128),1000))

# ========= Benchmark Results =========
# 1000 frames casting is really quite fast
# UInt8:
#   1. 38ms no checks // Probably some overhead for first loading BenchmarkTools
#   2. 33ms checks with error messages but no error handling
#   3. 56us checks with invalid frame, effectively returns as soons as a missmatch is seen
# UInt16:
#   1. 41ms no checks
#   2. 41ms checks with error messages but no error handling
#   3. 50us checks with invalid frame, effectively returns as soons as a missmatch is seen
