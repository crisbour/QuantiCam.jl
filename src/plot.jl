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

function plotPixelHistogram(data,number_of_frames,pixel_x_coord,pixel_y_coord)
  # data_masked = bitand(data,4095);
  # data_masked(bitand(data_masked,4088)==0) = 4096;
  # data_decoded = 4096 - data_masked;
  ##
  data_masked_coarse = bitshift(bitand(data, hex2dec('ff8')), -3);
  data_masked_coarse(data_masked_coarse==0) = 512;
  data_decoded_coarse = 512 - data_masked_coarse;

  # Fine bits
  data_decoded_fine = bitxor(bitand(data, hex2dec('7')),hex2dec('7'));

  # Combined
  data_decoded = bitor(bitshift(data_decoded_coarse, 3), data_decoded_fine);
  ##

  row = 1:193; #extra row and col is because surf does not display last row and column as a pixel square otherwise
  col = 1:129;

  data_reshaped = reshape(data_decoded,[128,192,number_of_frames]);

  data_image(1:128,1:96,1:number_of_frames) = data_reshaped(1:128,1:2:192,1:number_of_frames);
  data_image(1:128,97:192,1:number_of_frames) = data_reshaped(1:128,2:2:192,1:number_of_frames);
  data_image(:,1:96,:) = flip(data_image(:,1:96,:),2);

  pixel_val = rot90(mean(data_image,3));
  pixel_val(193,:) = 0;
  pixel_val(:,129) = 0;

  pixel_data(1:number_of_frames) = data_image(pixel_x_coord,pixel_y_coord,:);
  test_column_data = data_image(128,8,:);

  figure(1);
  histogram(test_column_data,-0.5:4095.5);

  # figure(2);
  # histogram(pixel_data,4096);

  # figure(3);
  # surf(col,row,pixel_val);
  # colormap(gray);
  # colorbar;
  # view(2);
  # axis equal;
  data_decoded
end

function plotIntensityImageByteMode(data,number_of_frames)
  row = 1:192; #extra row and col is because surf does not display last row and column as a pixel square otherwise
  col = 1:128;

  global last_row
  last_row_actual = last_row + 1
  rows = last_row_actual*2

  data_reshaped = reshape(data,[128,rows,number_of_frames])
  data_sum_frames = sum(data_reshaped,3)

  data_image(1:128,1:last_row_actual) = data_sum_frames(1:128,1:2:rows)
  data_image(1:128,last_row_actual+1:rows) = data_sum_frames(1:128,2:2:rows)
  data_image(:,1:last_row_actual) = flip(data_image(:,1:last_row_actual),2)

  # mask high DCR pixel
  load DCR_matrix.mat
  #pixel_val = (data_image.*DCR_matrix)';
  pixel_val = data_image'

  h = imagesc(pixel_val);
  axis image
  colormap(gray)
  colorbar;
  caxis([0 25])
  drawnow;
end
