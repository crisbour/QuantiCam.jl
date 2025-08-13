__precompile__()

module QuantiCam

using OpalKelly
using Printf
using Logging
using Random

export QCBoard, init_board!, new_profile!, set_profile!

include("types.jl")
include("constants.jl")
include("utils.jl")
include("bank_operations.jl")
include("setup.jl")
include("daq.jl")
include("hdf5_collector.jl")
include("processing.jl")
#include("plot.jl")

end # module QuantiCam
