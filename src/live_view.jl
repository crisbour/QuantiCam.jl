using GLMakie
using DataStructures
import StatsBase

export live_intensity, live_depth, live_histogram

function capture_and_process(qc::QCBoard)
    black_coord_ch = Channel{CartesianIndex}(0)
    black_coord = nothing

    if isready(black_coord_ch)
        black_coord = take!(black_coord_ch)
    end
    intensity_frame = capture_frame(qc)

    black_ref =
        if black_coord === nothing
            0
        else
            intensity_frame[black_coord]
        end
    unwrap_intensity_frame = intensity_frame .- black_ref

end

# ------------------------------------------------
# Live view functions
# ------------------------------------------------

function live_intensity(qc::QCBoard; frames=5)
    qc_lock = ReentrantLock()

    # Activate GLMakie
    GLMakie.activate!()

    # FIXME: Remove QuantiCam module namespace once include works based on Requires
    if !QuantiCam.has_config(qc, "intensity")
        intensity_config_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' config found, using default config from package: $intensity_config_config_path"
        new_config!(qc, "intensity", intensity_config_config_path)
    end
    set_config!(qc, "intensity")

    # Create a figure and axis
    fig = Figure()

    menu = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    exposure_slg = SliderGrid(fig,
                              (label="Exposure Time", range = Unsigned.(2 .^ (2:9)), startvalue=Unsigned(32)),
        (label="Frames", range = Unsigned.(1:200), startvalue=Unsigned(frames)))
    fig[1,1] = vgrid!(hgrid!(
        Label(fig, "Colormap", width = nothing),
        menu),
        exposure_slg
        )

    ax = Axis(fig[2, 1]; aspect=1)
    # Create initial data matrix (192x128)
    data = rand(UInt32, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm = heatmap!(ax, data)

    Colorbar(fig[2,2], hm, label="Photons count")

    rowsize!(fig.layout, 2, Relative(0.8))

    # Thread-safe variables for frames
    atomic_frames = Threads.Atomic{Int}(frames)
    ch_intensity_frame = Channel{Matrix{UInt64}}(1)
    # Spawn a new thread to continuously capture and process frames
    intensity_producer = Threads.@spawn collect_intensity_frame(qc, qc_lock, atomic_frames, ch_intensity_frame)

    # Display and run update loop
    display(fig)
    consumer = Threads.@spawn begin
        on(menu.selection) do s
            hm.colormap = s
        end
        notify(menu.selection)

        on(exposure_slg.sliders[1].value) do exposure_time
            lock(qc_lock) do
                change_config!(qc, "intensity", :exposure_time, exposure_time)
                set_config!(qc, "intensity")
            end
        end

        on(exposure_slg.sliders[2].value) do slider_frames
            atomic_frames[] = slider_frames
        end
        # Live loop while figure is open
        while isopen(fig.scene)
            try
                # Update the heatmap data
                intensity_frame = take!(ch_intensity_frame)
                hm[1] = intensity_frame # Update heatmap data
                yield() # Force redraw/update
            catch e
                @error "Error in consumer thread: $e"
                break
            end
        end
    end
    bind(ch_intensity_frame, intensity_producer)
    wait(consumer)
    close(ch_intensity_frame)
    wait(intensity_producer)
end

function collect_tcspc_frame(
    qc::QCBoard,
    qc_lock::ReentrantLock,
    n_frames::Threads.Atomic{Int},
    ch::Channel
)
    while true
        try
            new_frames = lock(qc_lock) do
                set_config!(qc, "tcspc")
                capture_frames(qc, n_frames)
            end
            filtered_frames = map(frame -> filter_code(frame), new_frames)
            tcspc_stream_missing = collect_frames(filtered_frames)
            tcspc_stream = map(pixel -> collect(skipmissing(pixel)), tcspc_stream_missing)
            if !isopen(ch)
                break
            end
        catch e
            @error "Error in collect_tcspc thread: $e"
            break
        end
    end
end

function collect_tcspc_pixel(
    qc::QCBoard,
    qc_lock::ReentrantLock,
    n_frames::Threads.Atomic{Int},
    ch_pixel_idx::Channel{CartesianIndex},
    ch_pixel_values::Channel{Vector{T}}
) where T <: Union{UInt8, UInt16}
    pixel_idx = CartesianIndex(qc.config.rows÷2, qc.config.cols÷2) # Start from the center pixel
    @info "Start collecting TCSPC data for pixel: $pixel_idx with frames=$(n_frames[])"
    while true
        if isready(ch_pixel_idx)
            pixel_idx = take!(ch_pixel_idx)
            @info "Collecting TCSPC data for pixel: $pixel_idx"
        end
        try
            new_frames = lock(qc_lock) do
                set_config!(qc, "tcspc")
                capture_frames(qc, n_frames[])
            end
            filtered_pixel = collect(skipmissing(map(frame -> filter_code(frame[pixel_idx]), new_frames)))
            if !isopen(ch_pixel_values)
                @error "Channel for pixel values is closed, exiting collect_tcspc_pixel"
                break
            end
            put!(ch_pixel_values, filtered_pixel)
        catch e
            @error "Error in collect_tcspc_pixel thread: $e => Skip this time"
        end
    end
end

function collect_intensity_frame(
    qc::QCBoard,
    qc_lock::ReentrantLock,
    n_frames::Threads.Atomic{Int},
    ch::Channel{Matrix{T}};
    delay = 0.02
) where T <: Unsigned
    @info "Start collecting intensity frames with n_frames=$(n_frames[])"
    while true
        try
            intensity_frames = lock(qc_lock) do
                set_config!(qc, "intensity")
                # FIXME: QuantiCam.jl use Result.jl types instead of exception to reduce overhead to stack unrolling when panicking
                capture_frames(qc, n_frames[])
            end
            intensity_frame = reduce(.+, intensity_frames)
            if !isopen(ch)
                break
            end
            put!(ch, transpose(intensity_frame)) # Transpose to match Makie orientation
        catch e
            @error "Error in collect_intensity thread: $e => Skip this time"
        end
        Threads.sleep(delay)
    end
end

function collect_hist_pixel(
    n_frames::Threads.Atomic{Int},
    bin_width::Threads.Atomic{Int},
    ch_pixel_values::Channel{Vector{T}},
    ch_pixel_hist::Channel #{StatsBase.Histogram{T, 1, AbstractArray{T}}}
) where T <: Union{UInt8, UInt16}
    @info "Start collecting histogram for pixel with n_frames=$(n_frames[]), bin_width=$(bin_width[])"
    cbuf = CircularBuffer{T}(1024)
    while true
        try
            if !isopen(ch_pixel_values)
                break
            end
            pixel_values = take!(ch_pixel_values)

            append!(cbuf, pixel_values)
            if (length(cbuf) < n_frames[])
                continue
            end
            start_idx = length(cbuf) - n_frames[] + 1
            stop_idx = length(cbuf)
            hist = StatsBase.fit(StatsBase.Histogram{T}, cbuf[start_idx:stop_idx], 0:bin_width[]:4096)

            if !isopen(ch_pixel_hist)
                break
            end
            put!(ch_pixel_hist, hist)
        catch e
            @error "Error in collect_hist_pixel thread: $e => Skip this time"
        end
    end
end

# Live histogram view
function live_histogram(qc::QCBoard; n_frames_step=100, n_intensity_frames=32)
    qc_lock = ReentrantLock()

    # Activate GLMakie
    GLMakie.activate!()

    if !QuantiCam.has_config(qc, "tcspc")
        tcspc_config_config_path = joinpath(@__DIR__, "../config/tcspc.json")
        @warn "No 'tcspc' config found, using default config from package: $tcspc_config_config_path"
        new_config!(qc, "tcspc", tcspc_config_config_path)
    end
    if !QuantiCam.has_config(qc, "intensity")
        intensity_config_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' config found, using default config from package: $intensity_config_config_path"
        new_config!(qc, "intensity", intensity_config_config_path)
    end


    fig = Figure(size=(1200, 600))

    g_intensity = fig[1,1] = GridLayout()
    g_hist = fig[1,2] = GridLayout()

    # Photon count settings and heatmap
    # ---------------------------------
    menu_intensity = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    intensity_slg = SliderGrid(fig,
        (label="Exposure Time", range = Unsigned.(2 .^ (2:9)), startvalue=Unsigned(8)),
        (label="Frames", range = Unsigned.(1:200), startvalue=Unsigned(n_intensity_frames)))
    g_intensity[1,1] = vgrid!(
        hgrid!(
            Label(fig, "Colormap", width = nothing),
            menu_intensity),
        intensity_slg
        )
    ax_intensity = Axis(g_intensity[2, 1], title="Intensity image")
    # Create initial data matrix (192x128)
    data_intensity = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm_intensity = heatmap!(ax_intensity, data_intensity)

    Colorbar(g_intensity[2,2], hm_intensity, label="Photons count")

    # Thread-safe variable for frames
    n_intensity_frames_atomic = Threads.Atomic{Int}(n_intensity_frames)

    # Selected pixel histogram
    # ---------------------------------
    hist_slg = SliderGrid(fig,
        (label="Exposure Time", range = Unsigned.(2 .^ (2:10)), startvalue=Unsigned(128)),
        (label="Frames", range = Unsigned.(1:4000), startvalue=Unsigned(4*n_frames_step)),
        (label="Frames step", range = Unsigned.(2 .^ (4:10)), startvalue=Unsigned(n_frames_step)),
        (label="Histogram bin width", range = 2 .^ (0:8), startvalue=32),
        (label="Phase offset", range = 0:5:360, startvalue=0)
    )
    g_hist[1,1] = vgrid!(
        hist_slg
        )
    pixel_idx_hist = Observable(CartesianIndex(qc.config.rows÷2, qc.config.cols÷2)) # Start from the center pixel
    # Plot initial heatmap and get the plot object for updating
    ax_hist = Axis(g_hist[2, 1], limits=((0,4096), (0,50)), title=lift(x -> "Histogram of pixel $x", pixel_idx_hist))
    data_hist = zeros(UInt16, 2000)
    pixel_hist = Ref(barplot!(ax_hist, 0:32:4095, fill(UInt16(0), 128), color=:dodgerblue))

    # Thread-safe variable for frames
    n_frames_step_atomic = Threads.Atomic{Int}(n_frames_step)
    n_frames_atomic = Threads.Atomic{Int}(4*n_frames_step)
    bin_width_atomic = Threads.Atomic{Int}(32)

    ch_pixel_idx = Channel{CartesianIndex}(1)

    ch_intensity_frame = Channel{Matrix{UInt64}}(1)
    intensity_producer = Threads.@spawn collect_intensity_frame(qc, qc_lock, n_intensity_frames_atomic, ch_intensity_frame)

    ch_tcspc_pixel = Channel{Vector{UInt16}}(1)
    tcspc_producer = Threads.@spawn collect_tcspc_pixel(qc, qc_lock, n_frames_step_atomic, ch_pixel_idx, ch_tcspc_pixel)

    #ch_tcspc_hist = Channel{StatsBase.Histogram{UInt16,1, NTuple{1, AbstractArray{UInt16}}}}(1)
    ch_tcspc_hist = Channel(1)
    hist_producer = Threads.@spawn collect_hist_pixel(n_frames_atomic, bin_width_atomic,  ch_tcspc_pixel, ch_tcspc_hist)

    display(fig)

    consumer = Threads.@spawn begin
        on(menu_intensity.selection) do s
            hm_intensity.colormap = s
        end
        notify(menu_intensity.selection)

        on(intensity_slg.sliders[1].value) do exposure_time
            change_config!(qc, "intensity", :exposure_time, exposure_time)
        end

        on(intensity_slg.sliders[2].value) do slider_frames
            n_intensity_frames_atomic[] = slider_frames
        end

        # Listen for mouse button events
        on(events(ax_intensity).mousebutton) do event
            if event.button == Mouse.left && event.action == Mouse.press
                # pick returns the plot and the index of the selected element
                plt, idx = pick(fig)
                if plt == hm_intensity
                    # idx is a linear index for the heatmap matrix
                    # convert linear index to row, col if needed
                    col = (idx - 1) % qc.config.cols + 1
                    row = Int(fld((idx - 1), qc.config.cols)) + 1
                    @info "Clicked heatmap cell index: $idx => $((row, col))"
                    if isready(ch_pixel_idx)
                        take!(ch_pixel_idx) # Remove previous index if any
                    end
                    pixel_idx_hist[] = CartesianIndex(row, col)
                    put!(ch_pixel_idx, CartesianIndex(row, col))
                end
            end
        end

        on(hist_slg.sliders[1].value) do exposure_time
            lock(qc_lock) do
                change_config!(qc, "tcspc", :exposure_time, exposure_time)
            end
        end
        on(hist_slg.sliders[2].value) do slider_frames
            n_frames_atomic[] = slider_frames
        end
        on(hist_slg.sliders[3].value) do slider_frames_step
            n_frames_step_atomic[] = slider_frames_step
        end
        on(hist_slg.sliders[4].value) do bin_width
            bin_width_atomic[] = bin_width
            delete!(ax_hist, pixel_hist[])  # Clear the axis before re-plotting
            pixel_hist[] = barplot!(ax_hist, 0:bin_width:4095, fill(UInt16(0), 4096 ÷ bin_width), color=:dodgerblue)
        end
        on(hist_slg.sliders[5].value) do phase_offset
            lock(qc_lock) do
                set_phase!(qc, phase_offset)
            end
        end
        # Live loop while figure is open
        while isopen(fig.scene)
            try
                # Update the heatmap and hist data
                if isready(ch_intensity_frame)
                    intensity_frame = take!(ch_intensity_frame)
                    hm_intensity[1] = intensity_frame # Update heatmap data
                end
                if isready(ch_tcspc_hist)
                    hist = take!(ch_tcspc_hist)
                    if (4096 ÷ bin_width_atomic[]) == length(hist.weights)
                        pixel_hist[][1] = hist.edges[1][1:end-1]
                        pixel_hist[][2] = hist.weights
                    end
                    #pixel_hist[] = barplot!(ax_hist, hist.edges[1][1:end-1], hist.weights, color=:dodgerblue)
                end

                yield() # Force redraw/update
            catch e
                @error "Error in consumer thread: $e"
                break
            end
        end
    end

    bind(ch_intensity_frame, intensity_producer)
    bind(ch_tcspc_pixel, tcspc_producer)
    #bind(ch_tcspc_hist, hist_producer)
    wait(consumer)
    close(ch_intensity_frame)
    close(ch_tcspc_pixel)
    close(ch_pixel_idx)
    close(ch_tcspc_hist)
end

# Live depth view
function live_depth(qc::QCBoard; n_frames=100, n_intensity_frames=50)
    qc_lock = ReentrantLock()

    # Activate GLMakie
    GLMakie.activate!()

    if !QuantiCam.has_config(qc, "tcspc")
        tcspc_config_config_path = joinpath(@__DIR__, "../config/tcspc.json")
        @warn "No 'tcspc' config found, using default config from package: $tcspc_config_config_path"
        new_config!(qc, "tcspc", tcspc_config_config_path)
    end
    if !QuantiCam.has_config(qc, "intensity")
        intensity_config_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' config found, using default config from package: $intensity_config_config_path"
        new_config!(qc, "intensity", intensity_config_config_path)
    end

    cbuf = CircularBuffer{Matrix{UInt16}}(2048)

    fig = Figure(size=(1200, 600))

    g_intensity = fig[1,1] = GridLayout()
    g_hist = fig[1,2] = GridLayout()
    g_depth = fig[1,3] = GridLayout()

    # Photon count settings and heatmap
    # ---------------------------------
    menu_intensity = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    intensity_slg = SliderGrid(fig,
        (label="Exposure Time", range = Unsigned.(2 .^ (2:9)), startvalue=Unsigned(32)),
        (label="Frames", range = Unsigned.(1:200), startvalue=Unsigned(n_intensity_frames)))
    g_intensity[1,1] = vgrid!(
        hgrid!(
            Label(fig, "Colormap", width = nothing),
            menu_intensity),
        intensity_slg
        )
    ax_intensity = Axis(g_intensity[2, 1], title="Intensity image")
    # Create initial data matrix (192x128)
    data_intensity = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm_intensity = heatmap!(ax_intensity, data_intensity)

    Colorbar(g_intensity[2,2], hm_intensity, label="Photons count")

    # Thread-safe variable for frames
    n_intensity_frames_atomic = Threads.Atomic{Int}(n_intensity_frames)

    # Selected pixel histogram
    # ---------------------------------
    hist_slg = SliderGrid(fig,
        (label="Exposure Time", range = Unsigned.(2 .^ (2:9)), startvalue=Unsigned(32)),
        (label="Frames", range = Unsigned.(1:500), startvalue=Unsigned(n_frames)),
        (label="Histogram bins", range = 2 .^ (2:12), startvalue=100)
    )
    g_hist[1,1] = vgrid!( hist_slg)
    # Plot initial heatmap and get the plot object for updating
    ax_hist = Axis(g_hist[2, 1], limits=((0,4096), (0,50)))
    data_hist = zeros(UInt16, 2000)
    pixel_hist = Ref(hist!(ax_hist, data_hist, bins=100))


    # Computed depth heatmap
    # ---------------------------------
    menu_depth_color = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    menu_depth_alg = Menu(fig, options = ["Peak", "Matched filter", "Sketch", "Histogram-less"], default = "Peak")
    # TODO: Add different methods for extracting depth from histogram
    depth_slg = SliderGrid(fig,
        (label="Bins", range = Unsigned.(1:500), startvalue=Unsigned(200)),
        (label="", range = Unsigned.(1:500), startvalue=Unsigned(200))
    )
    g_depth[1,1] = vgrid!(
        hgrid!(Label(fig, "Colormap", width = nothing), menu_depth_color),
        hgrid!(Label(fig, "Algorithm", width = nothing), menu_depth_alg),
        )
    ax_depth = Axis(g_depth[2, 1])
    # Create initial data matrix (192x128)
    data_depth = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm_depth = heatmap!(ax_depth, data_depth)

    # Connect threads together
    # ------------------------
    # Thread-safe variable for frames
    n_frames_atomic = Threads.Atomic{Int}(n_frames)

    ch_pixel_idx = Channel{CartesianIndex}(1)

    ch_intensity_frame = Channel{Matrix{UInt64}}(1)
    intensity_producer = Threads.@spawn collect_intensity_frame(qc, qc_lock, n_intensity_frames_atomic, ch_intensity_frame)

    ch_tcspc_pixel = Channel{Vector{UInt16}}(1)
    tcspc_producer = Threads.@spawn collect_tcspc_pixel(qc, qc_lock, n_frames_atomic, ch_pixel_idx, ch_tcspc_pixel)

    display(fig)

    consumer = Threads.@spawn begin
        on(menu_intensity.selection) do s
            hm_intensity.colormap = s
        end
        notify(menu_intensity.selection)

        on(intensity_slg.sliders[1].value) do exposure_time
            change_config!(qc, "intensity", :exposure_time, exposure_time)
        end

        on(intensity_slg.sliders[2].value) do slider_frames
            n_intensity_frames_atomic[] = slider_frames
        end

        # Listen for mouse button events
        on(events(ax_intensity).mousebutton) do event
            if event.button == Mouse.left && event.action == Mouse.press
                # pick returns the plot and the index of the selected element
                plt, idx = pick(fig)
                if plt == hm_intensity
                    # idx is a linear index for the heatmap matrix
                    # convert linear index to row, col if needed
                    col = (idx - 1) % qc.config.cols + 1
                    row = Int(fld((idx - 1), qc.config.cols)) + 1
                    @info "Clicked heatmap cell index: $idx => $((row, col))"
                    if isready(ch_pixel_idx)
                        take!(ch_pixel_idx) # Remove previous index if any
                    end
                    put!(ch_pixel_idx, CartesianIndex(row, col))
                end
            end
        end

        on(hist_slg.sliders[1].value) do exposure_time
            lock(qc_lock) do
                change_config!(qc, "tcspc", :exposure_time, exposure_time)
            end
        end
        on(hist_slg.sliders[2].value) do slider_frames
            n_frames_atomic[] = slider_frames
        end
        on(hist_slg.sliders[3].value) do bins
            delete!(ax_hist, pixel_hist[])  # Clear the axis before re-plotting
            pixel_hist[] = hist!(ax_hist, data_hist, bins=bins)
        end

        on(menu_depth_color.selection) do s
            hm_depth.colormap = s
        end
        notify(menu_depth_color.selection)

        on(menu_depth_alg.selection) do s
            # TODO
        end
        notify(menu_depth_alg.selection)

        # Live loop while figure is open
        while isopen(fig.scene)
            try
                # Update the heatmap and hist data
                if isready(ch_intensity_frame)
                    intensity_frame = take!(ch_intensity_frame)
                    hm_intensity[1] = intensity_frame # Update heatmap data
                end
                if isready(ch_tcspc_pixel)
                    pixel_hist[][1] = take!(ch_tcspc_pixel)
                end

                yield() # Force redraw/update
            catch e
                @error "Error in consumer thread: $e"
                break
            end
        end
    end

    bind(ch_intensity_frame, intensity_producer)
    bind(ch_tcspc_pixel, tcspc_producer)
    wait(consumer)
    close(ch_intensity_frame)
    close(ch_tcspc_pixel)
    close(ch_pixel_idx)
end
