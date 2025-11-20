__precompile__()

module QuantiCam

using OpalKelly
using Printf
using Logging
using Random
using Requires
using Statistics

export QCBoard, init_board!, new_config!, set_config!, change_config!

include("types.jl")
include("constants.jl")
include("utils.jl")
include("bank_operations.jl")
include("setup.jl")
include("daq.jl")
include("hdf5_collector.jl")
include("processing.jl")
#include("plot.jl")
function __init__()
    @require GLMakie="e9467ef8-e4e7-5192-8a1a-b1aee30e663a" begin
        include("live_view.jl")
    end
end

end # module QuantiCam
