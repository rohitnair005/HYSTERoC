// =============================================================================
// transition_controller.v : global quiescence-based drain-and-switch FSM
// (spec 6.5, 7.2, 7.4, 9.3). One instance for the whole network.
//
//   RUN -> QUIESCE_REQUEST -> WAIT_ACK -> DRAIN -> SWITCH -> RESUME -> RUN
//   ERROR (sticky until reset) from QUIESCE_REQUEST / WAIT_ACK / DRAIN on timeout.
//
// Inputs
//   req_mode           from hysteresis_controller (requested mode)
//   inject_block_ack   one bit per source; a source raises it only once it will
//                      start no new packet and any started packet has finished
//   network_drained    from drain_detector
// Outputs
//   active_mode        THE single shared mode register. Written only in SWITCH,
//                      only when network_drained is true in that same cycle.
//   inject_block_req   1 in QUIESCE_REQUEST, WAIT_ACK, DRAIN, SWITCH, ERROR
//   ewma_enable        1 only in RUN (EWMA frozen in every other state)
//   hys_enable         1 only in RUN (request held outside RUN, spec 6.4)
//   transition_busy    1 in every state except RUN
//   drain_timeout      sticky error flag (== state ERROR)
//   state, target_mode status
//
// Rules implemented
//   * Target mode is latched when the transition starts and is never changed;
//     later changes of req_mode are ignored until the next RUN cycle.
//   * A transition starts in RUN only if req_mode != active_mode.
//   * WAIT_ACK needs ALL N_SRC acks in the same cycle (level).
//   * DRAIN waits for network_drained; SWITCH re-checks it: if it dropped, the
//     FSM returns to DRAIN WITHOUT switching.
//   * RESUME lasts 1 + POST_RESUME_MASK_CYCLES cycles; injection is released on
//     entry. EWMA and hysteresis stay frozen during it.
//   * Watchdog: cycle 1 is the first cycle inject_block_req = 1 (state
//     QUIESCE_REQUEST). If network_drained has not been seen (in state DRAIN)
//     by cycle WATCHDOG_LIMIT_CYCLES, the FSM goes to ERROR (drained seen exactly
//     in cycle LIMIT is still a success; later is not). Requires LIMIT >= 4. ERROR keeps inject_block_req = 1,
//     keeps active_mode, never switches, never resumes. Only reset recovers.
//   * A timeout NEVER forces a switch.
//
// Statistics (32-bit; ENABLE_STATS=0 removes all of them for the resource
// comparison, the FSM itself does not use any of them)
//   cycle_cnt                       free-running after reset
//   tr_blocked / tr_ackwait / tr_drain   current-or-last transition: cycles with
//                      inject_block_req=1 / in QUIESCE_REQUEST+WAIT_ACK / in DRAIN
//                      (cleared when the next transition starts)
//   tot_blocked / tot_ackwait / tot_drain / transitions   cumulative
//   t_block, t_ack, t_drained, t_switch, t_resume   cycle_cnt stamps of the last
//                      transition: block asserted (first cycle of QUIESCE_REQUEST),
//                      all acks seen (first cycle of DRAIN), network_drained seen
//                      (first cycle of SWITCH), mode updated (first cycle of
//                      RESUME, new active_mode visible), block released (same
//                      cycle as t_switch... see below).
//   Note: injection is released in RESUME, which is also the first cycle the new
//   mode is visible, so t_switch == t_resume by construction; both are exported.
// Verilog-2001, synchronous active-low reset.
// =============================================================================
`include "hysteroc_defs.vh"

module transition_controller #(
    parameter N_SRC                = 16,
    parameter WATCHDOG_LIMIT_CYCLES = `HY_WATCHDOG_LIMIT_DEFAULT,   // >= 4
    parameter POST_RESUME_MASK_CYCLES = `HY_POST_RESUME_MASK_DEFAULT,
    parameter ENABLE_STATS         = 1       // 0 removes every counter/timestamp (they read 0)
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              req_mode,
    input  wire [N_SRC-1:0]  inject_block_ack,
    input  wire              network_drained,

    output reg               active_mode,
    output wire              inject_block_req,
    output wire              ewma_enable,
    output wire              hys_enable,
    output wire              transition_busy,
    output wire              drain_timeout,
    output wire [2:0]        state_o,
    output wire              target_mode_o,

    output reg  [31:0]       cycle_cnt,
    output reg  [31:0]       tr_blocked,
    output reg  [31:0]       tr_ackwait,
    output reg  [31:0]       tr_drain,
    output reg  [31:0]       tot_blocked,
    output reg  [31:0]       tot_ackwait,
    output reg  [31:0]       tot_drain,
    output reg  [31:0]       transitions,
    output reg  [31:0]       t_block,
    output reg  [31:0]       t_ack,
    output reg  [31:0]       t_drained,
    output reg  [31:0]       t_switch,
    output reg  [31:0]       t_resume
);

    localparam [2:0] S_RUN    = 3'd0,
                     S_QUIESCE = 3'd1,
                     S_WAIT   = 3'd2,
                     S_DRAIN  = 3'd3,
                     S_SWITCH = 3'd4,
                     S_RESUME = 3'd5,
                     S_ERROR  = 3'd6;

    reg [2:0]  state;
    reg        target_mode;
    reg [15:0] wd_cnt;          // cycles of inject_block_req completed before this one (LIMIT < 65535)
    reg [15:0] mask_cnt;       // POST_RESUME_MASK_CYCLES < 65536

    wire all_ack = &inject_block_ack;
    wire wd_last = (wd_cnt >= (WATCHDOG_LIMIT_CYCLES - 1));   // this is cycle LIMIT (or later)
    wire wd_over = (wd_cnt >= WATCHDOG_LIMIT_CYCLES);         // already past cycle LIMIT

    assign inject_block_req = (state == S_QUIESCE) | (state == S_WAIT) | (state == S_DRAIN) |
                              (state == S_SWITCH)  | (state == S_ERROR);
    assign ewma_enable      = (state == S_RUN);
    assign hys_enable       = (state == S_RUN);
    assign transition_busy  = (state != S_RUN);
    assign drain_timeout    = (state == S_ERROR);
    assign state_o          = state;
    assign target_mode_o    = target_mode;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_RUN;
            active_mode <= `HY_MODE_XY;
            target_mode <= `HY_MODE_XY;
            wd_cnt      <= 16'd0;
            mask_cnt    <= 16'd0;
            cycle_cnt   <= 32'd0;
            tr_blocked <= 32'd0; tr_ackwait <= 32'd0; tr_drain <= 32'd0;
            tot_blocked <= 32'd0; tot_ackwait <= 32'd0; tot_drain <= 32'd0; transitions <= 32'd0;
            t_block <= 32'd0; t_ack <= 32'd0; t_drained <= 32'd0; t_switch <= 32'd0; t_resume <= 32'd0;
        end else begin
            if (ENABLE_STATS) cycle_cnt <= cycle_cnt + 32'd1;

            // ---- statistics (count the cycle being spent in this state) ----
            if (ENABLE_STATS && inject_block_req) begin
                tr_blocked  <= tr_blocked + 32'd1;
                tot_blocked <= tot_blocked + 32'd1;
            end
            if (ENABLE_STATS && (state == S_QUIESCE || state == S_WAIT)) begin
                tr_ackwait  <= tr_ackwait + 32'd1;
                tot_ackwait <= tot_ackwait + 32'd1;
            end
            if (ENABLE_STATS && state == S_DRAIN) begin
                tr_drain  <= tr_drain + 32'd1;
                tot_drain <= tot_drain + 32'd1;
            end
            if (inject_block_req && state != S_ERROR) wd_cnt <= wd_cnt + 16'd1;

            case (state)
                S_RUN: begin
                    wd_cnt <= 16'd0;
                    if (req_mode != active_mode) begin
                        target_mode <= req_mode;           // latched for the whole transition
                        state       <= S_QUIESCE;
                        if (ENABLE_STATS) begin
                            tr_blocked  <= 32'd0; tr_ackwait <= 32'd0; tr_drain <= 32'd0;
                            t_block     <= cycle_cnt + 32'd1;  // first cycle of QUIESCE
                        end
                    end
                end

                S_QUIESCE: begin
                    // inject_block_req is already 1 in this state
                    if (wd_last) state <= S_ERROR;          // only possible for LIMIT <= 1
                    else         state <= S_WAIT;
                end

                S_WAIT: begin
                    // acks in cycle LIMIT (or later) are too late: DRAIN could not
                    // see network_drained until after the limit
                    if (wd_last) state <= S_ERROR;
                    else if (all_ack) begin
                        state <= S_DRAIN;
                        if (ENABLE_STATS) t_ack <= cycle_cnt + 32'd1;
                    end
                end

                S_DRAIN: begin
                    if (network_drained && !wd_over) begin
                        state     <= S_SWITCH;
                        if (ENABLE_STATS) t_drained <= cycle_cnt + 32'd1;
                    end else if (wd_last) state <= S_ERROR;   // not drained by cycle LIMIT
                end

                S_SWITCH: begin
                    if (network_drained) begin             // re-check in the switching cycle
                        active_mode <= target_mode;        // the ONLY write of active_mode
                        if (ENABLE_STATS) transitions <= transitions + 32'd1;
                        mask_cnt    <= POST_RESUME_MASK_CYCLES;
                        state       <= S_RESUME;
                        if (ENABLE_STATS) begin
                            t_switch    <= cycle_cnt + 32'd1;
                            t_resume    <= cycle_cnt + 32'd1;
                        end
                    end else begin
                        state <= S_DRAIN;                  // lost quiescence: do not switch
                    end
                end

                S_RESUME: begin
                    if (mask_cnt == 16'd0) state <= S_RUN;
                    else                   mask_cnt <= mask_cnt - 16'd1;
                end

                S_ERROR: begin
                    state <= S_ERROR;                      // sticky until reset
                end

                default: state <= S_ERROR;
            endcase
        end
    end

endmodule
