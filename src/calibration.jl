using GLM, DataFrames
using FFTW

export measure_tdcs, capture_histograms

function get_tdc_freq(delays::Vector{T}, tdc_peaks::Vector{T}) where T<:Real
    data = DataFrame(delay = delays, tdc = tdc_peaks)
    model = lm(@formula(delay ~ tdc), data)
    tdc_res = coef(model)[2] # Extract slope (TDC resolution in s)
    return 1 / tdc_res
end

function measure_tdcs(qc::QCBoard, delay_range::Tuple{Float64, Float64}, frames_count::Integer; delays_count=10)::Matrix{Float64}
    delayed_peaks = [Vector{Float64}() for _ in 1:qc.config.rows, _ in 1:qc.config.cols]
    delays = collect(LinRange(delay_range[1], delay_range[2], delays_count))
    actual_delays = Float64[]
    for delay in delays
        actual_delay = set_delay!(qc, delay * 1e9) * 1e-9
        @info "Set delay to $(actual_delay * 1e9) ns"
        push!(actual_delays, actual_delay)
        sleep(0.5)

        # DAQ
        frames = capture_frames(qc, frames_count)

        # Processing
        filtered_frames = map(frame -> QuantiCam.filter_code(frame), frames)
        tcspc_stream_missing = collect_frames(filtered_frames)
        tcspc_stream = map(pixel -> collect(skipmissing(pixel)), tcspc_stream_missing)
        #peaks = map(pixel -> get_maximum(pixel), tcspc_stream)
        peaks = map(pixel_stream -> centroid_around_max(pixel_stream), tcspc_stream)

        for i in 1:qc.config.rows, j in 1:qc.config.cols
            append!(delayed_peaks[i, j], peaks[i, j])
        end
    end

    tdcs_freq = map(tdc_peaks -> get_tdc_freq(actual_delays, tdc_peaks), delayed_peaks)

    tdcs_freq
end

function fit_hist(pixel_stream::Vector{T}, tdc_freq::Float64; filter=false)::Histogram where T<:Union{UInt8, UInt16}
    h = fit(Histogram, pixel_stream, 0:1:4095)
    time = h.edges[1] ./ tdc_freq
    counts = h.weights
    if filter
        counts_fourier = fft(counts)
        counts_fourier_bandlimited = copy(counts_fourier)
        counts_fourier_bandlimited[350:end-350] .= 0 .+ 0im
        counts = real.(ifft(counts_fourier_bandlimited))
    end
    Histogram(time, counts)
end

function capture_histograms(
    qc::QCBoard,
    frames_count::Integer,
    tdcs_freq::Matrix{Float64};
    filter=false
)::Matrix{Histogram}
    frames = capture_frames(qc, frames_count)
    filtered_frames = map(frame -> QuantiCam.filter_code(frame), frames)
    tcspc_stream_missing = collect_frames(filtered_frames)
    tcspc_stream = map(pixel -> collect(skipmissing(pixel)), tcspc_stream_missing)

    histograms = map((pixel_stream, tdc_freq,) -> fit_hist(pixel_stream, tdc_freq), zip(tcspc_stream, tdcs_freq))
    histograms
end
