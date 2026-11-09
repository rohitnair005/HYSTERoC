// =============================================================================
// mode_switch_direct.v : NO-DRAIN mode switching (SWITCH_POLICY = 1)
//
// Replacement for transition_controller when the network does not drain before
// a mode change. It has the SAME ports so noc_top can instantiate either one.
//
//   active_mode follows req_mode one cycle later, at any time, with traffic in
//   flight. This is safe for deadlock freedom ONLY because both modes use
//   Odd-Even turns: the non-adaptive mode is oe_fixed (a member of the Odd-Even
//   candidate set) and the adaptive mode picks from that same set, so a header
//   routed in either mode takes only turns that the Odd-Even rules allow. A
//   packet already holding its output keeps it (wormhole), only the NEXT header
//   decision uses the new mode.
//
//   No injection block, no handshake with the sources, no watchdog: the
//   inject_block_req / ewma_enable / hys_enable / transition_busy / drain_timeout
//   outputs are constants and state_o is 0 (RUN). inject_block_ack and
//   network_drained are not used (kept only for the identical interface).
//   Statistics: cycle_cnt and transitions (number of active_mode changes) are
//   kept, all drain-related counters read 0.
// Verilog-2001.
// =============================================================================
`include "hysteroc_defs.vh"

module mode_switch_direct #(
    parameter N_SRC        = 16,
    parameter ENABLE_STATS = 1
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              req_mode,
    input  wire [N_SRC-1:0]  inject_block_ack,   // unused
    input  wire              network_drained,    // unused

    output reg               active_mode,
    output wire              inject_block_req,
    output wire              ewma_enable,
    output wire              hys_enable,
    output wire              transition_busy,
    output wire              drain_timeout,
    output wire [2:0]        state_o,
    output wire              target_mode_o,

    output reg  [31:0]       cycle_cnt,
    output wire [31:0]       tr_blocked,
    output wire [31:0]       tr_ackwait,
    output wire [31:0]       tr_drain,
    output wire [31:0]       tot_blocked,
    output wire [31:0]       tot_ackwait,
    output wire [31:0]       tot_drain,
    output reg  [31:0]       transitions,
    output wire [31:0]       t_block,
    output wire [31:0]       t_ack,
    output wire [31:0]       t_drained,
    output wire [31:0]       t_switch,
    output wire [31:0]       t_resume
);

    assign inject_block_req = 1'b0;
    assign ewma_enable      = 1'b1;
    assign hys_enable       = 1'b1;
    assign transition_busy  = 1'b0;
    assign drain_timeout    = 1'b0;
    assign state_o          = 3'd0;
    assign target_mode_o    = req_mode;

    assign tr_blocked = 32'd0;  assign tr_ackwait = 32'd0;  assign tr_drain = 32'd0;
    assign tot_blocked = 32'd0; assign tot_ackwait = 32'd0; assign tot_drain = 32'd0;
    assign t_block = 32'd0; assign t_ack = 32'd0; assign t_drained = 32'd0;
    assign t_switch = 32'd0; assign t_resume = 32'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            active_mode <= `HY_MODE_XY;
            cycle_cnt   <= 32'd0;
            transitions <= 32'd0;
        end else begin
            active_mode <= req_mode;
            if (ENABLE_STATS) begin
                cycle_cnt <= cycle_cnt + 32'd1;
                if (req_mode != active_mode) transitions <= transitions + 32'd1;
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_ok = &{1'b0, inject_block_ack, network_drained};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
