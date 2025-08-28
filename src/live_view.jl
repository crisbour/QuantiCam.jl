using GLMakie
using DataStructures

export live_intensity, live_depth

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

function live_intensity(qc::QCBoard; frames=50)
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
        (label="Exposure Time", range = Unsigned.(1:500), startvalue=Unsigned(50)),
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

    cb = Colorbar(fig[2,2], hm, label="Photons count")

    on(menu.selection) do s
        hm.colormap = s
    end
    notify(menu.selection)

    on(exposure_slg.sliders[1].value) do exposure_time
        change_config!(qc, "intensity", :exposure_time, exposure_time)
        set_config!(qc, "intensity")
    end

    # Thread-safe variable for frames
    atomic_frames = Threads.Atomic{Int}(frames)
    on(exposure_slg.sliders[2].value) do slider_frames
        atomic_frames[] = slider_frames
    end

    rowsize!(fig.layout, 2, Relative(0.8))
    display(fig)

    #scene = ax.scene

    # Listen for mouse button events
    on(events(fig).mousebutton) do event
        if event.button == Mouse.left && event.action == Mouse.press
            # pick returns the plot and the index of the selected element
            plt, idx = pick(fig)
            if plt == hm
                # idx is a linear index for the heatmap matrix
                println("Clicked heatmap cell index: ", idx)
                # convert linear index to row, col if needed
                row = (idx - 1) % size(data, 1) + 1
                col = Int(fld((idx - 1), size(data, 1))) + 1
                println("Row: ", row, ", Col: ", col)
            end
        end
    end

    ch_intensity_frame = Channel{Matrix{UInt64}}(1)
    # Spawn a new thread
    producer = Threads.@spawn begin
        while true
            try
                intensity_frames = capture_frames(qc, atomic_frames[])
                intensity_frame = reduce(.+, intensity_frames)
                intensity_frame = transpose(intensity_frame) # Transpose to match Makie orientation
                if !isopen(ch_intensity_frame)
                    break
                end
                put!(ch_intensity_frame, intensity_frame)
            catch e
                @error "Error in producer thread: $e"
                break
            end
        end
    end

    consumer = Threads.@spawn begin
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
    wait(consumer)
    close(ch_intensity_frame)
    wait(producer)
end

# Live depth view

function live_depth(qc::QCBoard; frames=500, frames_step=500)
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
        (label="Exposure Time", range = Unsigned.(1:500), startvalue=Unsigned(50)))
    g_intensity[1,1] = vgrid!(hgrid!(
        Label(fig, "Colormap", width = nothing),
        menu_intensity),
        intensity_slg
        )
    ax = Axis(g_intensity[2, 1])
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm_intensity = heatmap!(ax, data)

    cbar = Colorbar(g_intensity[2,2], hm_intensity, label="Photons count")

    on(menu_intensity.selection) do s
        hm_intensity.colormap = s
    end
    notify(menu_intensity.selection)

    on(intensity_slg.sliders[1].value) do exposure_time
        change_config!(qc, "intensity", :exposure_time, exposure_time)
    end

    # Selected pixel histogram
    # ---------------------------------
    menu_hist = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    hist_slg = SliderGrid(fig,
        (label="Exposure Time", range = Unsigned.(1:500), startvalue=Unsigned(50)),
        (label="Histogram bins", range = Unsigned.(1:500), startvalue=Unsigned(200))
    )
    g_hist[1,1] = vgrid!(hgrid!(
        Label(fig, "Colormap", width = nothing),
        menu_hist),
        hist_slg
        )
    # Plot initial heatmap and get the plot object for updating
    ax = Axis(g_hist[2, 1])
    data = rand(UInt16, 2000)
    pixel_hist = hist!(ax, data, bins=200)

    on(menu_hist.selection) do s
        # nothing to do ?
    end
    notify(menu_hist.selection)

    on(hist_slg.sliders[1].value) do exposure_time
        change_config!(qc, "tcspc", :exposure_time, exposure_time)
    end
    on(hist_slg.sliders[2].value) do bins
        pixel_hist.bins = bins
    end

    # Computed depth heatmap
    # ---------------------------------
    menu_depth = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    menu_depth_alg = Menu(fig, options = ["Peak", "Matched filter", "Sketch", "Histogram-less"], default = "Peak")
    # TODO: Add different methods for extracting depth from histogram
    depth_slg = SliderGrid(fig,
        (label="Bins", range = Unsigned.(1:500), startvalue=Unsigned(200)),
        (label="", range = Unsigned.(1:500), startvalue=Unsigned(200))
    )
    g_depth[1,1] = vgrid!(
        hgrid!(Label(fig, "Colormap", width = nothing), menu_depth),
        hgrid!(Label(fig, "Algorithm", width = nothing), menu_depth_alg),
        )
    ax = Axis(g_depth[2, 1])
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm_depth = heatmap!(ax, data)

    on(menu_depth.selection) do s
        hm_depth.colormap = s
    end
    notify(menu_depth.selection)

    display(fig)

    # Run a thread process that every 100ms set_config to `intensity` and captures 50 frames
    # and updates the heatmap with the average of those frames]

    # Live loop while figure is open
    while isopen(fig.scene)
        set_config!(qc, "intensity")
        intensity_frames = capture_frames(qc, 50)
        intensity_frame = reduce(.+, intensity_frames)
        # Update the heatmap data
        hm_intensity[1] = transpose(intensity_frame) # In Makie v0.16+, heatmap data is accessed like this

        set_config!(qc, "tcspc")
        new_frames = capture_frames(qc, 100)

        filtered_frames = map(frame -> filter_code(frame), new_frames)
        tcspc_stream_missing = collect_frames(filtered_frames)
        tcspc_stream = map(pixel -> collect(skipmissing(pixel)), tcspc_stream_missing)
        tcspc_events = map(pixel -> length(collect((skipmissing(pixel)))), tcspc_stream)
        # Update the heatmap data
        pixel_hist[1] = tcspc_stream[40,50]

        # Force redraw/update
        yield()
    end


end
