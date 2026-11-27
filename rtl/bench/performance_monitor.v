// =============================================================================
// performance_monitor.v : measurement block (spec 12, 13). NOT part of the
// router; it only OBSERVES signals and never drives anything except `now`.
// It is excluded from the HYSTERoC-versus-baseline overhead comparison.
//
// Provides
//   * `now`: the shared free-running cycle counter (0 in the first cycle after
//     reset). The same `now` must be wired to every traffic_generator and
//     packet_sink.
//   * Measurement window: cycles `warmup` .. `warmup + measure - 1` (by `now`).
//     `meas_en` is 1 inside the window. `meas_done` becomes 1 after the last
//     window cycle and stays 1. Every "w_" / windowed quantity below counts only
//     inside the window, using the value of `now` of the cycle in which the
//     event is observed (events are sampled at the clock edge, like any
//     registered logic).
//   * Switching metrics (spec 12.2) from the OBSERVED signals only:
//       completed switch   : the cycle in which `active_mode` differs from the
//                            previous cycle (first cycle the new mode is visible)
//       switch request     : `blk_starts` = rising edges of inject_block_req
//                            (a transition was started; it always completes
//                            unless the watchdog fires). `req_toggles` = changes
//                            of the raw `req_mode` request, started or not.
//       ping-pong event    : a completed switch whose previous completed switch
//                            was less than or equal to T_PP cycles earlier,
//                            BOTH inside the window. Consecutive completed
//                            switches always alternate direction, so every such
//                            pair is an opposite pair. Each switch is compared
//                            only with the one immediately before it (a run of
//                            n quick switches gives n-1 events). Four T_PP
//                            values counted at once (parameters PP0..PP3,
//                            default 50, 100, 200, 400).
//       dwell time         : cycles between two consecutive completed switches
//                            (both inside the window): sum, count, min, max.
//   * Transition cost (spec 12.3): a "blocked period" starts in the first cycle
//     inject_block_req = 1 and ends in the last cycle it is 1. drain length =
//     number of cycles in the period (including the cycle the new mode becomes
//     visible, in which injection is released). Periods are accumulated when the
//     period STARTED inside the window and ended before the monitor is read.
//     w_blocked = cycles inside the window with inject_block_req = 1;
//     injection-blocked fraction = w_blocked / measure.
//   * Packet metrics: for every good packet that a sink reports in the window
//     (pkt_done pulse): count, sum, sum of squares and maximum of the total
//     latency (creation to tail accepted) and of the network latency (header
//     offered to tail accepted). mean = sum/count; std = sqrt(sumsq/count -
//     mean^2). p99 is NOT computed here: the testbench logs every packet (exact
//     percentile). A packet belongs to the window if the sink pulse is in it.
//   * Throughput: flits accepted at the sources and at the sinks in the window.
//   * Progress watchdog: stall_cnt counts consecutive cycles with flits inside
//     the network (accepted minus delivered != 0) and no flit delivered.
//     stall_flag is sticky once stall_cnt reaches STALL_LIMIT; stall_max is the
//     longest stall. A stall detection is empirical evidence, not a proof.
//   * Totals over the whole run (not windowed): inj_flits_total, ej_flits_total,
//     pkts_total, sw_total, inflight.
//
// Latency inputs are 16-bit modulo values (decision 54). Verilog-2001.
// Synchronous active-low reset. Combinational loops over the 16 sinks are
// for simulation convenience (up to 16 packets can finish in one cycle).
// =============================================================================
module performance_monitor #(
    parameter PP0         = 50,
    parameter PP1         = 100,
    parameter PP2         = 200,
    parameter PP3         = 400,
    parameter STALL_LIMIT = 2000
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [31:0]  warmup,
    input  wire [31:0]  measure,

    // observed network signals
    input  wire         active_mode,
    input  wire         req_mode,
    input  wire         inject_block_req,
    input  wire [15:0]  inj_xfer,          // source flit accepted by its router
    input  wire [15:0]  ej_xfer,           // sink accepted a flit
    input  wire [15:0]  pkt_done,          // packet_sink pulses
    input  wire [255:0] lat_total,         // 16 x 16 bit, node n at [16n+:16]
    input  wire [255:0] lat_net,

    // time base and window
    output reg  [31:0]  now,
    output wire         meas_en,
    output reg          meas_done,
    output reg  [31:0]  meas_cycles,

    // switching
    output reg  [31:0]  sw_total,
    output reg  [31:0]  w_switches,
    output reg  [31:0]  w_to_adapt,
    output reg  [31:0]  w_to_xy,
    output reg  [31:0]  w_req_toggles,
    output reg  [31:0]  w_blk_starts,
    output reg  [31:0]  w_pp0,
    output reg  [31:0]  w_pp1,
    output reg  [31:0]  w_pp2,
    output reg  [31:0]  w_pp3,
    output reg  [31:0]  w_dwell_cnt,
    output reg  [47:0]  w_dwell_sum,
    output reg  [31:0]  w_dwell_min,
    output reg  [31:0]  w_dwell_max,
    output reg  [31:0]  w_adapt_cycles,

    // transition cost
    output reg  [31:0]  w_blocked,
    output reg  [31:0]  drain_cnt,
    output reg  [47:0]  drain_sum,
    output reg  [31:0]  drain_min,
    output reg  [31:0]  drain_max,
    output reg  [31:0]  blk_len_now,       // length of the blocked period in progress

    // packets / throughput
    output reg  [31:0]  w_pkts,
    output reg  [47:0]  w_lat_total_sum,
    output reg  [63:0]  w_lat_total_sq,
    output reg  [15:0]  w_lat_total_max,
    output reg  [47:0]  w_lat_net_sum,
    output reg  [63:0]  w_lat_net_sq,
    output reg  [15:0]  w_lat_net_max,
    output reg  [31:0]  w_inj_flits,
    output reg  [31:0]  w_ej_flits,
    output reg  [31:0]  pkts_total,
    output reg  [31:0]  inj_flits_total,
    output reg  [31:0]  ej_flits_total,
    output wire [31:0]  inflight,

    // watchdog
    output reg  [31:0]  stall_cnt,
    output reg  [31:0]  stall_max,
    output reg          stall_flag
);

    // ---------------------------------------------------------------
    // window
    // ---------------------------------------------------------------
    assign meas_en = (now >= warmup) && (meas_cycles < measure);

    // ---------------------------------------------------------------
    // per-cycle combinational sums over the 16 sinks / sources
    // ---------------------------------------------------------------
    integer i;
    reg [4:0]  c_inj, c_ej, c_pk;
    reg [19:0] s_tot, s_net;
    reg [35:0] q_tot, q_net;
    reg [15:0] m_tot, m_net;
    reg [15:0] lt, ln;
    always @* begin
        c_inj = 5'd0; c_ej = 5'd0; c_pk = 5'd0;
        s_tot = 20'd0; s_net = 20'd0; q_tot = 36'd0; q_net = 36'd0;
        m_tot = 16'd0; m_net = 16'd0;
        for (i = 0; i < 16; i = i + 1) begin
            lt = lat_total[16*i +: 16];
            ln = lat_net[16*i +: 16];
            if (inj_xfer[i]) c_inj = c_inj + 5'd1;
            if (ej_xfer[i])  c_ej  = c_ej  + 5'd1;
            if (pkt_done[i]) begin
                c_pk  = c_pk + 5'd1;
                s_tot = s_tot + {4'd0, lt};
                s_net = s_net + {4'd0, ln};
                q_tot = q_tot + {4'd0, lt} * {4'd0, lt};
                q_net = q_net + {4'd0, ln} * {4'd0, ln};
                if (lt > m_tot) m_tot = lt;
                if (ln > m_net) m_net = ln;
            end
        end
    end

    assign inflight = inj_flits_total - ej_flits_total;

    // ---------------------------------------------------------------
    // state for edge detection
    // ---------------------------------------------------------------
    reg        mode_prev, req_prev, blk_prev;
    reg        last_sw_valid;          // previous completed switch was inside the window
    reg [31:0] last_sw_time;
    reg        blk_in_window;          // the blocked period in progress started in the window

    wire sw_now     = (active_mode != mode_prev);
    wire blk_rise   = inject_block_req & ~blk_prev;
    wire blk_fall   = ~inject_block_req & blk_prev;
    wire [31:0] gap = now - last_sw_time;
    wire [31:0] len_final = blk_len_now;        // cycles counted so far (period just ended)

    always @(posedge clk) begin
        if (!rst_n) begin
            now <= 32'd0; meas_done <= 1'b0; meas_cycles <= 32'd0;
            sw_total <= 32'd0; w_switches <= 32'd0; w_to_adapt <= 32'd0; w_to_xy <= 32'd0;
            w_req_toggles <= 32'd0; w_blk_starts <= 32'd0;
            w_pp0 <= 32'd0; w_pp1 <= 32'd0; w_pp2 <= 32'd0; w_pp3 <= 32'd0;
            w_dwell_cnt <= 32'd0; w_dwell_sum <= 48'd0;
            w_dwell_min <= 32'hFFFFFFFF; w_dwell_max <= 32'd0; w_adapt_cycles <= 32'd0;
            w_blocked <= 32'd0; drain_cnt <= 32'd0; drain_sum <= 48'd0;
            drain_min <= 32'hFFFFFFFF; drain_max <= 32'd0; blk_len_now <= 32'd0;
            w_pkts <= 32'd0; w_lat_total_sum <= 48'd0; w_lat_total_sq <= 64'd0; w_lat_total_max <= 16'd0;
            w_lat_net_sum <= 48'd0; w_lat_net_sq <= 64'd0; w_lat_net_max <= 16'd0;
            w_inj_flits <= 32'd0; w_ej_flits <= 32'd0;
            pkts_total <= 32'd0; inj_flits_total <= 32'd0; ej_flits_total <= 32'd0;
            stall_cnt <= 32'd0; stall_max <= 32'd0; stall_flag <= 1'b0;
            mode_prev <= 1'b0; req_prev <= 1'b0; blk_prev <= 1'b0;
            last_sw_valid <= 1'b0; last_sw_time <= 32'd0; blk_in_window <= 1'b0;
        end else begin
            now       <= now + 32'd1;
            mode_prev <= active_mode;
            req_prev  <= req_mode;
            blk_prev  <= inject_block_req;

            // ---- window bookkeeping ----
            if (meas_en) meas_cycles <= meas_cycles + 32'd1;
            if (meas_en && (meas_cycles + 32'd1 >= measure)) meas_done <= 1'b1;

            // ---- whole-run totals ----
            inj_flits_total <= inj_flits_total + {27'd0, c_inj};
            ej_flits_total  <= ej_flits_total  + {27'd0, c_ej};
            pkts_total      <= pkts_total      + {27'd0, c_pk};
            if (sw_now) sw_total <= sw_total + 32'd1;

            // ---- progress watchdog ----
            if (inflight != 32'd0 && c_ej == 5'd0) begin
                stall_cnt <= stall_cnt + 32'd1;
                if (stall_cnt + 32'd1 > stall_max) stall_max <= stall_cnt + 32'd1;
                if (stall_cnt + 32'd1 >= STALL_LIMIT) stall_flag <= 1'b1;
            end else begin
                stall_cnt <= 32'd0;
            end

            // ---- completed switches, dwell, ping-pong ----
            if (sw_now) begin
                if (meas_en) begin
                    w_switches <= w_switches + 32'd1;
                    if (active_mode) w_to_adapt <= w_to_adapt + 32'd1;
                    else             w_to_xy    <= w_to_xy + 32'd1;
                    if (last_sw_valid) begin
                        w_dwell_cnt <= w_dwell_cnt + 32'd1;
                        w_dwell_sum <= w_dwell_sum + {16'd0, gap};
                        if (gap < w_dwell_min) w_dwell_min <= gap;
                        if (gap > w_dwell_max) w_dwell_max <= gap;
                        if (gap <= PP0) w_pp0 <= w_pp0 + 32'd1;
                        if (gap <= PP1) w_pp1 <= w_pp1 + 32'd1;
                        if (gap <= PP2) w_pp2 <= w_pp2 + 32'd1;
                        if (gap <= PP3) w_pp3 <= w_pp3 + 32'd1;
                    end
                    last_sw_valid <= 1'b1;
                end else begin
                    last_sw_valid <= 1'b0;      // a switch outside the window is no partner
                end
                last_sw_time <= now;
            end

            if (meas_en) begin
                if (req_mode != req_prev) w_req_toggles <= w_req_toggles + 32'd1;
                if (blk_rise)             w_blk_starts  <= w_blk_starts + 32'd1;
                if (inject_block_req)     w_blocked     <= w_blocked + 32'd1;
                if (active_mode)          w_adapt_cycles <= w_adapt_cycles + 32'd1;
                w_inj_flits <= w_inj_flits + {27'd0, c_inj};
                w_ej_flits  <= w_ej_flits  + {27'd0, c_ej};
                if (c_pk != 5'd0) begin
                    w_pkts          <= w_pkts + {27'd0, c_pk};
                    w_lat_total_sum <= w_lat_total_sum + {28'd0, s_tot};
                    w_lat_net_sum   <= w_lat_net_sum   + {28'd0, s_net};
                    w_lat_total_sq  <= w_lat_total_sq  + {28'd0, q_tot};
                    w_lat_net_sq    <= w_lat_net_sq    + {28'd0, q_net};
                    if (m_tot > w_lat_total_max) w_lat_total_max <= m_tot;
                    if (m_net > w_lat_net_max)   w_lat_net_max   <= m_net;
                end
            end

            // ---- blocked periods ----
            if (inject_block_req) begin
                blk_len_now <= blk_len_now + 32'd1;
                if (blk_rise) blk_in_window <= meas_en;
            end
            if (blk_fall) begin
                if (blk_in_window) begin
                    drain_cnt <= drain_cnt + 32'd1;
                    drain_sum <= drain_sum + {16'd0, len_final};
                    if (len_final < drain_min) drain_min <= len_final;
                    if (len_final > drain_max) drain_max <= len_final;
                end
                blk_len_now <= 32'd0;
            end
        end
    end

endmodule
