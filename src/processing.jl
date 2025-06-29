#=
function check_g2_pixel_component_stream()
  pixels = 2*(last_row+1)*64

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

=#

# --------------------------------------------------
# Qualify pixel reads to float + nan boxing based on codes
# --------------------------------------------------

function filter_code(tdc_pixels::Union{Array{UInt8}, Array{UInt16}}; decode_mode::DecodeMode=Decoded)
  nan_boxed_pixels = similar(tdc_pixels, Float32)
  # 0x04 is the code for missing data
  nan_boxed_pixels =
    if decode_mode == Decoded
        if tdc_pixels isa Array{UInt16}
            map(x-> if(x==0xffc) missing else Float32(x) end, tdc_pixels)
        else
            map(x-> if(x==0xfc) missing else Float32(x) end, tdc_pixels)
        end
    else
        map(x-> if(x==0x04) missing else Float32(x) end, tdc_pixels)
    end
  nan_boxed_pixels
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

function twos_complement_branching(data::T, size=nothing)::T where T <: Union{UInt8, UInt16}
  if size === nothing
    size = sizeof(data) * 8
  end
  masked_data = data&(1<<size - 1)
  if masked_data == 0
    masked_data = 1<<size
  end
  (1<<size) - masked_data
end

function twos_complement_instr(data::T, bits=nothing)::T where T <: Union{UInt8, UInt16}
  shamt = 8 * sizeof(data) - bits
  twos_complement_shifted = -reinterpret(signed(T), data << shamt)
  twos_complement_shifted_unsigned = reinterpret(T, twos_complement_shifted)
  twos_complement_shifted_unsigned >> shamt
end

function decode_frame_data(tdc_pixels::Array{UInt16})
  #data_decoded = map(pixel -> twos_complement_instr(pixel, 12), tdc_pixels)
  data_decoded_coarse = map(pixel -> twos_complement_instr(pixel>>3, 9), tdc_pixels)
  data_decoded_fine = map(pixel -> ~(pixel & 0x7), tdc_pixels)
  data_decoded = map((coarse, fine) -> coarse<<3 | fine, zip(data_decoded_coarse, data_decoded_fine))
  data_decoded
end
