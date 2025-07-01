# -------------------------------------
# Setup FPGA, Sensor and Configs
# -------------------------------------

export init_board!, config_sensor, reload_config, get_firmware_rev!

# Initialize FPGA with bitfile provided and settings in FPGA
function init_board!(qc::QCBoard)
  @info "Opal Kelly to API Comms setup in progress..."

  # The following procedure is to open communications with the Opal Kelly
  # generic FPGA platform.
  # - qc.fpga = FPGA(bitfile)
  # Load the correct register bank:
  # - qc.bank = QUANTICAM_BANK
  # Thse have been moved directly in the QCBoard constructor
  #qc = QCBoard(bitfile, QUANTICAM_BANK)

  # Open library, connect to FPGA and load bitfile
  OpalKelly.init_board!(qc.fpga)

  OpalKelly.set_timeout(qc.fpga, 1000) # Set timeout to 1 second

  get_firmware_rev!(qc)

  # Set voltage levels for sensor to work
  sensor_connect(qc)

  config_sensor(qc)
end


# Configure Sensor
function config_sensor(qc::QCBoard)
  #Configures the sensor serial interface
  tcspc = qc.config.tcspc
  second_photon_mode_enable = qc.config.second_photon_mode_enable

  exposure_time = 100 * qc.config.exposure_time ÷ 2 #exposure in 20ns steps

  # Compose byte vector in UInt32 slices, assumming little endian
  row_enables = reinterpret(UInt32, hex2bytes(qc.config.row_enables))
  col_enables = reinterpret(UInt32, hex2bytes(qc.config.col_enables))

  if (!qc.config.tcspc && qc.config.pixel_mode==TCSPC)
    @warn "Pixel readout is set to TCSPC, but sensor is configure as PHOTON_CNT => Configure sensor in TCSPC mode"
    qc.config.tcspc = true
  end
  if (qc.config.tcspc && qc.config.pixel_mode==PhotonCount)
    @warn "Pixel readout is set to PhotonCount, but sensor is configure as TCSPC => Configure sensor in PHOTON_CNT mode"
    qc.config.tcspc = false
  end

  @info "Initialize logic parameters necessary to interact with the sensor"
  set_wire_in_value(qc, STOP_CLK_DIVIDER,      qc.config.stop_clk_divider           )
  set_wire_in_value(qc, LAST_ROW,              qc.config.last_row                   )
  set_wire_in_value(qc, BYTE_SELECT,           UInt32(qc.config.byte_select      )  )
  set_wire_in_value(qc, BYTE_SELECT_MSB,       UInt32(qc.config.byte_select_msb  )  )
  set_wire_in_value(qc, PISO_READOUT_DELAY,    qc.config.piso_readout_delay         )
  set_wire_in_value(qc, STOP_SOURCE_SELECT,    UInt32(qc.config.stop_source_select) )
  set_wire_in_value(qc, SYNC_DELAY_CLK_CYCLES, qc.config.sync_delay_clk_cycles      )

  set_wire_in_value(qc, ENABLE_GATING,         UInt32(qc.config.enable_gating)      )
  set_wire_in_value(qc, DELAY_FROM_STOP,       UInt32(qc.config.delay)              )
  set_wire_in_value(qc, GATE_WIDTH,            UInt32(qc.config.gate_width)         )

  # Debugging settings
  set_wire_in_value(qc, ERROR_BACKTRACE,       UInt32(qc.config.error_backtrace)    )
  set_wire_in_value(qc, ENABLE_ERROR_TEST,     UInt32(qc.config.error_test)         )
  set_wire_in_value(qc, FIFO_RDOUT_TEST,       UInt32(qc.config.fifo_rdout_test)    )

  @info "Reset sensor and set parameters for the MODE of use"
  activate_trigger_in(qc, CHIP_RST)
  activate_trigger_in(qc, PIX_RST)

  set_wire_in_value(qc, ROW_ENABLES_0, row_enables[1])
  set_wire_in_value(qc, ROW_ENABLES_1, row_enables[2])
  set_wire_in_value(qc, ROW_ENABLES_2, row_enables[3])
  set_wire_in_value(qc, ROW_ENABLES_3, row_enables[4])
  set_wire_in_value(qc, ROW_ENABLES_4, row_enables[5])
  set_wire_in_value(qc, ROW_ENABLES_5, row_enables[6])

  set_wire_in_value(qc, COL_ENABLES_0, col_enables[1])
  set_wire_in_value(qc, COL_ENABLES_1, col_enables[2])
  set_wire_in_value(qc, COL_ENABLES_2, col_enables[3])
  set_wire_in_value(qc, COL_ENABLES_3, col_enables[4])

  set_wire_in_value(qc, TCSPC_MODE                 , UInt32(qc.config.tcspc)           )
  set_wire_in_value(qc, PIXEL_MODE                 , UInt32(qc.config.pixel_mode)      )
  set_wire_in_value(qc, DECODE_MODE                , UInt32(qc.config.decode_mode)     )
  set_wire_in_value(qc, OUTPUT_MODE                , UInt32(qc.config.output_mode)     )
  set_wire_in_value(qc, GLOBAL_SHUTTER_MODE        , UInt32(qc.config.gs_rs_mode)      ) # 0 for rolling shutter, 1 for global shutter
  set_wire_in_value(qc, TEST_COL_ENABLE            , UInt32(qc.config.test_col_enable) )
  set_wire_in_value(qc, TEST_COL_SECOND_PHOTON_MODE, UInt32(second_photon_mode_enable) )
  set_wire_in_value(qc, EXPOSURE_TIME              , exposure_time                     )
  #wireindata(obj.okComms,obj.bank,FRAME_NUMBER,frame_number)
  sleep(0.5)

  activate_trigger_in(qc, CONFIG_SI_TRIGGER)
  sleep(1)
  @info "Sensor configured"
end

# connect the sensor
function sensor_connect(qc::QCBoard)
  # Check obj not already connected.
  if qc.sensor_status == Connected
    @warn "Sensor already connected!"
  else
    qc.sensor_status = Connected

    #sys_rst
    activate_trigger_in(qc, SYS_RST)

    # set voltages
    set_voltage(qc, VQ,   1.1 )
    set_voltage(qc, VNBL, 1.1 )
    set_voltage(qc, VEB,  1.2 )
    sleep(0.5)
    set_voltage(qc, VBD,  6   )
    sleep(0.5)
    set_voltage(qc, VBD,  9   )
    sleep(0.5)
    set_voltage(qc, VBD,  15.6)

    @info "Waiting on voltages to stabilize"
    sleep(5)

    @info "Connected to Sensor"
  end
end


# Disconnect the OK
function sensor_disconnect(qc::QCBoard)
  # Check obj not already connected.
  if qc.sensor_status == Disconnected
      @warn "Sensor already disconnected!"
      return
  end

  # Pulse RSTN low

  # Turn off operating voltages
  set_voltage(qc, VEB,  0)
  set_voltage(qc, VQ,   0)
  set_voltage(qc, VNBL, 0)
  set_voltage(qc, VBD,  15.6)
  sleep(0.5)
  set_voltage(qc, VBD,  9)
  sleep(0.5)
  set_voltage(qc, VBD,  6)
  sleep(0.5)
  set_voltage(qc, VBD,  3)
  sleep(0.5)
  set_voltage(qc, VBD,  0)


  # Set SensorStatus = 'Disconnected'
  @info "Disconnected from Sensor"
  qc.sensor_status = Disconnected # Other allowed value is 'Connected'
end

# -------------------------------------------------------------------
# Utils
# -------------------------------------------------------------------

function reload_config(qc::QCBoard, config_path)
  qc.config = deser_json(QCConfig, read(config_path))
end

function get_firmware_rev!(qc::QCBoard)
  # Get firmware revision
  rev = get_wire_out_value(qc, FW_VERSION);
  # Parse UInt32 into Major.Minor.Patch format from bytes 2,1,0
  major = (rev >> 16) & 0xFF
  minor = (rev >> 8) & 0xFF
  patch = rev & 0xFF
  rev = string(major, ".", minor, ".", patch)
  qc.firmware_revision = rev
  @info "Firmware revision: $rev"
end

# -------------------------------------
# TODO: Implement functions not directly used by QuantiCam
# -------------------------------------
#function set_ok_PLL(obj, pll_number, p, q, enable)
#  if p < 6
#      error("P parameter must be greater than 6")
#  end
#  if p < 2053
#      error("P parameter must be smaller than 2053")
#  end
#  if q < 2
#      error("Q parameter must be greater than 2")
#  end
#  if q < 257
#      error("Q parameter must be smaller than 257")
#  end
#
#  if obj.which_OK_PLL=="PLL22150"
#      set_vco_parameters(obj.pll, p, q)
#  else
#      if obj.which_OK_PLL=="PLL22393"
#          obj.pll.set_pll_parameters(pll_number, p, q)
#      end
#  end
#end
#
#function init_ok_PLL(obj)
#    obj.PLL = okPLL22150()
#    if get_pll22150_configuration(obj.okCommsIn, obj.PLL) == 0
#        obj.which_PLL = "PLL22150"
#    else
#        obj.PLL = okPLL22393()
#        if get_pll22393_configuration(obj.okCommsIn, obj.PLL) == 0
#            obj.which_PLL = "PLL22393"
#        end
#    end
#end
