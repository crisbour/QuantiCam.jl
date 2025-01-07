module QuantiCam

using OpalKelly
using Printf
using Logging
using Random
using Test

export QCBoard, init_board!

include("types.jl")
include("constants.jl")
include("utils.jl")
include("bank_operations.jl")
include("setup.jl")
include("daq.jl")
#include("processing.jl")
#include("plot.jl")
include("test.jl")

end # module QuantiCam
