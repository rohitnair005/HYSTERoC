// =============================================================================
// tb_switch_allocator.v : self-checking testbench for switch_allocator,
// crossbar and their cooperation with five packet_tracker instances.
//
// Part A  (raw)   : switch_allocator driven with random, even illegal, request /
//                   reservation vectors; compared EVERY cycle with an independent
//                   behavioural reference (module alloc_ref below) that has its
//                   own round-robin pointers. Includes directed alloc_err cases.
// Part B  (system): 5 emulated FIFO heads -> 5 packet_tracker -> allocator ->
//                   crossbar -> 5 emulated output links with random ready.
//                   Legal 4-flit packets with random route_port per input
//                   (changing every cycle while a header stalls).
//                   Checks per cycle: DUT == reference, one input per output,
//                   no transfer without out_ready, crossbar data = selected
//                   input data. Checks per packet: output atomicity (no
//                   interleaving), same output for H,B,B,T, in-order, no loss,
//                   no duplication, reservation held under backpressure.
//                   Fairness: 5 inputs contending for one output share it
//                   within +-1 packet.
// Part C  (xbar)  : crossbar exhaustive over all 6^5 select patterns.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

// ---------------------------------------------------------------------------
// independent reference model of the allocator (behavioural, loops, integers)
// ---------------------------------------------------------------------------
module alloc_ref (
    input  wire        clk, rst_n,
    input  wire [4:0]  req_valid, req_new,
    input  wire [24:0] req_port,
    input  wire [4:0]  locked,
    input  wire [24:0] locked_port,
    input  wire [4:0]  out_ready,
    output reg  [4:0]  in_grant,
    output reg  [24:0] xbar_sel,
    output reg  [4:0]  out_busy,
    output reg         alloc_err
);
    integer ptr [0:4];
    integer o, i, k, w, nown, nsel;
    reg [4:0] own [0:4];
    reg [4:0] want;
    reg [4:0] pick;
    reg       fire;
    integer   winner [0:4];

    always @(*) begin
        in_grant = 5'b0; xbar_sel = 25'b0; out_busy = 5'b0; alloc_err = 1'b0;
        for (o = 0; o < 5; o = o + 1) begin
            nown = 0; own[o] = 5'b0;
            for (i = 0; i < 5; i = i + 1)
                if (locked[i] && locked_port[5*i+o]) begin nown = nown + 1; own[o][i] = 1'b1; end
            out_busy[o] = (nown > 0);
            if (nown > 1) alloc_err = 1'b1;
            pick = 5'b0; winner[o] = -1;
            if (nown > 0) begin
                for (i = 0; i < 5; i = i + 1) pick[i] = own[o][i] && req_valid[i];
            end else begin
                want = 5'b0;
                for (i = 0; i < 5; i = i + 1) want[i] = req_new[i] && req_port[5*i+o];
                for (k = 0; k < 5; k = k + 1) begin
                    w = (ptr[o] + k) % 5;
                    if (winner[o] < 0 && want[w]) winner[o] = w;
                end
                if (winner[o] >= 0) pick[winner[o]] = 1'b1;
            end
            nsel = 0;
            for (i = 0; i < 5; i = i + 1) if (pick[i]) nsel = nsel + 1;
            if (nsel > 1) alloc_err = 1'b1;
            fire = (nsel > 0) && out_ready[o];
            if (fire) begin
                for (i = 0; i < 5; i = i + 1) begin
                    xbar_sel[5*o+i] = pick[i];
                    if (pick[i]) in_grant[i] = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            for (o = 0; o < 5; o = o + 1) ptr[o] <= 0;
        end else begin
            for (o = 0; o < 5; o = o + 1)
                if (xbar_sel[5*o +: 5] != 5'b0 && winner[o] >= 0)
                    ptr[o] <= (winner[o] + 1) % 5;
        end
    end

    initial for (o = 0; o < 5; o = o + 1) ptr[o] = 0;
endmodule

module tb_switch_allocator;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors;
    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 25) $display("ERROR @%0t: %0s", $time, msg);
        end
    endtask

    // =====================================================================
    // Part A : raw allocator vs reference
    // =====================================================================
    reg  [4:0]  a_req_valid, a_req_new, a_locked, a_out_ready;
    reg  [24:0] a_req_port, a_locked_port;
    wire [4:0]  a_in_grant, a_busy;  wire [24:0] a_sel;  wire a_err;
    wire [4:0]  r_in_grant, r_busy;  wire [24:0] r_sel;  wire r_err;

    switch_allocator dutA (.clk(clk), .rst_n(rst_n),
        .req_valid(a_req_valid), .req_new(a_req_new), .req_port(a_req_port),
        .locked(a_locked), .locked_port(a_locked_port), .out_ready(a_out_ready),
        .in_grant(a_in_grant), .xbar_sel(a_sel), .out_busy(a_busy), .alloc_err(a_err));
    alloc_ref refA (.clk(clk), .rst_n(rst_n),
        .req_valid(a_req_valid), .req_new(a_req_new), .req_port(a_req_port),
        .locked(a_locked), .locked_port(a_locked_port), .out_ready(a_out_ready),
        .in_grant(r_in_grant), .xbar_sel(r_sel), .out_busy(r_busy), .alloc_err(r_err));

    integer seed, r, n, cA, errA_seen, a_err_cycles, a_contended, a_stalled_win;
    integer ii;

    function [4:0] onehot5;
        input integer rr;
        begin
            case (rr % 5)
                0: onehot5 = 5'b00001; 1: onehot5 = 5'b00010; 2: onehot5 = 5'b00100;
                3: onehot5 = 5'b01000; default: onehot5 = 5'b10000;
            endcase
        end
    endfunction

    task a_cycle;
        begin
            #1;
            cA = cA + 1;
            if (a_in_grant !== r_in_grant) fail("A in_grant");
            if (a_sel      !== r_sel)      fail("A xbar_sel");
            if (a_busy     !== r_busy)     fail("A out_busy");
            if (a_err      !== r_err)      fail("A alloc_err");
            if (r_err) a_err_cycles = a_err_cycles + 1;
            @(posedge clk); #1;
        end
    endtask

    // random raw vector. mode 0 = consistent-ish (new only if unlocked), 1 = fully random
    task a_randomize;
        input integer legalish;
        integer q;
        begin
            a_req_valid = $random(seed); a_req_new = $random(seed);
            a_locked = $random(seed); a_out_ready = $random(seed);
            for (q = 0; q < 5; q = q + 1) begin
                r = $random(seed); if (r < 0) r = -r;
                a_req_port[5*q +: 5]    = (r % 7 == 0) ? 5'b0 : onehot5(r / 7);
                r = $random(seed); if (r < 0) r = -r;
                a_locked_port[5*q +: 5] = onehot5(r);
            end
            if (legalish) begin
                a_req_new = a_req_new & ~a_locked & a_req_valid;      // headers only when unlocked
                // keep one owner per output
                for (q = 0; q < 5; q = q + 1)
                    for (ii = 0; ii < q; ii = ii + 1)
                        if (a_locked[q] && a_locked[ii] && (a_locked_port[5*q +: 5] == a_locked_port[5*ii +: 5]))
                            a_locked[q] = 1'b0;
            end
        end
    endtask

    // =====================================================================
    // Part B : system (trackers + allocator + crossbar)
    // =====================================================================
    reg         h_valid [0:4];
    reg  [1:0]  h_type  [0:4];
    reg  [15:0] h_data  [0:4];
    reg  [4:0]  h_route [0:4];
    wire [4:0]  tr_req_valid, tr_req_new, tr_locked;
    wire [24:0] tr_req_port, tr_locked_port;
    wire [4:0]  tr_err;
    wire [4:0]  b_in_grant, b_busy, br_in_grant, br_busy;
    wire [24:0] b_sel, br_sel;
    wire        b_err, br_err;
    reg  [4:0]  b_out_ready;
    wire [79:0] x_in_data; wire [9:0] x_in_type;
    wire [79:0] x_out_data; wire [9:0] x_out_type; wire [4:0] x_out_valid;

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : g_tr
            wire [4:0] rq_port, lk_port; wire rq_v, rq_n, lk, pe;
            packet_tracker u_tr (.clk(clk), .rst_n(rst_n),
                .head_valid(h_valid[gi]), .head_type(h_type[gi]), .head_data(h_data[gi]),
                .route_port(h_route[gi]), .xfer(b_in_grant[gi]),
                .hdr_dst_x(), .hdr_dst_y(), .hdr_src_x(), .hdr_src_y(),
                .req_valid(rq_v), .req_port(rq_port), .req_new(rq_n),
                .locked(lk), .locked_port(lk_port), .proto_err(pe));
            assign tr_req_valid[gi] = rq_v;
            assign tr_req_new[gi]   = rq_n;
            assign tr_req_port[5*gi +: 5] = rq_port;
            assign tr_locked[gi]    = lk;
            assign tr_locked_port[5*gi +: 5] = lk_port;
            assign tr_err[gi]       = pe;
            assign x_in_data[16*gi +: 16] = h_data[gi];
            assign x_in_type[2*gi +: 2]   = h_type[gi];
        end
    endgenerate

    switch_allocator dutB (.clk(clk), .rst_n(rst_n),
        .req_valid(tr_req_valid), .req_new(tr_req_new), .req_port(tr_req_port),
        .locked(tr_locked), .locked_port(tr_locked_port), .out_ready(b_out_ready),
        .in_grant(b_in_grant), .xbar_sel(b_sel), .out_busy(b_busy), .alloc_err(b_err));
    alloc_ref refB (.clk(clk), .rst_n(rst_n),
        .req_valid(tr_req_valid), .req_new(tr_req_new), .req_port(tr_req_port),
        .locked(tr_locked), .locked_port(tr_locked_port), .out_ready(b_out_ready),
        .in_grant(br_in_grant), .xbar_sel(br_sel), .out_busy(br_busy), .alloc_err(br_err));
    crossbar dutX (.in_data(x_in_data), .in_type(x_in_type), .sel(b_sel),
        .out_data(x_out_data), .out_type(x_out_type), .out_valid(x_out_valid));

    // per-input stream state
    reg        i_has [0:4];
    integer    i_f [0:4];
    integer    i_serial [0:4];
    // per-input delivery tracking (what the outputs have seen)
    integer    d_next_f [0:4];
    integer    d_serial [0:4];
    integer    d_out [0:4];          // output of the packet in flight, -1 none
    // per-output packet atomicity
    integer    o_src [0:4];          // input that owns the open packet, -1 none
    integer    o_flits [0:4];
    integer    pk_count [0:4];       // packets completed per input
    integer    b_cycles, n_pk_done, n_stall_hold, n_backpressure_cycles, n_contend, n_sim_outputs;
    integer    force_en, force_idx;
    integer    p_valid, p_ready;
    integer    q, oo, s, src_i;
    reg [4:0]  rp;

    function integer popc5;
        input [4:0] v;
        begin popc5 = v[0] + v[1] + v[2] + v[3] + v[4]; end
    endfunction

    task b_set_head;
        input integer p;
        begin
            h_valid[p] = i_has[p];
            h_type[p]  = (i_f[p] == 0) ? `HY_FT_HEADER : (i_f[p] == 3) ? `HY_FT_TAIL : `HY_FT_BODY;
            h_data[p]  = {p[2:0], i_serial[p][10:0], i_f[p][1:0]};
        end
    endtask

    task b_cycle;
        integer p, e;
        reg [4:0] gsave;
        reg [2:0] sp; reg [10:0] ss; reg [1:0] sf;
        begin
            // present heads and random route_port
            for (p = 0; p < 5; p = p + 1) begin
                if (!i_has[p]) begin
                    r = $random(seed); if (r < 0) r = -r;
                    if ((r % 100) < p_valid) i_has[p] = 1'b1;
                end
                b_set_head(p);
                r = $random(seed); if (r < 0) r = -r;
                rp = (r % 9 == 0) ? 5'b0 : onehot5(r / 9);
                if (force_en) rp = (force_idx == 99) ? `HY_PM_E : rp;
                h_route[p] = rp;
            end
            for (p = 0; p < 5; p = p + 1) begin
                r = $random(seed); if (r < 0) r = -r;
                b_out_ready[p] = ((r % 100) < p_ready);
            end
            #1;
            b_cycles = b_cycles + 1;
            // DUT vs reference
            if (b_in_grant !== br_in_grant) fail("B in_grant vs ref");
            if (b_sel      !== br_sel)      fail("B xbar_sel vs ref");
            if (b_busy     !== br_busy)     fail("B busy vs ref");
            if (b_err !== 1'b0)             fail("B alloc_err in legal run");
            if (tr_err !== 5'b0)            fail("B proto_err in legal run");
            for (e = 0; e < 5; e = e + 1) begin
                // one input per output, only if ready
                if (popc5(b_sel[5*e +: 5]) > 1) fail("B two inputs on one output");
                if (b_sel[5*e +: 5] != 0 && !b_out_ready[e]) fail("B transfer without ready");
                if (x_out_valid[e] !== (b_sel[5*e +: 5] != 0)) fail("B xbar valid");
                if (b_busy[e] && b_out_ready[e] == 0) n_backpressure_cycles = n_backpressure_cycles + 1;
            end
            // each input used by at most one output and consistent with in_grant
            for (p = 0; p < 5; p = p + 1) begin
                s = 0;
                for (e = 0; e < 5; e = e + 1) s = s + b_sel[5*e+p];
                if (s > 1) fail("B input drives two outputs");
                if (b_in_grant[p] !== (s == 1)) fail("B in_grant != sel");
            end
            // output side checks
            for (e = 0; e < 5; e = e + 1) begin
                if (x_out_valid[e]) begin
                    sp = x_out_data[16*e+13 +: 3]; ss = x_out_data[16*e+2 +: 11]; sf = x_out_data[16*e +: 2];
                    src_i = sp;
                    if (src_i > 4) fail("B bad source in data");
                    else begin
                        // crossbar carried the selected input's flit
                        if (!b_sel[5*e+src_i]) fail("B data from unselected input");
                        if (x_out_data[16*e +: 16] !== h_data[src_i]) fail("B xbar data");
                        if (x_out_type[2*e +: 2]   !== h_type[src_i]) fail("B xbar type");
                        // per-input in-order, no loss / duplicate
                        if (sf !== d_next_f[src_i][1:0]) fail("B flit order/dup/loss (f)");
                        if (ss !== d_serial[src_i][10:0]) fail("B flit order/dup/loss (serial)");
                        // packet atomicity + single output per packet
                        if (sf == 2'd0) begin
                            if (o_src[e] != -1) fail("B header while output has open packet");
                            o_src[e] = src_i; o_flits[e] = 1; d_out[src_i] = e;
                        end else begin
                            if (o_src[e] != src_i) fail("B interleaved packets on output");
                            if (d_out[src_i] != e) fail("B packet changed output");
                            o_flits[e] = o_flits[e] + 1;
                        end
                        if (sf == 2'd3) begin
                            if (o_flits[e] != 4) fail("B packet length != 4");
                            o_src[e] = -1;
                            pk_count[src_i] = pk_count[src_i] + 1; n_pk_done = n_pk_done + 1;
                            d_next_f[src_i] = 0; d_serial[src_i] = d_serial[src_i] + 1;
                        end else begin
                            d_next_f[src_i] = d_next_f[src_i] + 1;
                        end
                    end
                end
                // reservation held while stalled: busy stays set until tail passes
                if (o_src[e] != -1 && b_busy[e] !== 1'b1 && x_out_valid[e] !== 1'b1)
                    fail("B reservation dropped mid-packet");
                if (o_src[e] != -1 && !b_out_ready[e]) n_stall_hold = n_stall_hold + 1;
            end
            if (popc5(b_in_grant) > 1) n_sim_outputs = n_sim_outputs + 1;
            if (popc5(tr_req_valid & tr_req_new) > 1) n_contend = n_contend + 1;
            gsave = b_in_grant;
            @(posedge clk); #1;
            // advance input streams for accepted flits
            for (p = 0; p < 5; p = p + 1) begin
                if (gsave[p]) begin
                    i_has[p] = 1'b0;
                    if (i_f[p] == 3) begin i_f[p] = 0; i_serial[p] = i_serial[p] + 1; end
                    else i_f[p] = i_f[p] + 1;
                end
            end
        end
    endtask

    task b_reset_streams;
        integer p;
        begin
            for (p = 0; p < 5; p = p + 1) begin
                i_has[p] = 0; i_f[p] = 0; i_serial[p] = 0;
                d_next_f[p] = 0; d_serial[p] = 0; d_out[p] = -1;
                o_src[p] = -1; o_flits[p] = 0; pk_count[p] = 0;
            end
        end
    endtask

    // =====================================================================
    // Part C : crossbar exhaustive
    // =====================================================================
    reg  [79:0] c_in_data; reg [9:0] c_in_type; reg [24:0] c_sel;
    wire [79:0] c_out_data; wire [9:0] c_out_type; wire [4:0] c_out_valid;
    crossbar dutC (.in_data(c_in_data), .in_type(c_in_type), .sel(c_sel),
                   .out_data(c_out_data), .out_type(c_out_type), .out_valid(c_out_valid));
    integer c_idx, c_t, c_o, c_i, c_sv [0:4], c_cases;
    reg [15:0] c_exp_d; reg [1:0] c_exp_t;

    // =====================================================================
    integer cyc, pk_min, pk_max, pp;
    initial begin
        errors = 0; seed = 32'h5EED1234; cA = 0; a_err_cycles = 0; errA_seen = 0;
        b_cycles = 0; n_pk_done = 0; n_stall_hold = 0; n_backpressure_cycles = 0;
        n_contend = 0; n_sim_outputs = 0; force_en = 0; force_idx = 0; p_valid = 100; p_ready = 100;
        a_req_valid = 0; a_req_new = 0; a_locked = 0; a_out_ready = 0; a_req_port = 0; a_locked_port = 0;
        b_out_ready = 0;
        for (pp = 0; pp < 5; pp = pp + 1) begin h_valid[pp] = 0; h_type[pp] = 0; h_data[pp] = 0; h_route[pp] = 0; end
        b_reset_streams;
        rst_n = 1'b0;
        repeat (3) @(posedge clk); #1;
        rst_n = 1'b1;

        // ---------------- Part A directed ----------------
        // single header to E from input 0, ready
        a_req_valid = 5'b00001; a_req_new = 5'b00001; a_req_port = 25'd0; a_req_port[4:0] = 5'b00100;
        a_out_ready = 5'b11111; a_locked = 0; a_locked_port = 0;
        #1; if (a_sel !== 25'b0000000000000000000000000 + (25'd1 << 10)) fail("A1 header grant"); 
        if (a_in_grant !== 5'b00001) fail("A1 in_grant");
        @(posedge clk); #1;
        // not ready: no grant
        a_out_ready = 5'b11011; #1;
        if (a_in_grant !== 5'b0) fail("A2 grant without ready");
        @(posedge clk); #1;
        // two owners on one output -> alloc_err
        a_req_new = 0; a_req_valid = 5'b00011; a_locked = 5'b00011;
        a_locked_port = 0; a_locked_port[4:0] = 5'b00100; a_locked_port[9:5] = 5'b00100; a_out_ready = 5'b11111;
        #1; if (a_err !== 1'b1) fail("A3 alloc_err not raised for two owners");
        @(posedge clk); #1;
        // busy output not offered: input 2 header to E while input 0 owns E
        a_locked = 5'b00001; a_req_valid = 5'b00101; a_req_new = 5'b00100;
        a_req_port = 0; a_req_port[14:10] = 5'b00100; a_locked_port = 0; a_locked_port[4:0] = 5'b00100;
        a_out_ready = 5'b11111; #1;
        if (a_in_grant !== 5'b00001) fail("A4 busy output granted to second input");
        a_cycle;

        // ---------------- Part A random ----------------
        for (n = 0; n < 40000; n = n + 1) begin a_randomize(1); a_cycle; end
        for (n = 0; n < 40000; n = n + 1) begin a_randomize(0); a_cycle; end

        // ---------------- Part B ----------------
        b_reset_streams;
        rst_n = 1'b0; repeat (2) @(posedge clk); #1; rst_n = 1'b1;
        p_valid = 100; p_ready = 100; for (cyc = 0; cyc < 8000; cyc = cyc + 1) b_cycle;
        p_valid = 100; p_ready = 40;  for (cyc = 0; cyc < 12000; cyc = cyc + 1) b_cycle;
        p_valid = 40;  p_ready = 80;  for (cyc = 0; cyc < 12000; cyc = cyc + 1) b_cycle;
        p_valid = 70;  p_ready = 15;  for (cyc = 0; cyc < 12000; cyc = cyc + 1) b_cycle;
        p_valid = 90;  p_ready = 60;  for (cyc = 0; cyc < 12000; cyc = cyc + 1) b_cycle;

        // fairness: all five contend for East, always ready
        b_reset_streams;
        rst_n = 1'b0; repeat (2) @(posedge clk); #1; rst_n = 1'b1;
        // drain any stale state by running until all streams are at packet boundaries
        force_en = 1; force_idx = 99; p_valid = 100; p_ready = 100;
        for (cyc = 0; cyc < 4000; cyc = cyc + 1) b_cycle;
        pk_min = pk_count[0]; pk_max = pk_count[0];
        for (pp = 1; pp < 5; pp = pp + 1) begin
            if (pk_count[pp] < pk_min) pk_min = pk_count[pp];
            if (pk_count[pp] > pk_max) pk_max = pk_count[pp];
        end
        $display("INFO: fairness packets per input = %0d %0d %0d %0d %0d", pk_count[0], pk_count[1], pk_count[2], pk_count[3], pk_count[4]);
        if (pk_max - pk_min > 1) fail("B fairness: unequal share of contended output");
        if (pk_min < 100)        fail("B fairness: too few packets delivered");
        force_en = 0;

        // ---------------- Part C ----------------
        c_cases = 0;
        for (c_t = 0; c_t < 7776; c_t = c_t + 1) begin    // 6^5 patterns
            c_idx = c_t;
            for (c_o = 0; c_o < 5; c_o = c_o + 1) begin c_sv[c_o] = c_idx % 6; c_idx = c_idx / 6; end
            c_sel = 25'b0;
            for (c_o = 0; c_o < 5; c_o = c_o + 1)
                if (c_sv[c_o] < 5) c_sel[5*c_o + c_sv[c_o]] = 1'b1;
            for (c_i = 0; c_i < 5; c_i = c_i + 1) begin
                c_in_data[16*c_i +: 16] = $random(seed);
                c_in_type[2*c_i +: 2]   = $random(seed);
            end
            #1;
            for (c_o = 0; c_o < 5; c_o = c_o + 1) begin
                if (c_sv[c_o] < 5) begin
                    c_exp_d = c_in_data[16*c_sv[c_o] +: 16]; c_exp_t = c_in_type[2*c_sv[c_o] +: 2];
                end else begin c_exp_d = 16'h0; c_exp_t = 2'b00; end
                if (c_out_data[16*c_o +: 16] !== c_exp_d) fail("C data");
                if (c_out_type[2*c_o +: 2]   !== c_exp_t) fail("C type");
                if (c_out_valid[c_o] !== (c_sv[c_o] < 5)) fail("C valid");
            end
            c_cases = c_cases + 1;
        end

        $display("INFO: A cycles=%0d (alloc_err cycles=%0d)  B cycles=%0d packets=%0d  C patterns=%0d",
                 cA, a_err_cycles, b_cycles, n_pk_done, c_cases);
        $display("INFO: B coverage contended_cycles=%0d simultaneous_outputs=%0d stalled_reserved_cycles=%0d busy_and_not_ready=%0d",
                 n_contend, n_sim_outputs, n_stall_hold, n_backpressure_cycles);
        if (n_contend == 0 || n_sim_outputs == 0 || n_stall_hold == 0 || n_backpressure_cycles == 0 || a_err_cycles == 0) begin
            errors = errors + 1; $display("ERROR: coverage corner never hit");
        end
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #600000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
