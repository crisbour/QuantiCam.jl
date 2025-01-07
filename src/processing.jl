function check_frame_stream()
  last_row = 95
  pixels = 2*(last_row+1)*128

  #TODO: read from HDF5 file or channel
  data_read = read(channel)

  number_of_frames = data_read.number_of_frames
  data = data_read.data

  #look for start of the first complete frame (first transfer will probably be a
  #partial frame which will skew all the other frames by a certain number of
  #pixels
  for index = 1:number_of_frames*pixels
      if(data(index) == 0 && data(index+1) == 0 && data(index+2) == 0 && data(index + pixels - 256) == 0 && data(index + pixels - 255) == 95 && data(index + pixels - 254) == 0)
          start_index = index+1;
          break
      end
  end

  frame_data = data(start_index:end)
  remaining_frames = floor(size(frame_data,1)/pixels)

  #check for frame contiguousness
  for i = 1:remaining_frames
      frame_number_header_byte2 = frame_data((i-1)*pixels+4)
      frame_number_header_byte1 = frame_data((i-1)*pixels+3)
      frame_number_header(i) = bitor(bitshift(frame_number_header_byte2, 8), frame_number_header_byte1)
  end

  #if there is more than one frame difference between two frames flag the
  #frame with a 1, otherwise the frame is flagged with a zero
  for i = 1:remaining_frames-1
      if((frame_number_header(i+1) - frame_number_header(i)) == 1 || (frame_number_header(i+1) - frame_number_header(i)) == 2^15-1)
          frame_skip(i) = 0
      else
          frame_skip(i) = 1
      end
  end

  figure(1)
  #plots skipped frames (1 means there is more than a difference of 1 frame
  #between a frame and the next
  plot(frame_skip(1:end))

  figure(2)
  #display frames
  for i = 1:remaining_frames
      frame = uint8(frame_data((i-1)*pixels+1:i*pixels))
      plotIntensityImageByteMode(frame,1)
  end
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

function check_g2_pixel_component_stream()
  pixels = 2*(last_row+1)*64

  #reads in file
  fclose all
  fileid = fopen("g2_pixel_data.bin","r")
  data_read = fread(fileid,"uint16")
  fclose all

  number_of_tint = data_read(1)
  data_8bits = data_read(2:end)

  data_byte_1 = uint32(data_8bits(1:4:end))
  data_byte_2 = uint32(data_8bits(2:4:end))
  data_byte_3 = uint32(data_8bits(3:4:end))
  data_byte_4 = uint32(data_8bits(4:4:end))
  data_16bits_1 = bitor(bitshift(data_byte_2, 8), data_byte_1)
  data_16bits_2 = bitor(bitshift(data_byte_4, 8), data_byte_3)
  data_32bits = bitor(bitshift(data_16bits_2, 16), data_16bits_1)
  clear data_read data_16bits_1 data_16bits_2 data_8bits data_byte_1 data_byte_2 data_byte_3 data_byte_4
  #numerator or denominator component
  component_flag = bitshift(bitand(data_32bits,2^31),-31)
  row_header = bitshift(bitand(data_32bits,1073217536),-19)

  #look for start of the first complete frame (first transfer will probably be a
  #partial frame which will skew all the other frames by a certain number of
  #pixels
  for index = 1:number_of_tint*pixels*17
      if(component_flag(index) == 1 && row_header(index) == 1)
          start_index = index
          break
      end
  end
  start_index = 1
  for i = 1:number_of_tint*pixels*17
      if(component_flag(i) == 1)
          data_noheader(i) = bitand(data_32bits(i),2^19-1)
      else
          data_noheader(i) = bitand(data_32bits(i),2^27-1)
      end
  end

  g2_component_data = data_noheader(start_index:end)
  clear data_noheader
  remaining_tint = floor(size(g2_component_data,2)/pixels/17)

  index = 0
  for i = 1:remaining_tint
      for j = 1:last_row+1 #rows
          for ch = 1:17
              for k = 1:128 #columns
                  index = index+1
                  tint_components(i,j,k,ch) = double(g2_component_data(index))
              end
          end
      end
  end

  tint_components_pixels = reshape(tint_components,[remaining_tint,2*(last_row+1)*64,17])

  for i = 1:remaining_tint
      for j = 1:size(tint_components_pixels,2)
          g2_curves(i,j,:) = double(tint_components_pixels(i,j,2:17).*2048/double(tint_components_pixels(i,j,1)^2))
      end
  end

  plot(0:15,squeeze(g2_curves(1,1,:)))
  xlabel("tau")
  ylabel("g2")

end

function check_g2_tint()
  last_row = 95;
  pixels = 2*(last_row+1)*128;

  #reads in file
  fclose all;
  fileid = fopen("g2_data.bin:","r");
  data_read = fread(fileid,"uint16");
  fclose all;
  number_of_tint = data_read(1);
  data_8bits = data_read(2:end);

  data_byte_1 = uint32(data_8bits(1:4:end));
  data_byte_2 = uint32(data_8bits(2:4:end));
  data_byte_3 = uint32(data_8bits(3:4:end));
  data_byte_4 = uint32(data_8bits(4:4:end));
  data_16bits_1 = bitor(bitshift(data_byte_2, 8), data_byte_1);
  data_16bits_2 = bitor(bitshift(data_byte_4, 8), data_byte_3);
  data_32bits = bitor(bitshift(data_16bits_2, 16), data_16bits_1);
  header = bitshift(bitand(data_32bits,4293918720),-20);
  data_noheader = bitand(data_32bits,2^20-1);
  g2 = double(data_noheader)/double(2^18);

  #look for start of the first complete frame (first transfer will probably be a
  #partial frame which will skew all the other frames by a certain number of
  #pixels
  for index = 1:number_of_tint
      if(header(index) == header(index+1:index+15))
          start_index = index;
          break
      end
  end

  remaining_tint = floor(size(g2(start_index:end),1)/16);

  figure(1);
  #display frames
  pause on
  for i = 1:remaining_tint
      g2_curve = g2((i-1)*16+1:16*i);
      plotG2Tint(g2_curve);
      ylim([-1 4]);
      drawnow;
      pause(0.5);
  end
end

function data_image = decodeFrameData(data,number_of_frames)
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

  # pixel_val = data_image';
  # pixel_val(193,:) = 0;
  # pixel_val(:,129) = 0;
  #
  # pixel_data(1:number_of_frames) = data_image(pixel_x_coord,pixel_y_coord,:);
  # test_column_data = data_image(128,8,:);
  #
  # figure(1);
  # histogram(test_column_data,-0.5:4095.5);
  #
  # figure(2);
  # histogram(pixel_data,4096);
  #
  # figure(3);
  # surf(col,row,pixel_val);
  # colormap(gray);
  # colorbar;
  # view(2);
  # axis equal;

end


function plotIntensityImageByteMode(data,number_of_frames)
  row = 1:192; #extra row and col is because surf does not display last row and column as a pixel square otherwise
  col = 1:128;

  global last_row
  last_row_actual = last_row + 1;
  rows = last_row_actual*2;

  data_reshaped = reshape(data,[128,rows,number_of_frames]);
  data_sum_frames = sum(data_reshaped,3);

  data_image(1:128,1:last_row_actual) = data_sum_frames(1:128,1:2:rows);
  data_image(1:128,last_row_actual+1:rows) = data_sum_frames(1:128,2:2:rows);
  data_image(:,1:last_row_actual) = flip(data_image(:,1:last_row_actual),2);

  # mask high DCR pixel
  load DCR_matrix.mat
  #pixel_val = (data_image.*DCR_matrix)';
  pixel_val = data_image';

  h = imagesc(pixel_val);
  axis image
  colormap(gray)
  colorbar;
  caxis([0 25])
  drawnow;
end


function data_decoded = plotPixelHistogram(data,number_of_frames,pixel_x_coord,pixel_y_coord)
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

end


