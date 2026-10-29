// =============================================================================
// tb_noc_top.v : mesh-level self-checking testbench for noc_top (Verilog-2001)
//
// Four complete 4x4 meshes (module mesh_env), one per configuration:
//   0 HYSTERoC            DUAL=1 USE_EWMA=1 (160/96)
//   1 XY-only reference   XY_ONLY=1
//   2 conventional hybrid DUAL=0 USE_EWMA=0 (raw occupancy, single threshold 128)
//   3 Ablation A          DUAL=0 USE_EWMA=1, mask 4, DRAIN_CONFIRM=1
// Each mesh has behavioural sources (obeying the block/ack protocol: a packet
// whose injection started is finished, no new packet while inject_block_req) and
// random-ready sinks. Traffic phases: uniform low, hot-spot with a slow sink,
// uniform medium, complement (all long paths), idle-ish with fast sinks.
//
// Checked every cycle (values sampled just before each clock edge):
//   * every packet that is delivered: reaches the node named in its header, is
//     exactly H,B,B,T in order, body/tail tags match (src,seq), packet existed
//     in the scoreboard exactly once (no duplication, no phantom)
//   * END-TO-END DRAIN CHECKS (independent of the DUT): flits accepted from the
//     sources minus flits ejected = in-flight; at every cycle with
//     network_drained, in-flight must be 0; whenever active_mode changes, in-flight
//     was 0 and every source idle; during DRAIN/SWITCH no source drives valid
//   * global_congestion = max of the 16 EWMA outputs; EWMA frozen outside RUN
//   * proto_err_any = alloc_err_any = drain_timeout = 0
//   * XY_ONLY: active_mode never leaves XY, no transition
//   * at the end: all created packets delivered, 4*created flits in and out,
//     all routers empty, controller back in RUN
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module mesh_env #(
    parameter XY_ONLY = 0,
    parameter DUAL = 1,
    parameter USE_EWMA = 1,
    parameter MASK = 0,
    parameter CONFIRM = 2,
    parameter SEED = 1,
    parameter CYCLES = 30000
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         done,
    output reg  [31:0] err_count
);
    // ---------------- DUT ----------------
    reg  [255:0] inj_data;  reg [31:0] inj_type;  reg [15:0] inj_valid;
    wire [15:0]  inj_ready;
    wire [255:0] ej_data;   wire [31:0] ej_type;  wire [15:0] ej_valid;
    reg  [15:0]  ej_ready;
    wire         inject_block_req;
    reg  [15:0]  inject_block_ack, src_empty;
    wire         active_mode, req_mode, transition_busy, drain_timeout, network_drained;
    wire [7:0]   global_congestion, global_raw;
    wire [2:0]   ctrl_state;
    wire [15:0]  router_empty;
    wire [239:0] fifo_occ_all;
    wire [127:0] ewma_all;
    wire         proto_err_any, alloc_err_any;
    wire [31:0]  cycle_cnt, tr_blocked, tr_ackwait, tr_drain, tot_blocked, tot_ackwait, tot_drain, transitions;
    wire [31:0]  t_block, t_ack, t_drained, t_switch, t_resume;

    noc_top #(.XY_ONLY(XY_ONLY), .DUAL(DUAL), .USE_EWMA(USE_EWMA),
              .POST_RESUME_MASK_CYCLES(MASK), .DRAIN_CONFIRM(CONFIRM)) dut (
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

    // ---------------- bookkeeping ----------------
    integer errors, seed, cycle;
    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors <= 8) $display("ERROR[xy=%0d dual=%0d ewma=%0d] @%0t: %0s", XY_ONLY, DUAL, USE_EWMA, $time, msg); end
    endtask

    // sources
    reg        s_in_pkt [0:15];
    integer    s_f [0:15];
    reg [7:0]  s_seq [0:15];
    reg [15:0] s_data [0:15];
    reg [1:0]  s_type [0:15];
    // scoreboard: [src*256+seq] -> dst node + 1 (0 = not outstanding)
    integer    sb [0:4095];
    // sinks
    integer    k_f [0:15];
    integer    k_src [0:15];
    integer    k_seq [0:15];
    // counters
    integer    created, delivered, inj_flits, ej_flits, inflight, max_inflight;
    integer    cov_modes_adapt_cycles, cov_trans_done, cov_drain_with_flits_before;
    // phase control
    integer    p_start, p_ready, p_hot_ready, pat;
    reg        gen_en;
    integer    n, q, r, d;

    // freeze checking
    reg [127:0] prev_ewma;
    reg         prev_active;
    reg [2:0]   prev_state;
    integer     prev_inflight;
    reg [15:0]  prev_src_idle;

    function [3:0] pick_dst;
        input integer src;
        input integer pattern;
        integer rr, x, y;
        begin
            rr = $random(seed); if (rr < 0) rr = -rr;
            x = src % 4; y = src / 4;
            case (pattern)
                1: pick_dst = (rr % 100 < 70) ? 5 : (rr / 100) % 16;                // hot spot node 5
                3: pick_dst = (3 - x) + 4 * (3 - y);                                  // complement
                default: pick_dst = rr % 16;                                          // uniform
            endcase
        end
    endfunction

    task start_packet;
        input integer s;
        reg [3:0] dd;
        reg [7:0] sq;
        begin
            dd = pick_dst(s, pat);
            sq = s_seq[s];
            if (sb[s*256 + sq] != 0) fail("scoreboard slot reused while outstanding");
            sb[s*256 + sq] = dd + 1;
            s_data[s] = {dd[1:0], dd[3:2], s[1:0], s[3:2], sq};
            s_type[s] = `HY_FT_HEADER; s_f[s] = 0; s_in_pkt[s] = 1'b1;
            created = created + 1;
        end
    endtask

    task set_flit;
        input integer s;
        begin
            if (s_f[s] == 0) begin end   // header already built
            else begin
                s_data[s] = {s[3:0], s_seq[s], s_f[s][1:0], 2'b00};
                s_type[s] = (s_f[s] == 3) ? `HY_FT_TAIL : `HY_FT_BODY;
            end
        end
    endtask

    // ---------------- negedge: drive inputs ----------------
    integer idle_cnt;
    always @(negedge clk) if (rst_n) begin
        for (n = 0; n < 16; n = n + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            // start a new packet only when allowed
            if (!s_in_pkt[n] && gen_en && !inject_block_req && (r % 1000) < p_start * 10) begin
                start_packet(n);
            end
            // mid-packet bubbles
            if (s_in_pkt[n]) begin
                r = $random(seed); if (r < 0) r = -r;
                if (inj_valid[n] && !inj_ready[n]) begin end                 // hold while stalled
                else if (s_f[n] != 0 && (r % 100) < 8) inj_valid[n] = 1'b0;   // bubble before a body/tail flit
                else inj_valid[n] = 1'b1;
                inj_data[16*n +: 16] = s_data[n];
                inj_type[2*n +: 2]   = s_type[n];
            end else begin
                inj_valid[n] = 1'b0;
                inj_data[16*n +: 16] = $random(seed);
                inj_type[2*n +: 2]   = $random(seed);
            end
            src_empty[n]         = !s_in_pkt[n];
            inject_block_ack[n]  = inject_block_req && !s_in_pkt[n];
            // sinks
            r = $random(seed); if (r < 0) r = -r;
            ej_ready[n] = ((r % 100) < ((n == 5 && pat == 1) ? p_hot_ready : p_ready));
        end
    end

    // ---------------- posedge: sample pre-edge values, update scoreboard ----------------
    reg [15:0] acc_inj, acc_ej;
    reg [7:0]  mx;
    integer    kk;
    always @(posedge clk) begin
        if (!rst_n) begin
            // nothing
        end else begin
            cycle = cycle + 1;
            acc_inj = inj_valid & inj_ready;
            acc_ej  = ej_valid & ej_ready;

            // ---- checks on the cycle that is ending ----
            if (proto_err_any) fail("proto_err_any");
            if (alloc_err_any) fail("alloc_err_any");
            if (drain_timeout) fail("drain_timeout in legal traffic");
            if (network_drained && inflight != 0) fail("network_drained with flits in flight");
            if ((ctrl_state == 3 || ctrl_state == 4) && (inj_valid != 16'h0)) fail("source injecting during DRAIN/SWITCH");
            if (ctrl_state == 4 && network_drained && (src_empty != 16'hFFFF)) fail("switching with busy source");
            // sideband wiring: router n, direction d must see the occupancy of the neighbour
            // FIFO that faces it (independent index arithmetic, hierarchical read of the wire)
            for (kk = 0; kk < 16; kk = kk + 1) begin : sbchk
                integer xx, yy, nb;
                xx = kk % 4; yy = kk / 4;
                if (yy > 0) begin nb = kk - 4; if (dut.r_nbr_occ[12*kk + 0 +: 3] !== fifo_occ_all[15*nb + 3*1 +: 3]) fail("sideband N wiring"); end
                else if (dut.r_nbr_occ[12*kk + 0 +: 3] !== 3'd0) fail("sideband N boundary");
                if (yy < 3) begin nb = kk + 4; if (dut.r_nbr_occ[12*kk + 3 +: 3] !== fifo_occ_all[15*nb + 3*0 +: 3]) fail("sideband S wiring"); end
                else if (dut.r_nbr_occ[12*kk + 3 +: 3] !== 3'd0) fail("sideband S boundary");
                if (xx < 3) begin nb = kk + 1; if (dut.r_nbr_occ[12*kk + 6 +: 3] !== fifo_occ_all[15*nb + 3*3 +: 3]) fail("sideband E wiring"); end
                else if (dut.r_nbr_occ[12*kk + 6 +: 3] !== 3'd0) fail("sideband E boundary");
                if (xx > 0) begin nb = kk - 1; if (dut.r_nbr_occ[12*kk + 9 +: 3] !== fifo_occ_all[15*nb + 3*2 +: 3]) fail("sideband W wiring"); end
                else if (dut.r_nbr_occ[12*kk + 9 +: 3] !== 3'd0) fail("sideband W boundary");
            end
            // global max
            mx = 0;
            for (kk = 0; kk < 16; kk = kk + 1) if (ewma_all[8*kk +: 8] > mx) mx = ewma_all[8*kk +: 8];
            if (global_congestion !== mx) fail("global_congestion != max(ewma)");
            if (prev_state !== 3'd0 && ewma_all !== prev_ewma && prev_state !== 3'bxxx) begin
                // EWMA must not change when the previous cycle was outside RUN
                fail("EWMA changed outside RUN");
            end
            // mode change observed against previous cycle
            if (active_mode !== prev_active) begin
                if (prev_inflight != 0) fail("active_mode changed with flits in flight");
                if (prev_src_idle != 16'hFFFF) fail("active_mode changed with a source busy");
                cov_trans_done = cov_trans_done + 1;
                if (XY_ONLY) fail("XY_ONLY changed mode");
            end
            if (active_mode) cov_modes_adapt_cycles = cov_modes_adapt_cycles + 1;

            prev_ewma = ewma_all; prev_active = active_mode; prev_state = ctrl_state;
            prev_inflight = inflight; prev_src_idle = src_empty;

            // ---- sources: accepted transfers ----
            for (kk = 0; kk < 16; kk = kk + 1) begin
                if (acc_inj[kk]) begin
                    inj_flits = inj_flits + 1; inflight = inflight + 1;
                    if (s_f[kk] == 3) begin s_in_pkt[kk] = 1'b0; s_seq[kk] = s_seq[kk] + 1; end
                    else begin s_f[kk] = s_f[kk] + 1; set_flit(kk); end
                end
            end
            // ---- sinks ----
            for (kk = 0; kk < 16; kk = kk + 1) begin
                if (acc_ej[kk]) begin
                    ej_flits = ej_flits + 1; inflight = inflight - 1;
                    begin : sink
                        reg [15:0] dd; reg [1:0] tt; integer sn, sq;
                        dd = ej_data[16*kk +: 16]; tt = ej_type[2*kk +: 2];
                        if (k_f[kk] == 0) begin
                            if (tt !== `HY_FT_HEADER) fail("packet does not start with header");
                            else begin
                                sn = dd[11:10] + 4*dd[9:8]; sq = dd[7:0];
                                if (dd[15:14] !== (kk % 4) || dd[13:12] !== (kk / 4)) fail("packet delivered to wrong node");
                                if (sb[sn*256 + sq] != kk + 1) fail("delivered packet not in scoreboard / wrong dst (dup or phantom)");
                                k_src[kk] = sn; k_seq[kk] = sq; k_f[kk] = 1;
                            end
                        end else begin
                            if (dd !== {k_src[kk][3:0], k_seq[kk][7:0], k_f[kk][1:0], 2'b00}) fail("body/tail tag mismatch (interleave/loss)");
                            if (tt !== ((k_f[kk] == 3) ? `HY_FT_TAIL : `HY_FT_BODY)) fail("flit type order");
                            if (k_f[kk] == 3) begin
                                sb[k_src[kk]*256 + k_seq[kk]] = 0;
                                delivered = delivered + 1; k_f[kk] = 0;
                            end else k_f[kk] = k_f[kk] + 1;
                        end
                    end
                end
            end
            if (inflight > max_inflight) max_inflight = inflight;
        end
    end

    // every router must see the ONE shared mode and EWMA enable (no private copies)
    genvar gyy, gxx;
    generate
        for (gyy = 0; gyy < 4; gyy = gyy + 1) begin : chk_y
            for (gxx = 0; gxx < 4; gxx = gxx + 1) begin : chk_x
                always @(posedge clk) if (rst_n) begin
                    if (dut.g_y[gyy].g_x[gxx].u_router.active_mode !== active_mode) fail("router sees a different active_mode");
                    if (dut.g_y[gyy].g_x[gxx].u_router.ewma_enable !== (ctrl_state == 3'd0)) fail("router ewma_enable != (state==RUN)");
                end
            end
        end
    endgenerate

    // ---------------- main sequence ----------------
    integer ph, guard;
    initial begin
        done = 1'b0; err_count = 0; errors = 0; seed = SEED; cycle = 0;
        created = 0; delivered = 0; inj_flits = 0; ej_flits = 0; inflight = 0; max_inflight = 0;
        cov_modes_adapt_cycles = 0; cov_trans_done = 0; cov_drain_with_flits_before = 0;
        gen_en = 1'b0; p_start = 0; p_ready = 100; p_hot_ready = 100; pat = 0;
        inj_data = 0; inj_type = 0; inj_valid = 0; ej_ready = 0; inject_block_ack = 0; src_empty = 16'hFFFF;
        prev_ewma = 0; prev_active = 0; prev_state = 0; prev_inflight = 0; prev_src_idle = 16'hFFFF;
        for (n = 0; n < 16; n = n + 1) begin s_in_pkt[n] = 0; s_f[n] = 0; s_seq[n] = 0; s_data[n] = 0; s_type[n] = 0; k_f[n] = 0; k_src[n] = 0; k_seq[n] = 0; end
        for (n = 0; n < 4096; n = n + 1) sb[n] = 0;
        wait (rst_n === 1'b1);
        repeat (3) @(negedge clk);
        gen_en = 1'b1;
        while (cycle < CYCLES) begin
            ph = (cycle / 3000) % 5;
            case (ph)
                0: begin pat = 0; p_start = 3;  p_ready = 90;  p_hot_ready = 90; end
                1: begin pat = 1; p_start = 40; p_ready = 70;  p_hot_ready = 20; end
                2: begin pat = 0; p_start = 10; p_ready = 80;  p_hot_ready = 80; end
                3: begin pat = 3; p_start = 30; p_ready = 60;  p_hot_ready = 60; end
                default: begin pat = 0; p_start = 1; p_ready = 100; p_hot_ready = 100; end
            endcase
            @(negedge clk);
            if (cycle % 5000 == 0) $display("PROGRESS xy=%0d dual=%0d ewma=%0d cycle=%0d created=%0d delivered=%0d inflight=%0d mode=%0d trans=%0d", XY_ONLY, DUAL, USE_EWMA, cycle, created, delivered, inflight, active_mode, transitions);
        end
        // ---------------- drain everything ----------------
        gen_en = 1'b0; p_ready = 100; p_hot_ready = 100; pat = 0;
        guard = 0;
        while (guard < 30000 && !(inflight == 0 && created == delivered && src_empty == 16'hFFFF && ctrl_state == 3'd0 && req_mode == active_mode && global_congestion == 8'd0)) begin
            @(negedge clk); guard = guard + 1;
        end
        repeat (10) @(negedge clk);
        if (created != delivered) fail("packets missing at end");
        if (inj_flits != 4 * created || ej_flits != 4 * created) fail("flit counts at end");
        if (inflight != 0) fail("inflight != 0 at end");
        if (router_empty !== 16'hFFFF) fail("routers not empty at end");
        if (ctrl_state !== 3'd0) fail("controller not back in RUN");
        if (XY_ONLY && transitions !== 0) fail("XY_ONLY transitions != 0");
        if (!XY_ONLY && cov_trans_done == 0) fail("no mode transition occurred (coverage)");
        err_count = errors;
        $display("INFO: mesh xy_only=%0d dual=%0d ewma=%0d mask=%0d: cycles=%0d created=%0d delivered=%0d max_inflight_flits=%0d mode_changes=%0d ctrl_transitions=%0d adaptive_cycles=%0d tot_blocked=%0d tot_drain=%0d errors=%0d",
                 XY_ONLY, DUAL, USE_EWMA, MASK, cycle, created, delivered, max_inflight, cov_trans_done, transitions,
                 cov_modes_adapt_cycles, tot_blocked, tot_drain, errors);
        done = 1'b1;
    end
endmodule

module tb_noc_top;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    wire [3:0] dn;
    wire [31:0] e0, e1, e2, e3;

    mesh_env #(.XY_ONLY(0), .DUAL(1), .USE_EWMA(1), .MASK(0), .CONFIRM(2), .SEED(101)) m0 (.clk(clk), .rst_n(rst_n), .done(dn[0]), .err_count(e0));
    mesh_env #(.XY_ONLY(1), .DUAL(1), .USE_EWMA(1), .MASK(0), .CONFIRM(2), .SEED(102)) m1 (.clk(clk), .rst_n(rst_n), .done(dn[1]), .err_count(e1));
    mesh_env #(.XY_ONLY(0), .DUAL(0), .USE_EWMA(0), .MASK(0), .CONFIRM(2), .SEED(103)) m2 (.clk(clk), .rst_n(rst_n), .done(dn[2]), .err_count(e2));
    mesh_env #(.XY_ONLY(0), .DUAL(0), .USE_EWMA(1), .MASK(4), .CONFIRM(1), .SEED(104)) m3 (.clk(clk), .rst_n(rst_n), .done(dn[3]), .err_count(e3));

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        wait (&dn);
        #5;
        if ((e0 + e1 + e2 + e3) == 0) $display("TB_RESULT: PASS");
        else $display("TB_RESULT: FAIL (%0d errors)", e0 + e1 + e2 + e3);
        $finish;
    end
    initial begin
        #2000000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
