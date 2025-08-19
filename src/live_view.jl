export live_view

function live_view(qc::QCBoard)
    # Activate GLMakie
    GLMakie.activate!()
    # Create a figure and axis
    fig = Figure()
    ax = Axis(fig[1, 1])
    # Create initial data matrix (192x128)
    data = rand(UInt16, 128, 192)

    # Plot initial heatmap and get the plot object for updating
    hm = heatmap!(ax, data)

    display(fig)

    for _ in 1:10000
        sleep(0.1)
        one_frame = capture_frame(qc)
        # Update the heatmap data
        hm[1] = transpose(one_frame)# In Makie v0.16+, heatmap data is accessed like this

        # Force redraw/update
        yield()
        #heatmap(one_frame)
    end
end
