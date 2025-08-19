using GLMakie
export live_view

function live_view(qc::QCBoard)
    # Activate GLMakie
    GLMakie.activate!()

    # FIXME: Remove QuantiCam module namespace once include works based on Requires
    if QuantiCam.has_profile(qc, "intensity")
        intensity_profile_config_path = joinpath(@__DIR__, "../config/photon_cnt.json")
        @warn "No 'intensity' profile found, using default config from package: $intensity_profile_config_path"
        qc.new_profile!("intensity", intensity_profile_config_path)
    end
    if QuantiCam.has_profile(qc, "tcspc")
        tcspc_profile_config_path = joinpath(@__DIR__, "../config/tcspc.json")
        @warn "No 'tcspc' profile found, using default config from package: $tcspc_profile_config_path"
        qc.new_profile!("tcspc", tcspc_profile_config_path)
    end

    # Create a figure and axis
    fig = Figure()
    ax = Axis(fig[1, 1])
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm = heatmap!(ax, data)

    display(fig)

    # Live loop while figure is open
    while isopen(fig.scene)
        qc.set_profile!("intensity") # Set the profile to 'tcspc' for live viewing
        one_frame = capture_frame(qc)
        # Update the heatmap data
        hm[1] = transpose(one_frame)# In Makie v0.16+, heatmap data is accessed like this

        # Force redraw/update
        yield()
        #heatmap(one_frame)
    end
end
