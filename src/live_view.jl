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

function live_intensity(qc::QCBoard; frames=50)
    # Activate GLMakie
    GLMakie.activate!()

    # FIXME: Remove QuantiCam module namespace once include works based on Requires
    if !QuantiCam.has_profile(qc, "intensity")
        intensity_profile_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' profile found, using default config from package: $intensity_profile_config_path"
        new_profile!(qc, "intensity", intensity_profile_config_path)
    end
    set_profile!(qc, "intensity")

    # Create a figure and axis
    fig = Figure()

    menu = Menu(fig, options = ["viridis", "lajolla", "heat", "blues"], default = "viridis")
    exposure_slg = SliderGrid(fig,
        (label="Exposure Time", range = 1:500, startvalue=50))
    fig[2,:] = vgrid!(
        Label(fig, "Colormap", width = nothing),
        menu,
        exposure_slg
        )

    ax = Axis(fig[3, 1]; aspect=1)
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm = heatmap!(ax, data)

    cb = Colorbar(fig[3,2], hm, colorrange=0:(frames*512) ,label="Photons count")

    on(menu.selection) do s
        hm.colormap = s
    end
    notify(menu.selection)

    on(exposure_slg.sliders[1].value) do exposure_value
        qc.config.exposure_time = exposure_value
        config_sensor(qc)
    end

    rowsize!(fig.layout, 3, Relative(0.8))
    display(fig)

    #scene = ax.scene

    # Listen for mouse button events
    on(events(fig).mousebutton, priority=2) do event
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

    # Live loop while figure is open
    while isopen(fig.scene)
        intensity_frames = capture_frames(qc, 50)
        intensity_frame = reduce(.+, intensity_frames)
        # Update the heatmap data
        hm[1] = transpose(intensity_frame)# In Makie v0.16+, heatmap data is accessed like this

        # Force redraw/update
        yield()
        #heatmap(one_frame)
    end
end

function live_depth(qc::QCBoard; frames=1000, frames_step=500)
    if !QuantiCam.has_profile(qc, "tcspc")
        tcspc_profile_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' profile found, using default config from package: $tcspc_profile_config_path"
        new_profile!(qc, "tcspc", tcspc_profile_config_path)
    end
    if !QuantiCam.has_profile(qc, "intensity")
        intensity_profile_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' profile found, using default config from package: $intensity_profile_config_path"
        new_profile!(qc, "intensity", intensity_profile_config_path)
    end

    cbuf = CircularBuffer{Matrix{UInt16}}(2048)

    fig = Figure()

    menu = Menu(fig, options = ["viridis", "heat", "blues"], default = "viridis")
    fig[1,1] = vgrid!(
        Label(fig, "Colormap", width = nothing),
        menu)

    ax = Axis(fig[2, 1])
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm = heatmap!(ax, data)

    cbar = Colorbar(fig[2,2], hm, label="Photons count")

    on(menu.selection) do s
        hm.colormap = s
    end
    notify(menu.selection)

    display(fig)

    append!(cbuf, capture_frames(qc, frames))

    # Live loop while figure is open
    while isopen(fig.scene)

        set_profile!(qc, "tcspc")
        #new_frames = capture_frames(qc, frames_step)
        #append!(cbuf, new_frames)

        #filtered_frames = map(frame -> filter_code(frame), cbuf[1:frames])
        #tcspc_stream_missing = collect_frames(filtered_frames)
        #tcspc_stream = map(pixel -> collect(skipmissing(pixel)), tcspc_stream_missing)
        #tcspc_events = map(pixel -> length(collect((skipmissing(pixel)))), tcspc_stream)

        set_profile!(qc, "intensity")
        intensity_frame = capture_frame(qc)


        # Update the heatmap data
        hm[1] = transpose(intensity_frame) # In Makie v0.16+, heatmap data is accessed like this

        # Force redraw/update
        yield()
        #heatmap(one_frame)
    end


end
