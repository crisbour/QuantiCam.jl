# -------------------------------------
# Setup FPGA, Sensor and Configs
# -------------------------------------

export init_board!, config_sensor, set_config!, new_config!, set_phase!, set_delay!

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

    OpalKelly.set_timeout(qc.fpga, 2000) # Set timeout to 2 second

    get_firmware_rev!(qc)

    # Set voltage levels for sensor to work
    sensor_connect(qc)

    config_sensor(qc)
end


# Configure Sensor
function config_sensor(qc::QCBoard)
    if qc.sensor_status != SensorStatus.Connected
        @error "Sensor not connected, cannot configure"
        return
    end

    @debug "Configuring Sensor with config \"$(qc.config.config_name)\" from path $(qc.config.config_path)"

    # Calculate exposure time in clock cycles
    exposure_time = 100 * qc.config.exposure_time #exposure in 10ns steps

    # Compose byte vector in UInt32 slices, assumming little endian
    row_enables = reinterpret(UInt32, hex2bytes(qc.config.row_enables))
    col_enables = reinterpret(UInt32, hex2bytes(qc.config.col_enables))

    if (!qc.config.tcspc && qc.config.pixel_mode == PixelMode.TCSPC)
        @warn "Pixel readout is set to TCSPC, but sensor is configure as PHOTON_CNT => Configure sensor in TCSPC mode"
        qc.config.tcspc = true
    end
    if (qc.config.tcspc && qc.config.pixel_mode == PixelMode.PhotonCount)
        @warn "Pixel readout is set to PhotonCount, but sensor is configure as TCSPC => Configure sensor in PHOTON_CNT mode"
        qc.config.tcspc = false
    end

    # WARN: Not sure why, but these flags are reversed for the sensor configuration
    tcspc = qc.config.tcspc == 0 ? 1 : qc.config.tcspc == 1 ? 0 : qc.config.tcspc
    second_photon_mode_enable =
        qc.config.second_photon_mode_enable == 0 ? 1 :
        qc.config.second_photon_mode_enable == 1 ? 0 : qc.config.second_photon_mode_enable

    # Based on firmware version, change division and phase accordingly
    stop_clk_divider = 0
    if qc.firmware_revision >= FWRevision(2,0,0)
        # New FW version, phase offset is now in a separate register
        set_wire_in_value(qc, LASER_STOP_PHASE, UInt32(round(qc.config.phase_offset * 1000))) # Phase offset in mdeg
        @debug "Setting phase offset to $(qc.config.phase_offset) degrees"
        stop_clk_divider = qc.config.stop_clk_divider
    else
        # Old FW version, phase offset is set via the sync_delay_clk_cycles
        set_wire_in_value(qc, SYNC_DELAY_CLK_CYCLES, qc.config.sync_delay_clk_cycles)
        if qc.config.phase_offset != 0.0
            @warn "Phase offset setting not supported in firmware versions <= 1.9.x, use sync_delay_clk_cycles instead"
        end
        if (stop_clk_divider != 0)
            if (qc.config.stop_clk_divider % 2 != 0)
                @warn "stop_clk_divider must be even for firmware versions <= 1.9.x, rounding down"
            end
            stop_clk_divider = qc.config.stop_clk_divider ÷ 2 - 1
        end
    end

    @debug "Initialize logic parameters necessary to interact with the sensor"
    set_wire_in_value(qc, STOP_CLK_DIVIDER  , UInt32(stop_clk_divider)            )
    set_wire_in_value(qc, LAST_ROW          , qc.config.last_row                  )
    set_wire_in_value(qc, BYTE_SELECT       , UInt32(qc.config.byte_select)       )
    set_wire_in_value(qc, BYTE_SELECT_MSB   , UInt32(qc.config.byte_select_msb)   )
    set_wire_in_value(qc, PISO_READOUT_DELAY, qc.config.piso_readout_delay        )
    set_wire_in_value(qc, STOP_SOURCE_SELECT, UInt32(qc.config.stop_source_select))
    set_wire_in_value(qc, HEADER_EN         , UInt32(qc.config.header_en)         )

    set_wire_in_value(qc, ENABLE_GATING     , UInt32(qc.config.enable_gating)     )
    set_wire_in_value(qc, DELAY_FROM_STOP   , UInt32(qc.config.gate_delay)             )
    set_wire_in_value(qc, GATE_WIDTH        , UInt32(qc.config.gate_width)        )

    # Debugging settings
    set_wire_in_value(qc, ERROR_BACKTRACE   , UInt32(qc.config.error_backtrace)   )
    set_wire_in_value(qc, ENABLE_ERROR_TEST , UInt32(qc.config.error_test)        )
    set_wire_in_value(qc, FIFO_RDOUT_TEST   , UInt32(qc.config.fifo_rdout_test)   )

    @debug "Reset sensor and set parameters for the MODE of use"
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

    set_wire_in_value(qc, TCSPC_MODE, UInt32(tcspc))
    set_wire_in_value(qc, PIXEL_MODE, UInt32(qc.config.pixel_mode))
    set_wire_in_value(qc, DECODE_MODE, UInt32(qc.config.decode_mode))
    set_wire_in_value(qc, OUTPUT_MODE, UInt32(qc.config.output_mode))
    set_wire_in_value(qc, GLOBAL_SHUTTER_MODE, UInt32(qc.config.gs_rs_mode)) # 0 for rolling shutter, 1 for global shutter
    set_wire_in_value(qc, TEST_COL_ENABLE, UInt32(qc.config.test_col_enable))
    set_wire_in_value(qc, TEST_COL_SECOND_PHOTON_MODE, UInt32(second_photon_mode_enable))
    set_wire_in_value(qc, EXPOSURE_TIME, exposure_time)
    #wireindata(obj.okComms,obj.bank,FRAME_NUMBER,frame_number)

    activate_trigger_in(qc, CONFIG_SI_TRIGGER)

    if qc.firmware_revision >= FWRevision(2,0,0)
        activate_trigger_in(qc, CLKS_CONFIG_TRIGGER)
        div_fixed = get_wire_out_value(qc, STOP_CLK_DIVIDER_RESP)
        div_float = Float32(Int(div_fixed>>3)) / 32.0
    else
        div_float = Float32(Int(2*(qc.config.stop_clk_divider+1)))
    end

    @info "Sensor configured with config \"$(qc.config.config_name)\" and STOP_CLK=$(100 / div_float) MHz and phase: $(qc.config.phase_offset) degrees"
end

# connect the sensor
function sensor_connect(qc::QCBoard)
    # Check obj not already connected.
    if qc.sensor_status == SensorStatus.Connected
        @warn "Sensor already connected!"
    else
        qc.sensor_status = SensorStatus.Connected

        #sys_rst
        activate_trigger_in(qc, SYS_RST)

        # set voltages
        set_voltage(qc, VQ, 1.1) # Vquence
        set_voltage(qc, VNBL, 1.1) # VDDOSC
        set_voltage(qc, VEB, 1.2) # VDD
        sleep(0.1)
        set_voltage(qc, VBD, 6)
        sleep(0.1)
        set_voltage(qc, VBD, 9)
        sleep(0.1)
        set_voltage(qc, VBD, 15.6) # VHV

        @info "Waiting on voltages to stabilize"
        sleep(1)

        @info "Connected to Sensor"
    end
end


# Disconnect the OK
function sensor_disconnect(qc::QCBoard)
    # Check obj not already connected.
    if qc.sensor_status == SensorStatus.Disconnected
        @warn "Sensor already disconnected!"
        return
    end

    # Pulse RSTN low

    # Turn off operating voltages
    set_voltage(qc, VEB, 0)
    set_voltage(qc, VQ, 0)
    set_voltage(qc, VNBL, 0)
    set_voltage(qc, VBD, 15.6)
    sleep(0.1)
    set_voltage(qc, VBD, 9)
    sleep(0.1)
    set_voltage(qc, VBD, 6)
    sleep(0.1)
    set_voltage(qc, VBD, 3)
    sleep(0.1)
    set_voltage(qc, VBD, 0)


    # Set SensorStatus = 'Disconnected'
    @info "Disconnected from Sensor"
    qc.sensor_status = SensorStatus.Disconnected # Other allowed value is 'Connected'
end

function is_connected(qc::QCBoard)::Bool
    return qc.sensor_status == SensorStatus.Connected
end

# -------------------------------------------------------------------
# Utils
# -------------------------------------------------------------------
function new_config!(qc::QCBoard, name::String, config_path::String)
    # Check config_path is a valid file
    if !isfile(config_path)
        @error "Config path $(config_path) is not a valid file"
        return
    end

    # Load the config from the file
    config = deser_json(QCConfig, read(config_path))
    config.config_name = name
    config.config_path = config_path

    config_idx = findfirst(p -> p.config_name == name, qc.configs)
    if config_idx !== nothing
        @warn "Config with name \"$(name)\" at idx=$config_idx already exists => Overwritting"
        qc.configs[config_idx] = config
    else
        push!(qc.configs, config)
        config_idx = length(qc.configs)
    end

    if qc.config.config_name == name
        @info "Reloading active config"
        set_config!(qc, name)
    end
end

function new_config!(qc::QCBoard, config_path::String)
    new_config!(qc, "default", config_path)
end

function set_config!(qc::QCBoard, name::String)
    # Find the config with the given name
    config_idx = findfirst(p -> p.config_name == name, qc.configs)
    if config_idx === nothing
        @error "Config with name $(name) not found"
        return
    end

    prev_name = qc.config.config_name
    dirty = qc.configs[config_idx].dirty
    qc.configs[config_idx].dirty = false
    qc.config = qc.configs[config_idx]

    if qc.sensor_status == SensorStatus.Connected && (dirty || prev_name != qc.config.config_name)
        @debug "Configuring sensor with config $(qc.config.config_name)"
        config_sensor(qc)
    elseif qc.sensor_status != SensorStatus.Connected
        @warn "Sensor not connected, cannot reconfigure"
    end
end

"""
    set_phase!(qc::QCBoard, ϕ::Real)
Set delay of the LASER_STOP from the SPAD_STOP, in order to improve histogram width for a certain depth
# Arguemnts:
- `qc::QCBoard`: The QCBoard instance
- `ϕ::Real`: Phase shift in degrees, ϕ∈[0, 360]
"""
function set_phase!(qc::QCBoard, ϕ::Real)::Float64
    for config in qc.configs
        change_config!(qc, config.config_name, :phase_offset, Float32(ϕ))
    end
    if qc.sensor_status != SensorStatus.Connected
        @warn "Sensor not connected, cannot reconfigure"
        return
    end
    # Based on firmware version, change division and phase accordingly
    if qc.firmware_revision >= FWRevision(2,0,0)
        # New FW version, phase offset is now in a separate register
        written_phase_offset = Float64(round(qc.config.phase_offset * 1000)) / 1000
        set_wire_in_value(qc, LASER_STOP_PHASE, UInt32(round(qc.config.phase_offset * 1000))) # Phase offset in mdeg
        @debug "Setting phase offset to $(written_phase_offset) degrees"
        activate_trigger_in(qc, CLKS_CONFIG_TRIGGER)
        return written_phase_offset
    else
        # Old FW version, phase offset is set via the sync_delay_clk_cycles
        @error "Phase offset setting not supported in firmware versions < 2.0.0, use sync_delay_clk_cycles instead"
        return NaN
    end
end

"""
    set_delay!(qc::QCBoard, ΔT::Real)
Set delay of the LASER_STOP from the SPAD_STOP, in order to improve histogram width for a certain depth
# Arguemnts:
- `qc::QCBoard`: The QCBoard instance
- `ΔT::Real`: Delay in ns
"""
function set_delay!(qc::QCBoard, ΔT::Real)::Float64
    if qc.sensor_status != SensorStatus.Connected
        @warn "Sensor not connected, cannot reconfigure"
        return
    end
    div_fixed = get_wire_out_value(qc, STOP_CLK_DIVIDER_RESP)
    div_float = Float32(Int(div_fixed>>3)) / 32.0
    stop_freq = 100e6 / div_float # in Hz
    stop_period = 1 / stop_freq # in s
    phase = (ΔT * 1e-9 / stop_period) * 360.0
    written_phase = set_phase!(qc, phase)
    written_delay = (written_phase / 360.0) * stop_period * 1e9 # in ns
    return written_delay
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
