using BenchmarkTools
using QuantiCam

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

function extract_headers_stripe(raw_frame::PixelVector, rows::UInt, cols::UInt)::Vector{Vector{UInt8}}
  map(row_pair -> extract_header(row_pair) , partition_row_pairs(raw_frame, rows, cols))
end
