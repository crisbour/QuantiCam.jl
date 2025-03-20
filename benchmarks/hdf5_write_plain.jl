using BenchmarkTools
using QuantiCam
using HDF5
using Serde
using Dates

# Write to an HDF5 File
function init_file(path::String)
  # Create a new file
  file = h5open(path, "w")
  write_attribute(file, "description", "HDF5 write speed test for QC frames format")
  write_attribute(file, "timestamp", Dates.format(Dates.now(), Dates.ISODateTimeFormat))
  group = create_group(file, "qc_hdf5_benchmark")
  write_attribute(group, "timestamp", Dates.format(Dates.now(), Dates.ISODateTimeFormat))
  write_attribute(group, "description", "Trying to write big N frames of 128x192 QC pixels for 8/16 bit modes")
  qc_config  = deser_json(QuantiCam.QCConfig, "{}")
  attributes_qc_config = parse_json(to_json(qc_config))
  for (name, value) in attributes_qc_config
    write_attribute(group, name, value)
  end
  return file, group
end


function plain_write(::Type{T}, no_frames=1000) where T
  frame = rand(T, 128, 192)
  file, group = init_file("qc_benchmark_plain.h5")

  timestamps = create_dataset(group, "timestamp", typeof(Dates.now()), (no_frames,))
  frames = create_dataset(group, "frames", eltype(frame), (no_frames, size(frame)...))

  println("Testing plain write frame wise for ($no_frames, 128, 192)::$T, incr idx of the frame")
  for idx in 1:no_frames
    timestamps[idx] = Dates.now()
    frames[idx, :, :] = frame
  end
  close(file)
end

function chunked_frame_write(::Type{T}, no_frames=1000) where T
  frame = rand(T, 128, 192)
  file, group = init_file("qc_benchmark_chunked_frame.h5")

  timestamps = create_dataset(group, "timestamp", typeof(Dates.now()), (no_frames,))
  frames = create_dataset(group, "frames", eltype(frame), (no_frames, size(frame)...), chunk=(1, size(frame)...))

  println("Testing chunked write frame wise for ($no_frames, 128, 192)::$T, incr idx of the frame")
  for idx in 1:no_frames
    timestamps[idx] = Dates.now()
    frames[idx, :, :] = frame
  end
  close(file)
end

@btime plain_write(UInt8)
@btime chunked_frame_write(UInt8)


@btime plain_write(UInt16)
@btime chunked_frame_write(UInt16)

# RESULTS:
# Chunking makes a huge difference:
# - Plain:   18.6 seconds
# - Chunked: 881 ms => 21x faster
# TODO: Reducing the size of the elements UInt16 -> UInt8 also halves the time
# => Use the proper size to store into the H5 file instead of generic UInt16
