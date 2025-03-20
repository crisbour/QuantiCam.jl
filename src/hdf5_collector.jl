using HDF5
using Base.Threads
using Test
using Dates
using Base: close
using Base.Filesystem

# --------------------------------------------------------------------
# HDF5 Types for interoperability
# --------------------------------------------------------------------

struct GroupConfig
  name::String
  size # No Idea what a general size Tuple should be for size
  description::String
end
const AttributesDict = Dict{String, Any}
struct Terminate end

const H5StreamType{T} = Union{AttributesDict, T, GroupConfig, Terminate}

# --------------------------------------------------------------------
# System Configuration
# --------------------------------------------------------------------

# NOTE: HDF5 seems to work out of the box, so ignore the following

#using MPIPreferences
#using Preferences

# Identify system and determine how to set preferences for the mpi and hdf5 libraries

# Use system libraries, make sure these are added to LD_LIBRARY_PATH when using nix
# Method 1:
#MPIPreferences.use_system_binary()
# TODO: Perhaps use libhdf5 defined by Nix
#set_preferences!(HDF5, # Or use UUID: "f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f"
#                 "libhdf5" => ENV["NIX_HDF5_CORE_LIB_PATH"],
#                 "libhdf5_hl" => ENV["NIX_HDF5_HL_LIB_PATH"],
#                 force = true)
## Method 2:
#HDF5.API.set_libraries!(
#  "/usr/lib/x86_64-linux-gnu/hdf5/mpich/libhdf5.so",
#  "/usr/lib/x86_64-linux-gnu/hdf5/mpich/libhdf5_hl.so"
#)
#
## Method 3:
## Generate the "LocalPreferences.toml" from flake.nix and load: ...

# --------------------------------------------------------------------
# HDF5 Collector stream setup
# --------------------------------------------------------------------

# NOTE: Pipeline is defined in steps 1-4 described in comments in the code below

# 1. Construct a collect for a file, give name and define format if necessary, tag with time and description
function hdf5_collector_init(path::String, ::Type{T}; description=Union{String, Nothing}=nothing)::Tuple{Task, Channel{H5StreamType{T}}} where T
  # TODO: benchmark on daq to find out suitable channel size
  # - Unbuffered channel should work best, but is there any concern about blocking due to write to disk?
  # - Probably no, since write first happens to memory and it copies to disk by the DMA

  #channel = Channel{T}(0) # unbuffered channel
  # Add a few buffers to allow for variability between HDF5 writting and frame readout
  # The larger the number of frames, the slower is to write HDF5
  # FIXME: Finf out how to chunk it in order to increase write speed
  channel = Channel{H5StreamType{T}}(1) # SPSC channel

  # Check that file does not exist, but dirpath exists
  @assert !ispath(path) "HDF5 file $path already exists"
  @assert splitext(path)[2] in [".h5", ".hdf", ".hdf5"] "HDF5 file must have extension: .h5, .hdf, .hdf5; got $path"
  if !isdir(dirname(path))
    @warn "Directory $(dirname(path)) does not exist, creating it"
    mkdir(dirname(path))
  end

  @info "Spawning HDF5 collector thread"
  hdf5_task = @spawn hdf5_collector_thread(path, channel; description=description);

  # Close channel if task finishes
  bind(channel, hdf5_task)

  # 2. Produce a MPSC channel with sender side being given back to caller, which can be passed around to any DAQ producer
  @info "Returning channel to caller"
  hdf5_task, channel
end

function hdf5_collector_thread(path::String, channel::Channel{H5StreamType{T}}; description=nothing)::Nothing where T
  # TODO: Decide on HDF5 layout: groups, datasets, etc.
  # 3. The receiver side is sent to a thread running the writer, watching the channel
  group_config::Union{Nothing, GroupConfig} = nothing
  group = nothing
  timestamps = nothing
  frames = nothing
  idx = 0
  h5open(path, "cw") do file
    # Create new HDF5 file and write info for self description
    if description !== nothing
      write_attribute(file, "description", description)
    end
    write_attribute(file, "timestamp", Dates.format(Dates.now(), Dates.ISODateTimeFormat))

    while isopen(channel)
      # Receive data from channel
      # Only read when ready to avoid race condition of close and take!
      rx = try
        take!(channel)
      catch e
        @error "Horrible error catch pattern in Julia, try to use ResultTypes instead"
        return
      end
      @debug "Received data to be put in the HDF5 file: $rx"
      if rx isa GroupConfig
        # Create a new group for the data
        # TODO: Write groups name as DAQ function + date/time
        group_config = rx
        group = create_group(file, group_config.name)
        write_attribute(group, "timestamp", Dates.format(Dates.now(), Dates.ISODateTimeFormat))
        write_attribute(group, "description", group_config.description)
        # FIXME: Convert DateTime to ISO format instead for interop with other languages
        timestamps = create_dataset(group, "timestamp", typeof(Dates.now()), (group_config.size,))
        frames = nothing
        idx = 0
      elseif rx isa AttributesDict
        if group === nothing
          @error "No group defined for attributes"
          continue
        end
        for (name, value) in rx
          write_attribute(group, name, value)
        end
      elseif rx isa T
        if group === nothing
          @error "No group defined for attributes"
          continue
        end

        # Create new dataset if necessary and verify received data matches expected size
        if frames === nothing
          @info "Creating dataset for frames of type: $(eltype(rx)) and size: $((group_config.size, size(rx)...)) in group: $group"
          frames = create_dataset(group, "frames", eltype(rx), (group_config.size, size(rx)...), chunk=(1,size(rx)...))
        end

        # Check data size
        if size(frames) != (group_config.size, size(rx)...)
          @error "Data size mismatch: Expected $(group_config.size) frames of size \
          $(size(frames)[2:3]), but got $(size(rx))"
          continue
        end

        idx += 1
        if idx > group_config.size
          @error "Samples number mismatch: Expected $(group_config.size) frames, but got more"
          continue
        end

        # Write data to file
        timestamps[idx] = Dates.now()
        @debug "Writing frame: $frames"
        frames[idx,:,:] = rx
      elseif rx isa Terminate
        break
      else
        @error "Unknown data type received: $(typeof(rx))"
      end
    end
  end
  # 4. Keep writing data to file until channel is closed (or sender ref count goes to 0), then we can kill the collector thread
end

# --------------------------------------------------------------------
# JLD2 Collector stream setup: Julia standalone alternative to HDF5
# --------------------------------------------------------------------
#using JLD2

# TODO: Implement JLD2 collector as a separate function

# --------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------

@testset "Test HDF5 Collector" begin
  using Base.Threads
  A_stream = collect(reshape(1:400, (2,10,20)))
  hdf5_task, hdf5_channel = hdf5_collector_init("/tmp/test.h5", Matrix{Int}; description="Test hdf5 file")

  # Crate dataset group
  group_config = GroupConfig("test_group", size(A_stream)[1], "Test group for data")
  put!(hdf5_channel, group_config)

  # Write attributes for the group
  @serde @default_value struct TestAttributes
    attr1::Int | 54
    attr2::String | "test string attribute"
    attr3::Float64 | 1.54272
    attr4::Bool | true
    #attr5::Vector{UInt8} | hex2bytes("FFFFFFFF")
  end
  put!(hdf5_channel, parse_json(to_json(deser_json(TestAttributes, "{}"))))

  # Write data to the group
  put!(hdf5_channel, A_stream[1,:,:])
  put!(hdf5_channel, A_stream[2,:,:])

  # FIXME: I'm not sure it's a good idea to rely on user to use correctly the sequence of commands,
  # I.e. instead of using Terminate and leaving an orphan task, there should be a RefCell for channel sender,
  # maybe bind channel also to the master task
  put!(hdf5_channel, Terminate())
  wait(hdf5_task)

  # Tests
  fid = h5open("/tmp/test.h5", "r")
  @test length(HDF5.get_datasets(fid)) == 2
  group = fid["test_group"]
  @test read_attribute(group, "attr1") == 54
  @test read_attribute(group, "attr2") == "test string attribute"
  @test read_attribute(group, "attr3") == 1.54272
  @test read_attribute(group, "attr4") == true
  #@test read_attribute(group, "attr5") == hex2bytes("FFFFFFFF")
  @test read_dataset(group, "frames") == A_stream

  close(fid)

  # Cleanup
  rm("/tmp/test.h5", force=true)
end
