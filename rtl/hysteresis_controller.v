// =============================================================================
// hysteresis_controller.v : routing-mode REQUEST logic (spec 6.4, 12.1)
//
// One module covers HYSTERoC and all comparison configurations via parameters:
//
//   DUAL = 1, USE_EWMA = 1 : HYSTERoC            (EWMA value, THIGH/TLOW)
//   DUAL = 1, USE_EWMA = 0 : Ablation B          (raw value,  THIGH/TLOW)
//   DUAL = 0, USE_EWMA = 1 : Ablation A          (EWMA value, single threshold)
//   DUAL = 0, USE_EWMA = 0 : conventional hybrid (raw value,  single threshold)
//
// Dual-threshold behaviour (spec 6.4), state = req_mode:
//   req_mode == XY    : value >= THIGH  -> request ADAPT
//   req_mode == ADAPT : value <= TLOW   -> request XY
//   otherwise hold (no change anywhere in the band TLOW < value < THIGH).
// Single-threshold behaviour (baselines, spec 12.1; no memory of the past):
//   req_mode_next = (value >= THRESH_SINGLE) ? ADAPT : XY
//   Default THRESH_SINGLE = 128 : mapped occupancy 2 or more requests adaptive.
//   (Spec 12.1 gives the 128 for the raw baseline only; using the same 128 for
//   Ablation A keeps the input source as the only difference. Recorded in
//   DECISIONS.md.)
//
// Mode request vs permission (spec 6.4): req_mode is the REQUESTED mode.
// mode_change_request = (req_mode != active_mode) only says the request differs
// from the network's current mode; it never changes any mode itself. The global
// transition controller decides when a switch is allowed.
//
// enable = 0 HOLDS req_mode (used by the transition controller outside RUN and
// during the optional post-resume mask, so a request cannot be retargeted
// mid-transition, spec 7.2/7.4).
//
// Reset (synchronous, active low): req_mode = XY. Thresholds are parameters, so
// synthesis folds them into constant comparators (smallest logic). Require
// TLOW < THIGH when DUAL = 1: violated settings stop the simulation.
// All value inputs are 8-bit mapped congestion values (0..255).
// =============================================================================
`include "hysteroc_defs.vh"

module hysteresis_controller #(
    parameter       DUAL          = 1,                      // 1 = dual threshold, 0 = single
    parameter       USE_EWMA      = 1,                      // 1 = value_ewma, 0 = value_raw
    parameter [7:0] THIGH         = `HY_THIGH_DEFAULT,      // 160
    parameter [7:0] TLOW          = `HY_TLOW_DEFAULT,       // 96
    parameter [7:0] THRESH_SINGLE = `HY_BASE_THRESH         // 128
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,            // 0 = hold requested mode
    input  wire [7:0] value_ewma,        // global max of the 16 EWMA estimates
    input  wire [7:0] value_raw,         // global max of the 16 mapped raw occupancies
    input  wire       active_mode,       // current network-wide mode (from the transition controller)

    output reg        req_mode,          // requested mode: XY(0) / ADAPT(1)
    output wire       mode_change_request // req_mode differs from active_mode
);

    // synthesis translate_off
    initial begin
        if (DUAL != 0 && !(TLOW < THIGH)) begin
            $display("ERROR: hysteresis_controller requires TLOW < THIGH (TLOW=%0d THIGH=%0d)", TLOW, THIGH);
            $finish;
        end
    end
    // synthesis translate_on

    wire [7:0] value = (USE_EWMA != 0) ? value_ewma : value_raw;

    reg next_req;
    always @(*) begin
        if (DUAL != 0) begin
            next_req = req_mode;                                  // default: hold
            if (req_mode == `HY_MODE_XY) begin
                if (value >= THIGH) next_req = `HY_MODE_ADAPT;
            end else begin
                if (value <= TLOW)  next_req = `HY_MODE_XY;
            end
        end else begin
            next_req = (value >= THRESH_SINGLE) ? `HY_MODE_ADAPT : `HY_MODE_XY;
        end
    end

    always @(posedge clk) begin
        if (!rst_n)
            req_mode <= `HY_MODE_XY;
        else if (enable)
            req_mode <= next_req;
    end

    assign mode_change_request = (req_mode != active_mode);

endmodule
