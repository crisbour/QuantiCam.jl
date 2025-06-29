using Serde
using ResultTypes

export QuantiCamError

# --------------------------------------------------
# Setup necessary and helper types
# --------------------------------------------------

@enum PixelMode begin
    Raw         = 0
    TCSPC       = 1
    PhotonCount = 2
end
@enum DecodeMode begin
    Encoded = 0
    Partial = 1
    Decoded = 2
end
@enum OutputMode begin
    Standard    = 0
    Multievents = 1
    Histogram   = 2
    Sketch      = 3
end

@enum SensorStatus begin
  Disconnected
  Connected
end

struct BankInfo
  addr::UInt8
  size::UInt8
  bit::UInt8
end

function Base.convert(::Type{Tuple}, x::BankInfo)
  # Initialize state with current px and py values of IterPoints
  return (x.addr, x.size, x.bit)
end

@enum BankEnum begin
VBD
VEB
VQ
VNBL
VBD_OUT
VEB_OUT
VQ_OUT
VNBL_OUT
GLOBAL_SHUTTER_MODE
TEST_COL_ENABLE
TEST_COL_SECOND_PHOTON_MODE
TCSPC_MODE
FIFO_RDOUT_TEST
PIXEL_MODE
DECODE_MODE
OUTPUT_MODE
HEADER_EN
ERROR_BACKTRACE
ENABLE_ERROR_TEST
FRAME_NUMBER
EXPOSURE_TIME
ROW_ENABLES_0
ROW_ENABLES_1
ROW_ENABLES_2
ROW_ENABLES_3
ROW_ENABLES_4
ROW_ENABLES_5
COL_ENABLES_0
COL_ENABLES_1
COL_ENABLES_2
COL_ENABLES_3
CONFIG_SI_TRIGGER
SYS_RST
START_CAPTURE_TRIGGER
FIFO_RST
CHIP_RST
PIX_RST
ERROR_RST
TRIGGER_END_CAPTURE
PROGRESETDAC
PROGSETDAC
EP_READY
WR_DATA_COUNT
RD_DATA_COUNT
FIFO_OUT
ERROR_FIFO
ENABLE_GATING
DELAY_FROM_STOP
GATE_WIDTH
ENABLE_SCAN_WINDOW
STOP_CLK_DIVIDER
LAST_ROW
BYTE_SELECT
BYTE_SELECT_MSB
PISO_READOUT_DELAY
STOP_SOURCE_SELECT
SYNC_DELAY_CLK_CYCLES
FW_VERSION
ERROR_READY
end

 @serde @default_value mutable struct QCConfig
  # Config filename if derived from JSON
  config_path::String                 | ""

  # Constants
  rows::Unsigned                      | 192
  cols::Unsigned                      | 128
  # TODO: Add assertion frame_size = | rows*cols or replace field with fn call
  frame_size::Unsigned                | 24576 #rows*cols

  # Setup parameters
  # 192 rows, 128 columns, hex string expressed in little-endian: i.e.
  row_enables::String | "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
  col_enables::String | "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"

  pixel_mode::PixelMode               | TCSPC
  decode_mode::DecodeMode             | Decoded
  output_mode::OutputMode             | Standard
  header_en::Unsigned                 | 1 # Enable header in the output stream

  tcspc::Unsigned                     | 0
  second_photon_mode_enable::Unsigned | 0
  gs_rs_mode::Unsigned                | 1
  enable_gating::Unsigned             | 0
  test_col_enable::Unsigned           | 0 # Enable this column to do calibration
  exposure_time::Unsigned             | 500 #exposure in us
  delay::Unsigned                     | 10 #multiples of 10ns; Delay from STOP => 20 * 10 ns = 200 ns
  gate_width::Unsigned                | 2 #multiples of 10ns;  Gate width in clock cycles => 2 * 10 ns = 20 ns

  stop_clk_divider::Unsigned          | 0
  last_row::Unsigned                  | 95
  byte_select::Unsigned               | 1
  byte_select_msb::Unsigned           | 0
  piso_readout_delay::Unsigned        | 19
  stop_source_select::Unsigned        | 0
  sync_delay_clk_cycles::Unsigned     | 0

  error_backtrace::Unsigned           | 0 # 0: Forward trace, 1: Backwards trace
  error_test::Unsigned                | 0 # 1 => Assign least priority line with ERROR_TEST signal
  fifo_rdout_test::Unsigned           | 0 # Enable readout emulation, to test serialiser->usb readout pipeline
end

Base.@kwdef mutable struct QCBoard
  # --------------------------------------------------
  # Intrinsic fields
  # ------------------------------------------------

  fpga::FPGA
  bank::Dict{BankEnum, BankInfo}

  # TODO: Add thread that disables operations with QCBoard until the timer expires
  # Useful for delays between configurations
  #cooldown::Atomic{Bool} = false

  # --------------------------------------------------
  # Setup parameters
  # ------------------------------------------------

  # PLL Setup
  which_OK_PLL = nothing

  # Power Supplies default values:
  # NOTE: Is this the same as V_ddro?
  VDD::Float32    = 1.1 # ring-oscillator power supply ∈ [0.7, 1.1] V
  # NOTE: Is this the same as Vdd for the level-shifter or the inverter voltage for SPAD firing
  VDDPIX::Float32 = 2.8 # VDDPIX 3V3 supply
  VQ::Float32     = 1 # Quenching gate voltage
  VEB::Float32    = 0.4
  VNBL::Float32   = 0.5
  VBD::Float32    = 0

  # Info
  sensor_status::SensorStatus = Disconnected  # Other allowed value is 'Connected'
  firmware_revision::String = ""

  # --------------------------------------------------
  # Config parameters
  # ------------------------------------------------
  config::QCConfig
  # TODO: Is there a way to decorate QCBoard with members of QCConfig?
end


function QCBoard(bitfile::String, bank::Dict{BankEnum, BankInfo}, config_path::Union{Nothing, AbstractString}=nothing)::QCBoard
  # Init library and default FPGA values
  fpga = FPGA(bitfile)
  # Get confis
  qc_config = if config_path !== nothing
    deser_json(QCConfig, read(config_path))
  else
    deser_json(QCConfig, "{}")
  end
  if config_path !== nothing
    qc_config.config_path = config_path
  end
  # Setup with FPGA and correct register banks
  qc = QCBoard(fpga=fpga, bank=bank, config = qc_config)
  finalizer(cleanup, qc)
  qc
end

QCBoard(bitfile::String, config_path::Union{Nothing,AbstractString}=nothing) = QCBoard(bitfile, QUANTICAM_BANK, config_path)

frame_size(qc) = 2 * (qc.config.last_row + 1) * qc.config.cols

function cleanup(qc::QCBoard)
  sensor_disconnect(qc)
  finalize(qc.fpga)
end

# --------------------------------------------------
# Parsing data helper types
# --------------------------------------------------

# FIXME: Is there a way to define a supertype for this instead of runtime matching?
const PixelVector = Union{Vector{UInt16}, Vector{UInt8}}

struct RowPairHeader
  marker::UInt8
  frame_id::UInt8
  row_cnt::UInt8
end

# The header is written in big endian
function parse_header(row_pair::PixelVector)::Result{RowPairHeader, ErrorException}#::RowPairHeader#
  # Header decoding in little endian:
  # |31    24|23    16|15       8|7      0|
  # | Marker | Frame  | Reserved | Row    |
  # But data is streamed in big endian (network fashion)
  header_bytes = extract_header(row_pair)
  #@assert header_bytes[2] == 0 "Expected the reserved byte in the headr to always be 0"
  if header_bytes[2] != 0
    @error "Expected the reserved byte in the header to always be 0; Header: $header_bytes"
    return ErrorResult(RowPairHeader, "Expected the reserved byte in the header to always be 0; Header: $header_bytes")
  end
  RowPairHeader(header_bytes[4], header_bytes[3], header_bytes[1])
end

function extract_header(row_pair::Vector{UInt16})::Vector{UInt8}
  reinterpret(UInt8, row_pair[1:2])
end

function extract_header(row_pair::Vector{UInt8})::Vector{UInt8}
  row_pair[1:4]
end

# ---------------------------------------------------
# Error Values
# ---------------------------------------------------
@enum QuantiCamError begin
  NO_ERROR                                     = 0
  # Readout is ignorant to flow control, hence out_valid |-> out_ready
  # => Decrease readout speed to avoid backpressure:
  #   -> Increase piso_readout_delay
  #   -> Increase exposure_time
  ERROR_READOUT_NO_BLOCKING                    = 1
  # ------------------------------------
  # Pipeline errors
  # ------------------------------------
  ERROR_PIXEL_DECODE_BACKPRESSURE_NOT_EXPECTED = 2
  ERROR_PIXEL_VALUES_PACK_INVALID_HEADER       = 3
  ERROR_PIXEL_VALUES_PACK_NOT_ZERO_EXTENDED    = 4
  ERROR_PIXEL_VALUES_PACK_MIXED_ENCODING_ERROR = 5
  # Frame sync FIFO
  ERROR_FIFO_SYNCHRONISER_ROW_OVERFLOW         = 6
  ERROR_FIFO_SYNCHRONISER_COL_OVERFLOW         = 7
  ERROR_FIFO_SYNCHRONISER_COL_LENGTH_ZERO      = 8
  ERROR_FIFO_SYNCHRONISER_FRAME_IDX_MISMATCH   = 9
  ERROR_FIFO_FRAME_COMITTED_BEFORE_END         = 10
  ERROR_FIFO_SYNCHRONISER_MISSALIGNED          = 11
  # Readout
  ERROR_READOUT_FIFO_FULL                      = 12
  ERROR_READOUT_FIFO_EMPTY                     = 13
  # Miscellaneous
  ERROR_CONFIG                                 = 14
  ERROR_TIMEOUT_ERROR                          = 15
  ERROR_DATA_INTEGRITY                         = 16
  ERROR_UNEXPECTED_DATA                        = 17
  ERROR_TEST                                   = 18
end
