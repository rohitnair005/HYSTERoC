// =============================================================================
// tb_traffic_system.v : noc_top + 16 traffic_generator + 16 packet_sink
//
// Two systems (HYSTERoC and XY-only) driven by the REAL generators and sinks.
//   Z  zero-load latency: one packet 0 -> 15 and 15 -> 0, one packet to a
//      neighbour, one to self-distance 2; records the latency law
//        lat_net = distance + 4 (header offered -> tail accepted)
//   P  five traffic phases (uniform low, hot spot with slow hot sink,
//      uniform medium, complement, transpose, idle) with random sink ready
//   Checks: sink error counters all zero; scoreboard from create / pkt_done
//   pulses (each created packet delivered exactly once, at the right node);
//   independent flit accounting (injected - ejected = in flight) with
//   network_drained => 0 in flight, mode change => 0 in flight and all sources
//   idle, no valid during DRAIN/SWITCH; lat_total >= lat_net >= distance + 4;
//   at the end created = delivered, injected = created, all queues empty, all
//   routers empty, controller back in RUN, XY-only never transitions.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module sys_env #(
    parameter XY_ONLY = 0,
    parameter SEED = 7,
    parameter CYCLES = 20000,
    parameter [8*24-1:0] LOG_PKT = "sys_packets.csv",
    parameter [8*24-1:0] LOG_SW  = "sys_switches.csv",
    parameter [8*24-1:0] LOG_BLK = "sys_blocks.csv",
    parameter [8*24-1:0] LOG_SUM = "sys_summary.txt",
    parameter [8*24-1:0] LOG_TAG = "sys"
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [31:0] err_count
);
    wire [31:0] now;                 // time base from the performance monitor
    localparam [31:0] PM_WARM = 32'd1000, PM_MEAS = 32'd18000;
    reg [31:0] LOG_WARM, LOG_MEAS;
    initial begin LOG_WARM = PM_WARM; LOG_MEAS = PM_MEAS; end

    // ---------------- configuration ----------------
    reg         gen_enable;
    reg  [15:0] rate;
    reg  [2:0]  pattern;
    reg  [3:0]  hot_node;
    reg  [7:0]  hot_pct;
    reg  [31:0] max_packets;
    reg  [15:0] gen_mask;
    reg  [7:0]  thresh_all, thresh_hot;

    // ---------------- DUT: network ----------------
    wire [255:0] inj_data, ej_data;  wire [31:0] inj_type, ej_type;
    wire [15:0]  inj_valid, inj_ready, ej_valid, ej_ready;
    wire         inject_block_req;
    wire [15:0]  inject_block_ack, src_empty;
    wire         active_mode, req_mode, transition_busy, drain_timeout, network_drained;
    wire [7:0]   global_congestion, global_raw;
    wire [2:0]   ctrl_state;
    wire [15:0]  router_empty;
    wire [239:0] fifo_occ_all;  wire [127:0] ewma_all;
    wire         proto_err_any, alloc_err_any;
    wire [31:0]  cycle_cnt, tr_blocked, tr_ackwait, tr_drain, tot_blocked, tot_ackwait, tot_drain, transitions;
    wire [31:0]  t_block, t_ack, t_drained, t_switch, t_resume;

    noc_top #(.XY_ONLY(XY_ONLY)) dut (
        .clk(clk), .rst_n(rst_n),
        .inj_data(inj_data), .inj_type(inj_type), .inj_valid(inj_valid), .inj_ready(inj_ready),
        .ej_data(ej_data), .ej_type(ej_type), .ej_valid(ej_valid), .ej_ready(ej_ready),
        .inject_block_req(inject_block_req), .inject_block_ack(inject_block_ack), .src_empty(src_empty),
        .active_mode(active_mode), .req_mode(req_mode),
        .global_congestion(global_congestion), .global_raw(global_raw),
        .transition_busy(transition_busy), .drain_timeout(drain_timeout), .network_drained(network_drained),
        .ctrl_state(ctrl_state), .router_empty(router_empty), .fifo_occ_all(fifo_occ_all), .ewma_all(ewma_all),
        .proto_err_any(proto_err_any), .alloc_err_any(alloc_err_any),
        .cycle_cnt(cycle_cnt), .tr_blocked(tr_blocked), .tr_ackwait(tr_ackwait), .tr_drain(tr_drain),
        .tot_blocked(tot_blocked), .tot_ackwait(tot_ackwait), .tot_drain(tot_drain), .transitions(transitions),
        .t_block(t_block), .t_ack(t_ack), .t_drained(t_drained), .t_switch(t_switch), .t_resume(t_resume)
    );

    // ---------------- 16 sources and 16 sinks ----------------
    wire [15:0] g_create_pulse;
    wire [63:0] g_create_dst;
    wire [127:0] g_create_seq;
    wire [15:0] g_flit_accept;
    wire [511:0] g_created, g_dropped, g_injected;
    wire [47:0] g_qcount;
    wire [15:0] k_pkt_done;
    wire [63:0] k_pkt_src;
    wire [127:0] k_pkt_pid;
    wire [255:0] k_lat_t, k_lat_n;
    wire [511:0] k_pkts_ok, k_flits;
    wire [255:0] k_ed, k_eo, k_ei;
    wire [15:0] k_err_any;

    genvar n;
    generate
        for (n = 0; n < 16; n = n + 1) begin : g_node
            traffic_generator #(.NODE(n), .SEED(32'hA5000000 + SEED * 977 + n * 131)) gen (
                .clk(clk), .rst_n(rst_n), .now(now),
                .gen_enable(gen_enable & gen_mask[n]), .rate(rate), .pattern(pattern), .hot_node(hot_node), .hot_pct(hot_pct),
                .max_packets(max_packets),
                .inj_data(inj_data[16*n +: 16]), .inj_type(inj_type[2*n +: 2]), .inj_valid(inj_valid[n]), .inj_ready(inj_ready[n]),
                .inject_block_req(inject_block_req), .inject_block_ack(inject_block_ack[n]), .src_empty(src_empty[n]),
                .create_pulse(g_create_pulse[n]), .create_dst(g_create_dst[4*n +: 4]), .create_seq(g_create_seq[8*n +: 8]),
                .flit_accept(g_flit_accept[n]),
                .created(g_created[32*n +: 32]), .dropped(g_dropped[32*n +: 32]), .injected(g_injected[32*n +: 32]),
                .q_count(g_qcount[3*n +: 3])
            );
            packet_sink #(.NODE(n), .SEED(32'h5A000000 + SEED * 311 + n * 17)) sink (
                .clk(clk), .rst_n(rst_n), .now(now), .ready_thresh((n == hot_node) ? thresh_hot : thresh_all),
                .ej_data(ej_data[16*n +: 16]), .ej_type(ej_type[2*n +: 2]), .ej_valid(ej_valid[n]), .ej_ready(ej_ready[n]),
                .pkt_done(k_pkt_done[n]), .pkt_src(k_pkt_src[4*n +: 4]), .pkt_pid(k_pkt_pid[8*n +: 8]),
                .pkt_lat_total(k_lat_t[16*n +: 16]), .pkt_lat_net(k_lat_n[16*n +: 16]),
                .pkts_ok(k_pkts_ok[32*n +: 32]), .flits(k_flits[32*n +: 32]),
                .err_dest_cnt(k_ed[16*n +: 16]), .err_order_cnt(k_eo[16*n +: 16]), .err_integ_cnt(k_ei[16*n +: 16]),
                .err_any(k_err_any[n])
            );
        end
    endgenerate

    // ---------------- performance monitor + log ----------------
    wire pm_meas_en;
    performance_monitor pm (
        .clk(clk), .rst_n(rst_n), .warmup(PM_WARM), .measure(PM_MEAS),
        .active_mode(active_mode), .req_mode(req_mode), .inject_block_req(inject_block_req),
        .inj_xfer(inj_valid & inj_ready), .ej_xfer(ej_valid & ej_ready),
        .pkt_done(k_pkt_done), .lat_total(k_lat_t), .lat_net(k_lat_n),
        .now(now), .meas_en(pm_meas_en));
    `define PM_INST pm
    `include "pm_log.vh"

    // ---------------- checking ----------------
    integer errors, seed;
    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors <= 8) $display("ERROR[xy=%0d] @%0t: %0s", XY_ONLY, $time, msg); end
    endtask

    integer sb [0:4095];             // [src*256 + seq] -> dst + 1
    integer inflight, inj_fl, ej_fl, max_inflight, created_total, delivered_total;
    integer lat_n_sum, lat_t_sum, lat_cnt, lat_n_sum_xy, lat_cnt_xy, lat_n_sum_ad, lat_cnt_ad;
    integer cov_trans, min_excess;
    integer w_cnt, w_lt_sum, w_ln_sum, w_inj, w_ej, w_blk, w_sw;
    reg        prev_active; integer prev_inflight; reg [15:0] prev_src_empty;
    integer    zl_lat [0:15];        // zero-load latency by distance
    integer    zl_phase, zl_count;
    integer kk, dist, srcn, dstn;
    reg [15:0] acc_i, acc_e;
    reg        win;
    function [4:0] pc16; input [15:0] v; integer q; begin pc16 = 0; for (q = 0; q < 16; q = q + 1) pc16 = pc16 + v[q]; end endfunction

    always @(posedge clk) if (rst_n) begin
        acc_i = inj_valid & inj_ready;
        acc_e = ej_valid & ej_ready;
        win = (now >= PM_WARM) && (now < PM_WARM + PM_MEAS);
        if (win) begin
            w_inj = w_inj + pc16(acc_i); w_ej = w_ej + pc16(acc_e);
            if (inject_block_req) w_blk = w_blk + 1;
            if (active_mode !== prev_active) w_sw = w_sw + 1;
        end
        if (proto_err_any) fail("proto_err_any");
        if (alloc_err_any) fail("alloc_err_any");
        if (drain_timeout) fail("drain_timeout");
        if (network_drained && inflight != 0) fail("network_drained with flits in flight");
        if ((ctrl_state == 3 || ctrl_state == 4) && inj_valid != 16'h0) fail("source injecting during DRAIN/SWITCH");
        if (active_mode !== prev_active) begin
            cov_trans = cov_trans + 1;
            if (prev_inflight != 0) fail("mode changed with flits in flight");
            if (prev_src_empty != 16'hFFFF) fail("mode changed with a source busy");
            if (XY_ONLY) fail("XY_ONLY changed mode");
        end
        prev_active = active_mode; prev_inflight = inflight; prev_src_empty = src_empty;
        for (kk = 0; kk < 16; kk = kk + 1) begin
            if (acc_i[kk]) begin inj_fl = inj_fl + 1; inflight = inflight + 1; end
            if (acc_e[kk]) begin ej_fl = ej_fl + 1; inflight = inflight - 1; end
            if (g_create_pulse[kk]) begin
                if (sb[kk*256 + g_create_seq[8*kk +: 8]] != 0) fail("scoreboard slot reused");
                sb[kk*256 + g_create_seq[8*kk +: 8]] = g_create_dst[4*kk +: 4] + 1;
                created_total = created_total + 1;
            end
            if (k_pkt_done[kk]) begin
                srcn = k_pkt_src[4*kk +: 4];
                if (sb[srcn*256 + k_pkt_pid[8*kk +: 8]] != kk + 1) fail("delivered packet not expected (dup/phantom/wrong node)");
                else sb[srcn*256 + k_pkt_pid[8*kk +: 8]] = 0;
                delivered_total = delivered_total + 1;
                if (win) begin w_cnt = w_cnt + 1; w_lt_sum = w_lt_sum + k_lat_t[16*kk +: 16]; w_ln_sum = w_ln_sum + k_lat_n[16*kk +: 16]; end
                dist = ((srcn % 4) > (kk % 4) ? (srcn % 4) - (kk % 4) : (kk % 4) - (srcn % 4)) +
                       ((srcn / 4) > (kk / 4) ? (srcn / 4) - (kk / 4) : (kk / 4) - (srcn / 4));
                if (k_lat_n[16*kk +: 16] < dist + 4) fail("network latency below the physical minimum");
                if (k_lat_t[16*kk +: 16] < k_lat_n[16*kk +: 16]) fail("total latency < network latency");
                lat_n_sum = lat_n_sum + k_lat_n[16*kk +: 16]; lat_t_sum = lat_t_sum + k_lat_t[16*kk +: 16]; lat_cnt = lat_cnt + 1;
                if (k_lat_n[16*kk +: 16] - dist - 4 < min_excess) min_excess = k_lat_n[16*kk +: 16] - dist - 4;
                if (zl_phase) begin zl_lat[dist] = k_lat_n[16*kk +: 16]; if (k_lat_n[16*kk +: 16] != dist + 4) fail("zero-load latency != distance + 4"); zl_count = zl_count + 1; end
                if (active_mode) begin lat_n_sum_ad = lat_n_sum_ad + k_lat_n[16*kk +: 16]; lat_cnt_ad = lat_cnt_ad + 1; end
                else begin lat_n_sum_xy = lat_n_sum_xy + k_lat_n[16*kk +: 16]; lat_cnt_xy = lat_cnt_xy + 1; end
            end
        end
        if (k_err_any != 16'h0) fail("a sink reported a protocol/integrity/destination error");
        if (inflight > max_inflight) max_inflight = inflight;
    end

    // ---------------- stimulus ----------------
    integer ph, guard, cc, i, qsum, dsum, isum, drop_sum, flits_in, flits_out;
    task tick; input integer c; integer q; begin for (q = 0; q < c; q = q + 1) @(negedge clk); end endtask

    initial begin
        done = 0; err_count = 0; errors = 0; seed = SEED;
        gen_enable = 0; rate = 0; pattern = 0; hot_node = 4'd9; hot_pct = 8'd180; max_packets = 0;
        thresh_all = 8'hFF; thresh_hot = 8'hFF;
        inflight = 0; inj_fl = 0; ej_fl = 0; max_inflight = 0; created_total = 0; delivered_total = 0;
        lat_n_sum = 0; lat_t_sum = 0; lat_cnt = 0; lat_n_sum_xy = 0; lat_cnt_xy = 0; lat_n_sum_ad = 0; lat_cnt_ad = 0;
        w_cnt = 0; w_lt_sum = 0; w_ln_sum = 0; w_inj = 0; w_ej = 0; w_blk = 0; w_sw = 0;
        cov_trans = 0; min_excess = 100000; zl_count = 0; gen_mask = 16'hFFFF; prev_active = 0; prev_inflight = 0; prev_src_empty = 16'hFFFF; zl_phase = 0;
        for (i = 0; i < 16; i = i + 1) zl_lat[i] = -1;
        for (i = 0; i < 4096; i = i + 1) sb[i] = 0;
        wait (rst_n === 1'b1); tick(5);

        // ---- Z: zero-load latency, one packet from one node into an empty network ----
        zl_phase = 1; rate = 16'hFFF0; max_packets = 1;
        // node 0, complement -> node 15 (distance 6)
        gen_mask = 16'h0001; pattern = 3'd3; gen_enable = 1; tick(80); gen_enable = 0;
        // node 5, neighbour -> node 6 (distance 1)
        gen_mask = 16'h0020; pattern = 3'd4; gen_enable = 1; tick(80); gen_enable = 0;
        // node 1, transpose -> node 4 (distance 2)
        gen_mask = 16'h0002; pattern = 3'd2; gen_enable = 1; tick(80); gen_enable = 0;
        // node 14, complement -> node 1 (distance 4)
        gen_mask = 16'h4000; pattern = 3'd3; gen_enable = 1; tick(80); gen_enable = 0;
        if (zl_count != 4) fail("zero-load packets not delivered");
        zl_phase = 0; gen_mask = 16'hFFFF; max_packets = 0;
        // rewind the sources' packet limits: created counters stay, so use unlimited from here on

        // ---- P: traffic phases ----
        max_packets = 0; gen_enable = 1;
        cc = 0;
        while (cc < CYCLES) begin
            ph = (cc / 2500) % 6;
            case (ph)
                0: begin pattern = 3'd0; rate = 16'h0800; thresh_all = 8'hE0; thresh_hot = 8'hE0; end
                1: begin pattern = 3'd1; rate = 16'h6000; thresh_all = 8'hB0; thresh_hot = 8'h30; end
                2: begin pattern = 3'd0; rate = 16'h1800; thresh_all = 8'hC8; thresh_hot = 8'hC8; end
                3: begin pattern = 3'd3; rate = 16'h4000; thresh_all = 8'h90; thresh_hot = 8'h90; end
                4: begin pattern = 3'd2; rate = 16'h3000; thresh_all = 8'hB0; thresh_hot = 8'hB0; end
                default: begin pattern = 3'd0; rate = 16'h0200; thresh_all = 8'hFF; thresh_hot = 8'hFF; end
            endcase
            @(negedge clk); cc = cc + 1;
            if (cc % 5000 == 0) $display("PROGRESS xy=%0d cycle=%0d created=%0d delivered=%0d inflight=%0d mode=%0d trans=%0d", XY_ONLY, cc, created_total, delivered_total, inflight, active_mode, transitions);
        end

        // ---- drain ----
        gen_enable = 0; thresh_all = 8'hFF; thresh_hot = 8'hFF;
        guard = 0;
        qsum = 1;
        while (guard < 60000 && !(qsum == 0 && inflight == 0 && src_empty == 16'hFFFF && ctrl_state == 3'd0 && req_mode == active_mode && global_congestion == 8'd0)) begin
            @(negedge clk); guard = guard + 1;
            qsum = 0; for (i = 0; i < 16; i = i + 1) qsum = qsum + g_qcount[3*i +: 3];
        end
        tick(10);

        // ---- end checks ----
        isum = 0; drop_sum = 0; dsum = 0; flits_in = 0; flits_out = 0;
        for (i = 0; i < 16; i = i + 1) begin
            isum = isum + g_injected[32*i +: 32]; drop_sum = drop_sum + g_dropped[32*i +: 32];
            dsum = dsum + k_pkts_ok[32*i +: 32]; flits_out = flits_out + k_flits[32*i +: 32];
            if (g_qcount[3*i +: 3] != 0) fail("queue not empty at end");
        end
        if (created_total != isum) fail("created != injected");
        if (isum != dsum || delivered_total != dsum) fail("injected != delivered");
        if (flits_out != 4 * dsum) fail("flit count at sinks");
        if (inj_fl != 4 * isum || ej_fl != inj_fl) fail("flit accounting");
        if (inflight != 0) fail("inflight at end");
        if (router_empty !== 16'hFFFF) fail("routers not empty at end");
        if (ctrl_state !== 3'd0) fail("controller not in RUN at end");
        if (XY_ONLY && transitions !== 0) fail("XY-only transitions");
        if (!XY_ONLY && cov_trans == 0) fail("no mode change occurred (coverage)");
        for (i = 0; i < 4096; i = i + 1) if (sb[i] != 0) begin fail("packet created but never delivered"); i = 4096; end
        // ---- performance monitor against the independent bookkeeping above ----
        if (pm.pkts_total !== delivered_total) fail("pm pkts_total");
        if (pm.inj_flits_total !== inj_fl)     fail("pm inj_flits_total");
        if (pm.ej_flits_total  !== ej_fl)      fail("pm ej_flits_total");
        if (pm.inflight !== inflight)          fail("pm inflight");
        if (pm.sw_total !== cov_trans)         fail("pm sw_total");
        if (pm.w_switches !== w_sw)            fail("pm w_switches");
        if (pm.w_pkts !== w_cnt)               fail("pm w_pkts");
        if (pm.w_lat_total_sum !== w_lt_sum)   fail("pm lat_total_sum");
        if (pm.w_lat_net_sum !== w_ln_sum)     fail("pm lat_net_sum");
        if (pm.w_inj_flits !== w_inj)          fail("pm w_inj_flits");
        if (pm.w_ej_flits !== w_ej)            fail("pm w_ej_flits");
        if (pm.w_blocked !== w_blk)            fail("pm w_blocked");
        if (pm.meas_cycles !== PM_MEAS || pm.meas_done !== 1'b1) fail("pm window");
        if (pm.stall_flag !== 1'b0)            fail("pm stall flag (no stall expected)");
        if (pm.w_switches != pm.w_to_adapt + pm.w_to_xy) fail("pm switch directions");
        if (pm.drain_cnt !== pm.w_blk_starts) fail("pm blocked periods != block starts");
        if (!XY_ONLY && pm.sw_total !== transitions) fail("pm sw_total != controller transitions");
        pm_write_summary;
        err_count = errors;
        $display("INFO: system xy_only=%0d: created=%0d dropped=%0d delivered=%0d max_inflight=%0d mode_changes=%0d mean_lat_net=%0d mean_lat_total=%0d (xy-mode %0d over %0d, adaptive %0d over %0d) min_excess_over_bound=%0d errors=%0d",
                 XY_ONLY, created_total, drop_sum, delivered_total, max_inflight, cov_trans,
                 lat_n_sum / (lat_cnt > 0 ? lat_cnt : 1), lat_t_sum / (lat_cnt > 0 ? lat_cnt : 1),
                 lat_n_sum_xy / (lat_cnt_xy > 0 ? lat_cnt_xy : 1), lat_cnt_xy, lat_n_sum_ad / (lat_cnt_ad > 0 ? lat_cnt_ad : 1), lat_cnt_ad, min_excess, errors);
        done = 1;
    end
endmodule

module tb_traffic_system;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    wire [1:0] dn; wire [31:0] e0, e1;
    sys_env #(.XY_ONLY(0), .SEED(7), .LOG_PKT("hys_packets.csv"), .LOG_SW("hys_switches.csv"), .LOG_BLK("hys_blocks.csv"), .LOG_SUM("hys_summary.txt"), .LOG_TAG("hysteroc"))  s0 (.clk(clk), .rst_n(rst_n), .done(dn[0]), .err_count(e0));
    sys_env #(.XY_ONLY(1), .SEED(8), .LOG_PKT("xy_packets.csv"), .LOG_SW("xy_switches.csv"), .LOG_BLK("xy_blocks.csv"), .LOG_SUM("xy_summary.txt"), .LOG_TAG("xy_only"))  s1 (.clk(clk), .rst_n(rst_n), .done(dn[1]), .err_count(e1));
    initial begin
        rst_n = 1'b0; repeat (4) @(posedge clk); #1 rst_n = 1'b1;
        wait (&dn); #5;
        if ((e0 + e1) == 0) $display("TB_RESULT: PASS");
        else $display("TB_RESULT: FAIL (%0d errors)", e0 + e1);
        $finish;
    end
    initial begin #3000000000; $display("TB_RESULT: FAIL (timeout)"); $finish; end
endmodule
