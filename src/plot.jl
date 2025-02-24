function plotIntensityImage(obj,data,number_of_frames)
  data_masked = data .& 0x1FFF

  row = 1:192 #extra row and col is because surf does not display last row and column as a pixel square otherwise
  col = 1:128

  global last_row
  last_row_actual = last_row + 1
  rows = last_row_actual*2

  data_reshaped = reshape(data_masked,(128,rows,number_of_frames))
  data_sum_frames = sum(data_reshaped,3)

  data_image[1:128,1:last_row_actual]      = data_sum_frames(1:128,1:2:rows)
  data_image[1:128,last_row_actual+1:rows] = data_sum_frames(1:128,2:2:rows)
  data_image[:,1:last_row_actual]          = reverse(data_image[:,1:last_row_actual],dims=2)

  # mask high DCR pixel
  load DCR_matrix.mat
  #pixel_val = (data_image.*DCR_matrix)';
  pixel_val = data_image'

  fig = heatmap(pixel_val)
  fig = Figure()
  ax, hm = heatmap(fig[1,1], pixel_val, colormap=:viridis, axis=(;cscale=log10))
  Colorbar(fig[1,2], hm)
  display(fig)
end


function plotIntensityImageByteMode(obj,data,number_of_frames)
  row = 1:192 #extra row and col is because surf does not display last row and column as a pixel square otherwise
  col = 1:128

  global last_row
  last_row_actual = last_row + 1
  rows = last_row_actual*2

  data_reshaped = reshape(data,(128,rows,number_of_frames))
  data_sum_frames = sum(data_reshaped,3)

  data_image[1:128,1:last_row_actual     ]  = data_sum_frames(1:128,1:2:rows)
  data_image[1:128,last_row_actual+1:rows]  = data_sum_frames(1:128,2:2:rows)
  data_image[:,1:last_row_actual         ]  = reverse(data_image[:,1:last_row_actual],dims=2)

  # mask high DCR pixel
  load DCR_matrix.mat
  #pixel_val = (data_image.*DCR_matrix)';
  pixel_val = data_image'

  fig = heatmap(pixel_val)
  fig = Figure()
  ax, hm = heatmap(fig[1,1], pixel_val, colormap=:viridis, axis=(;cscale=log10))
  Colorbar(fig[1,2], hm)
  display(fig)

end

function plotG2Tint(obj,data)

subplot(1,2,1);
plot(0:15,data(1,:));
ylabel('g2');
xlabel('tau');

g2_mean = mean(data,1);
g2_std = std(data,0,1);
subplot(1,2,2);
snr = (g2_mean-1)./g2_std;
plot(0:15,snr);
ylabel('SNR');
xlabel('tau');
ylim([0 600]);

drawnow;
end

# --------------------------------------------------------------------
# Plotter runner
# --------------------------------------------------------------------

"""
The plotter is ran as a separate task to prevent blocking the acquisition from QC. It receives the frame over a channel and displays them in different layous based on an enum received if existent.
Same architecture is used for the HDF5 collector [@hdf5-collector].
"""

function plotter_init(::Type{T}; description=Union{String, Nothing}=nothing)::Tuple{Task, Channel{T}} where T

  channel = Channel{T}(1) # SPSC channel

  @info "Spawning plotter thread"
  task = @spawn plotter_thread(description, channel);

  task, channel
end

function plotter_thread(description, channel::Channel{T}) where T
  while isopen(channel)
    # Receive data from channel
    # Only read when ready to avoid
  end
end
