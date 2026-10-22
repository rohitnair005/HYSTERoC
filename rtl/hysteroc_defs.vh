// =============================================================================
// hysteroc_defs.vh : shared constants for HYSTERoC (spec v5, Verilog-2001)
//
// Include with:   `include "hysteroc_defs.vh"      (compile with -I rtl)
// Only `define macros are used (no packages, no SystemVerilog constructs).
// Every value below is either FROZEN by spec v5 or marked DEFAULT (tunable).
// =============================================================================
`ifndef HYSTEROC_DEFS_VH
`define HYSTEROC_DEFS_VH

// ---- Network size (spec 3.1, FROZEN) ----------------------------------------
`define HY_MESH_DIM        4          // 4x4 mesh
`define HY_NUM_ROUTERS     16
`define HY_COORD_W         2          // x,y in 0..3

// ---- Link / flit format (spec 3.2, 4.1, FROZEN) -----------------------------
`define HY_DATA_W          16
`define HY_TYPE_W          2
`define HY_FLIT_W          18         // {flit_type, data}

// flit_type encoding (spec 4.1, FROZEN)
`define HY_FT_HEADER       2'b00
`define HY_FT_BODY         2'b01
`define HY_FT_TAIL         2'b10
`define HY_FT_RSVD         2'b11

// Packet = header + 2 body + tail, exactly 4 flits (spec 4.2, FROZEN)
`define HY_PKT_FLITS       4

// ---- Header field positions (spec 4.3, FROZEN) ------------------------------
`define HY_HDR_DSTX_HI     15
`define HY_HDR_DSTX_LO     14
`define HY_HDR_DSTY_HI     13
`define HY_HDR_DSTY_LO     12
`define HY_HDR_SRCX_HI     11
`define HY_HDR_SRCX_LO     10
`define HY_HDR_SRCY_HI     9
`define HY_HDR_SRCY_LO     8
`define HY_HDR_PID_HI      7
`define HY_HDR_PID_LO      0

// ---- Port IDs (internal encoding; tie-break order E,S,W,N is separate) ------
`define HY_NUM_PORTS       5
`define HY_PORT_ID_W       3
`define HY_PORT_N          3'd0
`define HY_PORT_S          3'd1
`define HY_PORT_E          3'd2
`define HY_PORT_W          3'd3
`define HY_PORT_L          3'd4       // Local

// One-hot port masks: bit i of a 5-bit port mask is port id i
`define HY_PM_N            5'b00001
`define HY_PM_S            5'b00010
`define HY_PM_E            5'b00100
`define HY_PM_W            5'b01000
`define HY_PM_L            5'b10000

// ---- Routing mode (spec 6.4: reset mode is XY) ------------------------------
`define HY_MODE_XY         1'b0
`define HY_MODE_ADAPT      1'b1       // adaptive Odd-Even

// ---- Input FIFO (spec 5.2, FROZEN) ------------------------------------------
`define HY_FIFO_DEPTH      4
`define HY_FIFO_PTR_W      2
`define HY_FIFO_OCC_W      3          // occupancy 0..4

// ---- Occupancy -> 8-bit congestion map (spec 6.2, FROZEN) -------------------
`define HY_CONG_OCC0       8'd0
`define HY_CONG_OCC1       8'd64
`define HY_CONG_OCC2       8'd128
`define HY_CONG_OCC3       8'd192
`define HY_CONG_OCC4       8'd255
`define HY_CONG_W          8

// ---- EWMA (spec 6.3, FROZEN) : S = 8*E, S_next = S - (S>>3) + C -------------
`define HY_EWMA_SHIFT      3
`define HY_EWMA_S_W        11         // max representable 2047
`define HY_SAMPLE_PERIOD_DEFAULT 1    // DEFAULT, update every cycle

// ---- Hysteresis thresholds (spec 6.4: provisional, configurable) ------------
`define HY_THIGH_DEFAULT   8'd160     // DEFAULT
`define HY_TLOW_DEFAULT    8'd96      // DEFAULT

// ---- Baseline single threshold on raw occupancy (spec 12.1) -----------------
`define HY_BASE_THRESH     8'd128

// ---- Transition controller defaults (spec 7.4) ------------------------------
`define HY_WATCHDOG_LIMIT_DEFAULT   1000   // DEFAULT cycles
`define HY_POST_RESUME_MASK_DEFAULT 0      // DEFAULT cycles

`endif // HYSTEROC_DEFS_VH
