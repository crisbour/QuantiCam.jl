export filter_code, collect_frames, build_histogram, decode_histogram_to_depth, centroid_around_max, centroid, fwhm, histogram_maximum

function collect_frames(v::Vector{Matrix{T}})::Matrix{Vector{T}} where T
    n_rows = size(v[1], 1)
    n_cols = size(v[1], 2)
    n_matrices = length(v)

    result = Matrix{Vector{T}}(undef, n_rows, n_cols)

    for i in 1:n_rows, j in 1:n_cols
        result[i, j] = [v[k][i, j] for k in 1:n_matrices]
    end

    return result
end


# --------------------------------------------------
# Qualify pixel reads to float + nan boxing based on codes
# --------------------------------------------------

function filter_code(tdc_pixel::T; decode_mode=DecodeMode.Decoded)::Union{T, Missing} where T <: Union{UInt8, UInt16}
    # 0x04 is the code for missing data
    if decode_mode == DecodeMode.Decoded
        if tdc_pixel isa UInt16
            if tdc_pixel == 0x1ff
                return missing
            else
                return tdc_pixel
            end
        else
            if tdc_pixel == 0xff
                return missing
            else
                return tdc_pixel
            end
        end
    else
        return tdc_pixel
    end
end

function filter_code(
    tdc_pixels::Array{T};
    decode_mode=DecodeMode.Decoded,
)::Array{Union{T, Missing}} where T <: Union{UInt8, UInt16}
    map(x -> filter_code(x, decode_mode=decode_mode), tdc_pixels)
end

function filter_code(tdc_pixel::T, missing_code::Unsigned)::Union{T, Missing} where T <: Union{UInt8, UInt16}
    if (tdc_pixel == missing_code) missing else tdc_pixel end
end

function filter_code(tdc_pixels::Array{T}, missing_code::Unsigned)::Array{Union{T, Missing}} where T <: Union{UInt8, UInt16}
    map(x -> filter_code(x, missing_code), tdc_pixels)
end
# Assume each pixel might have a slightly different ring-oscillator,
# hence, based on this inferred TDC clock, we convert the timestamp to calibrated qualified timestamps
function calibrate_tdc(data::Array{Float32}, freq::Array{Float32})
    data .* (1e9 ./ freq)  # in ns
end

# The timestamps will have a delay based on constant line delay + some offset inherent to each SPAD impulse response
function calibrate_offset(data::Array{Float32}, offset::Array{Float32})
    data .- offset
end

# ==================================================
# TCSPC data decoding of pixels trig->STOP into START->trig
# ==================================================
# WARN: This takes the 2s complement yet again for the 12-bit TCSPC value,
# which shouldn't be necessary

function twos_complement_branching(
    data::T,
    size = nothing,
)::T where {T<:Union{UInt8,UInt16}}
    if size === nothing
        size = sizeof(data) * 8
    end
    masked_data = data & (1 << size - 1)
    if masked_data == 0
        masked_data = 1 << size
    end
    (1 << size) - masked_data
end

function twos_complement_instr(data::T, bits = nothing)::T where {T<:Union{UInt8,UInt16}}
    shamt = 8 * sizeof(data) - bits
    twos_complement_shifted = -reinterpret(signed(T), data << shamt)
    twos_complement_shifted_unsigned = reinterpret(T, twos_complement_shifted)
    twos_complement_shifted_unsigned >> shamt
end

function decode_frame_data(tdc_pixels::Array{UInt16})
    #data_decoded = map(pixel -> twos_complement_instr(pixel, 12), tdc_pixels)
    data_decoded_coarse = map(pixel -> twos_complement_instr(pixel >> 3, 9), tdc_pixels)
    data_decoded_fine = map(pixel -> ~(pixel & 0x7), tdc_pixels)
    data_decoded = map(
        (coarse, fine) -> coarse << 3 | fine,
        zip(data_decoded_coarse, data_decoded_fine),
    )
    data_decoded
end

# ==================================================
# Functions for histogram building and depth decoding
# ==================================================

"""
    Module for building histograms from TCSPC stream data
    Inputs:
        - tcspc_stream: Matrix of Vectors containing TCSPC data per pixel
        - num_bins: Desired number of bins for the histogram
        - max_tdc: Maximum TDC code (default 4095)
    Ouptputs:
        - histograms: Matrix of Vectors containing histogram data per pixel
"""

function build_histogram(
    tcspc_stream::Matrix{Vector{T}},
    num_bins::Int,
    max_tdc::Int=4095
)::Matrix{Vector{T}} where T <: Union{UInt16, UInt8}
    # Build histogram from TCSPC stream data
    H, W = size(tcspc_stream)
    histograms = Matrix{Vector{T}}(undef, H, W)
    rebin_factor = cld(max_tdc, num_bins)  # ceiling division
    for i in 1:H, j in 1:W
        # Extract B values for pixel (i,j), skip missing
        values = collect(skipmissing(tcspc_stream[i, j]))

        # Create histogram bin vector (counts per bin index)
        h = zeros(UInt16, num_bins)

        for v in values
            if 1 ≤ v ≤ max_tdc
                new_bin = clamp(fld(v - 1, rebin_factor) + 1, 1, num_bins)
                h[new_bin] += 1
            end
        end

        histograms[i, j] = h
    end
    return histograms
end

"""
    Decode histogram data to depth map
    Inputs:
        - histograms: Matrix of Vectors containing histogram data per pixel
        - reach: Number of bins to consider around the maximum for centroid calculation (default 3)
        - compensation: Optional matrix for depth compensation caused by clock distribution network (default nothing)
    Outputs:
        - centroid: Matrix of Float64 containing estimated sub bin centroid per pixel
"""
function decode_histogram_to_depth(histograms::Matrix{Vector{T}}, reach::Int=3, compensation::Union{Matrix{Float64},Nothing}=nothing) where T
    # Estimate depth map from histogram data
    H, W = size(histograms)
    centroid = Matrix{Float64}(undef, H, W)
    for i in 1:H
        for j in 1:W
            pixel_histogram = histograms[i, j]
            medval = median(Float64.(pixel_histogram))
            pixel_histogram = max.(Float64.(pixel_histogram) .- medval, 0.0)
            centroid[i, j] = centroid_around_max(pixel_histogram, reach, medval)
        end
    end
    if !isnothing(compensation)
        @assert size(compensation) == size(centroid) "Compensation matrix size must match centroid size"
        centroid .+= compensation
    end
    return centroid # Matrix{Float64}
end

function decode_histogram_to_depth(
    histograms::Matrix{Histogram},
    reach::Int=5;
    compensation::Union{Matrix{Float64},Nothing}=nothing
)::Matrix{Float64}
    # Estimate depth map from histogram data
    centroids = map(hist -> centroid(hist, reach), histograms)

    if !isnothing(compensation)
        @assert size(compensation) == size(centroids) "Compensation matrix size must match centroid size"
        centroids .+= compensation
    end

    centroids
end


"""
    Compute centroid around the maximum value in the histogram
    Inputs:
        - histogram: Vector containing histogram data for a pixel
        - centroid_reach: Number of bins to consider around the maximum (default 3)
        - medval: Median value of the histogram for noise estimation (default 0.0)
    Outputs:
        - centroid: Float64 value representing the centroid position, or NaN if conditions not met
"""
function centroid_around_max(histogram::Vector{T}, centroid_reach; medval::Float64=0.0) where T
    # Compute the centroid of the histogram around the maximum value
    # Find the index of the maximum value in the histogram
    max_val, max_index = findmax(histogram)
    if max_val >= 11*sqrt(medval)  && max_val > 5.0
        hist_len = length(histogram)
        # Determine the start and end indices for the centroid calculation
        reach_below = min(centroid_reach, max_index - 1)
        reach_above = min(centroid_reach, hist_len - max_index)
        reach = min(reach_below, reach_above)

        start_index = max_index - reach
        end_index = max_index + reach

        # Compute the centroid as the weighted average of the values in the histogram
        centroid = sum((i * histogram[i] for i in start_index:end_index)) / (sum(histogram[start_index:end_index]) + 1e-6)

        return centroid # Float64
    else
        return NaN
    end
end

function centroid(tdc_samples::Vector{T}, centroid_reach::Int=5)::Float64 where T<:Union{UInt8, UInt16}
    # Compute the centroid of the histogram around the maximum value
    # Find the index of the maximum value in the histogram
    h = fit(Histogram, tdc_samples, UInt16.(0:1:4095))
    return centroid_around_max(h, centroid_reach)
end

function centroid(h::Histogram{T,1,E}, centroid_reach::Int=5)::Float64 where {T,E}
    # Compute the centroid of the histogram around the maximum value
    # Find the index of the maximum value in the histogram
    max_idx = findfirst(==(maximum(h.weights)), h.weights)
    max_val = h.weights[max_idx]

    if max_val > 5.0
        # Determine the start and end indices for the centroid calculation
        reach_below = min(centroid_reach, max_idx - 1)
        reach_above = min(centroid_reach, length(h.weights) - max_idx)
        reach = min(reach_below, reach_above)

        start_index = max_idx - reach
        end_index = max_idx + reach

        # Compute the centroid as the weighted average of the values in the histogram
        centroid = sum((h.edges[1][i] * h.weights[i] for i in start_index:end_index)) / (sum(h.weights[start_index:end_index]) + 1e-6)

        return centroid
    else
        return NaN
    end
end

function histogram_maximum(pixel_stream::Vector{T})::T where T <: Union{UInt16, UInt8}
    h = fit(Histogram, pixel_stream, 0:1:4095)
    idx = findfirst(==(maximum(h.weights)), h.weights)
    return h.edges[1][idx]
end

function fwhm(h::Histogram{T,1})::T where T
    max_idx = findfirst(==(maximum(h.weights)), h.weights)
    max_val = h.weights[max_idx]
    half_max = max_val / 2

    # Find the indices where the histogram crosses half maximum
    left_idx = max_idx
    while left_idx > 1 && h.weights[left_idx] >= half_max
        left_idx -= 1
    end
    right_idx = max_idx
    while right_idx < length(h.weights) && h.weights[right_idx] >= half_max
        right_idx += 1
    end

    fwhm_value = h.edges[1][right_idx] - h.edges[1][left_idx]

    return fwhm_value
end
