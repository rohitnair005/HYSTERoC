// =============================================================================
// tb_noc_router.v : self-checking testbench for noc_router (Verilog-2001)
//
// 16 independent environments (module rt_env), one per mesh position, each with
// its own random stimulus. Every environment drives five input links with legal
// 4-flit packets (random destination 0..3 x 0..3, random source fields), random
// output ready, random neighbour occupancy sideband, and toggles the global mode
// at random times (also while packets are in flight).
//
// Checks (all every cycle unless noted):
//   * every flit accepted into an input FIFO leaves exactly once, in per-input
//     order, with identical type and data (log compare: no loss/dup/reorder)
//   * output packets never interleave; H,B,B,T leave on ONE output; length 4
//   * header output = XY port in XY mode (independent function); in adaptive
//     mode = the lowest-occupancy available Odd-Even candidate computed from the
//     testbench's own copy of the one-cycle-old sideband, ties E,S,W,N
//   * out_valid only with out_ready; boundary outputs never used; no flit
//     leaves in the cycle it arrives (FIFO latency >= 1)
//   * in_ready == (occupancy != 4); occupancy matches pushes - pops
//   * router_empty == (all FIFOs empty && no open packet), exactly, each cycle
//   * ewma_out matches an independent S = S - (S>>3) + C model, freezes when
//     ewma_enable = 0; cong_now / max_occ_now match the mapped sideband
//   * proto_err = 0 and alloc_err = 0 in legal traffic
//   * at the end: all flits delivered, router_empty = 1
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module rt_env #(
    parameter X = 0,
    parameter Y = 0,
    parameter SEED = 1,
    parameter CYCLES = 20000
) (
    input  wire clk,
    input  wire rst_n,
    output reg  done,
    output reg  [31:0] err_count,
    output reg  [31:0] pk_count_o,
    output reg  [31:0] cov_o
);

    // ---------------- DUT ----------------
    reg         active_mode, ewma_enable;
    reg  [79:0] in_data;  reg [9:0] in_type;  reg [4:0] in_valid;
    wire [4:0]  in_ready;
    wire [79:0] out_data; wire [9:0] out_type; wire [4:0] out_valid;
    reg  [4:0]  out_ready;
    reg  [11:0] nbr_occ_in;
    wire [3:0]  nbr_avail = { (X != 0), (X != 3), (Y != 3), (Y != 0) };   // W,E,S,N bit order: [0]=N [1]=S [2]=E [3]=W
    wire [14:0] fifo_occ;
    wire        router_empty, proto_err, alloc_err;
    wire [7:0]  ewma_out, cong_now;
    wire [2:0]  max_occ_now;

    noc_router dut (
        .clk(clk), .rst_n(rst_n), .x_coord(X[1:0]), .y_coord(Y[1:0]),
        .active_mode(active_mode), .ewma_enable(ewma_enable),
        .in_data(in_data), .in_type(in_type), .in_valid(in_valid), .in_ready(in_ready),
        .out_data(out_data), .out_type(out_type), .out_valid(out_valid), .out_ready(out_ready),
        .nbr_occ_in(nbr_occ_in), .nbr_avail(nbr_avail),
        .fifo_occ(fifo_occ), .router_empty(router_empty), .ewma_out(ewma_out),
        .cong_now(cong_now), .max_occ_now(max_occ_now),
        .proto_err(proto_err), .alloc_err(alloc_err)
    );

    // route oracle driven from the OBSERVED output header (verified exhaustively)
    reg  [15:0] ob_hdr;
    wire [4:0]  or_xy, or_oe;
    route_compute oracle (.x(X[1:0]), .y(Y[1:0]),
        .dst_x(ob_hdr[15:14]), .dst_y(ob_hdr[13:12]), .src_x(ob_hdr[11:10]),
        .xy_port(or_xy), .oe_cand(or_oe));

    // ---------------- bookkeeping ----------------
    integer seed;
    integer r, p, e, k;
    integer errors;
    // input streams
    reg        i_has [0:4];
    integer    i_f [0:4];
    integer    i_serial [0:4];
    reg [15:0] i_data [0:4];
    reg [1:0]  i_type [0:4];
    // logs of accepted flits per input (circular, 4096)
    reg [17:0] logq [0:5*4096-1];
    integer    n_push [0:4];
    integer    n_cons [0:4];
    // open packet tracking
    integer    o_src [0:4];
    integer    o_flits [0:4];
    integer    in_open [0:4];     // packets with header consumed but tail not
    integer    pk_out [0:4];      // output of in-flight packet per input
    integer    packets_done;
    // fifo model
    integer    m_occ [0:4];
    // sideband copy
    reg [11:0] occq_m;
    // ewma model
    integer    S_m;
    // coverage
    integer    cov_xy_hdr, cov_ad_hdr, cov_ad_choice, cov_tie, cov_stall_hold, cov_modeflip, cov_local;
    integer    p_valid, p_ready;
    integer    cycle;
    reg        gen_en;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 5) $display("ERROR %0d,%0d @%0t: %0s", X, Y, $time, msg);
        end
    endtask

    function integer map_occ;
        input integer o;
        begin
            case (o)
                0: map_occ = 0; 1: map_occ = 64; 2: map_occ = 128; 3: map_occ = 192; default: map_occ = 255;
            endcase
        end
    endfunction

    function integer pc5;
        input [4:0] v;
        begin pc5 = v[0] + v[1] + v[2] + v[3] + v[4]; end
    endfunction

    // expected port (as one-hot) for adaptive mode. cand/avail: bit order N S E W L
    function [4:0] exp_adapt;
        input [4:0] cand;
        input [11:0] oq;
        input [3:0] av;
        reg [4:0] c;
        integer best, bo, d;
        integer order [0:3];   // E,S,W,N as port ids 2,1,3,0
        integer idx;
        begin
            c = cand & {1'b1, av[3], av[2], av[1], av[0]};
            if (c[4]) exp_adapt = 5'b10000;
            else begin
                exp_adapt = 5'b0; best = -1; bo = 99;
                for (idx = 0; idx < 4; idx = idx + 1) begin
                    case (idx) 0: d = 2; 1: d = 1; 2: d = 3; default: d = 0; endcase
                    if (c[d]) begin
                        if (best < 0 || oq[3*d +: 3] < bo) begin
                            best = d; bo = oq[3*d +: 3];
                        end
                    end
                end
                if (best >= 0) exp_adapt = 5'b1 << best;
            end
        end
    endfunction

    // number of candidates tied for the minimum (coverage only)
    function integer tied;
        input [4:0] cand;
        input [11:0] oq;
        input [3:0] av;
        reg [4:0] c;
        integer m, d, cnt;
        begin
            c = cand & {1'b1, av};
            m = 99; cnt = 0;
            for (d = 0; d < 4; d = d + 1) if (c[d] && oq[3*d +: 3] < m) m = oq[3*d +: 3];
            for (d = 0; d < 4; d = d + 1) if (c[d] && oq[3*d +: 3] == m) cnt = cnt + 1;
            tied = cnt;
        end
    endfunction

    // ---------------- stimulus helpers ----------------
    task new_flit;
        input integer q;
        reg [7:0] pid;
        reg [15:0] d;
        begin
            if (i_f[q] == 0) begin
                r = $random(seed);
                pid = {q[2:0], i_serial[q][4:0]};
                d = {r[1:0], r[3:2], r[5:4], r[7:6], pid};   // dst_x dst_y src_x src_y pid
                i_data[q] = d; i_type[q] = `HY_FT_HEADER;
            end else begin
                r = $random(seed);
                i_data[q] = {q[2:0], r[12:0]};
                i_type[q] = (i_f[q] == 3) ? `HY_FT_TAIL : `HY_FT_BODY;
            end
        end
    endtask

    integer q, s_in, src_in, ex_i, ob_o;
    reg [4:0] exp_port;
    reg [4:0] ob_valid_s, ob_ready_s, in_acc;
    reg [17:0] ob_flit, exp_flit;
    reg        any_open;
    integer    S_next;
    reg [11:0] occq_pre;
    reg        mode_pre;
    reg        ewma_en_pre;
    integer    cn, mo, dd;

    initial begin
        done = 1'b0; err_count = 0; pk_count_o = 0; cov_o = 0;
        seed = SEED; errors = 0; packets_done = 0; cycle = 0; gen_en = 1'b1;
        cov_xy_hdr = 0; cov_ad_hdr = 0; cov_ad_choice = 0; cov_tie = 0; cov_stall_hold = 0; cov_modeflip = 0; cov_local = 0;
        p_valid = 80; p_ready = 70;
        active_mode = 0; ewma_enable = 1;
        in_data = 0; in_type = 0; in_valid = 0; out_ready = 0; nbr_occ_in = 0; occq_m = 0; S_m = 0; ob_hdr = 0;
        for (q = 0; q < 5; q = q + 1) begin
            i_has[q] = 0; i_f[q] = 0; i_serial[q] = 0; n_push[q] = 0; n_cons[q] = 0;
            o_src[q] = -1; o_flits[q] = 0; in_open[q] = 0; pk_out[q] = -1; m_occ[q] = 0;
        end
        wait (rst_n === 1'b1);
        @(negedge clk);
        while (cycle < CYCLES + 600) begin
            // ------- phase control -------
            if (cycle == CYCLES) begin gen_en = 1'b0; p_ready = 100; end
            if (cycle % 2500 == 0 && cycle < CYCLES) begin
                case ((cycle / 2500) % 5)
                    0: begin p_valid = 100; p_ready = 100; end
                    1: begin p_valid = 100; p_ready = 30;  end
                    2: begin p_valid = 40;  p_ready = 80;  end
                    3: begin p_valid = 90;  p_ready = 12;  end
                    default: begin p_valid = 70; p_ready = 60; end
                endcase
            end
            // ------- drive inputs (data stable while valid && !ready) -------
            for (q = 0; q < 5; q = q + 1) begin
                if (!i_has[q] && (gen_en || i_f[q] != 0)) begin
                    r = $random(seed); if (r < 0) r = -r;
                    if ((r % 100) < p_valid) begin new_flit(q); i_has[q] = 1'b1; end
                end
                in_valid[q] = i_has[q];
                in_data[16*q +: 16] = i_has[q] ? i_data[q] : $random(seed);
                in_type[2*q +: 2]   = i_has[q] ? i_type[q] : $random(seed);
                r = $random(seed); if (r < 0) r = -r;
                out_ready[q] = ((r % 100) < p_ready);
            end
            // neighbour occupancy: random walk 0..4 per direction, sometimes jumps
            for (q = 0; q < 4; q = q + 1) begin
                r = $random(seed); if (r < 0) r = -r;
                if (r % 4 == 0) begin
                    r = $random(seed); if (r < 0) r = -r;
                    nbr_occ_in[3*q +: 3] = r % 5;
                end
            end
            // mode toggles at random times (also with packets in flight)
            r = $random(seed); if (r < 0) r = -r;
            if (r % 600 == 0) begin active_mode = ~active_mode; cov_modeflip = cov_modeflip + 1; end
            r = $random(seed); if (r < 0) r = -r;
            ewma_enable = !(r % 40 < 6 && (r % 7 == 0));
            if (cycle < CYCLES && cycle % 3000 > 2800) ewma_enable = 1'b0;     // long freeze windows

            #1;   // settle combinational outputs
            // ================= checks on this cycle =================
            ob_valid_s = out_valid; ob_ready_s = out_ready;
            if (proto_err) fail("proto_err in legal traffic");
            if (alloc_err) fail("alloc_err in legal traffic");
            // in_ready and occupancy
            for (q = 0; q < 5; q = q + 1) begin
                if (in_ready[q] !== (m_occ[q] != 4)) fail("in_ready != (occ!=4)");
                if (fifo_occ[3*q +: 3] !== m_occ[q]) fail("fifo_occ mismatch");
            end
            // router_empty
            any_open = 1'b0;
            for (q = 0; q < 5; q = q + 1) if (in_open[q] != 0) any_open = 1'b1;
            if (router_empty !== ((m_occ[0] + m_occ[1] + m_occ[2] + m_occ[3] + m_occ[4] == 0) && !any_open))
                fail("router_empty wrong");
            // sideband-derived values
            cn = 0; mo = 0;
            for (dd = 0; dd < 4; dd = dd + 1)
                if (nbr_avail[dd]) begin
                    if (occq_m[3*dd +: 3] > mo) mo = occq_m[3*dd +: 3];
                end
            if (max_occ_now !== mo[2:0]) fail("max_occ_now");
            if (cong_now !== map_occ(mo)) fail("cong_now");
            if (ewma_out !== (S_m >> 3)) fail("ewma_out");
            // outputs
            for (e = 0; e < 5; e = e + 1) begin
                if (out_valid[e]) begin
                    if (!out_ready[e]) fail("out_valid without out_ready");
                    if (e < 4 && !nbr_avail[e]) fail("flit on boundary output");
                    ob_flit = {out_type[2*e +: 2], out_data[16*e +: 16]};
                    // identify source
                    if (out_type[2*e +: 2] == `HY_FT_HEADER) src_in = out_data[16*e+5 +: 3];
                    else                                     src_in = out_data[16*e+13 +: 3];
                    if (src_in > 4) begin fail("bad source tag"); end
                    else begin
                        if (n_cons[src_in] >= n_push[src_in]) fail("flit left that was never accepted");
                        else begin
                            exp_flit = logq[src_in*4096 + (n_cons[src_in] % 4096)];
                            if (ob_flit !== exp_flit) fail("flit content/order mismatch");
                            n_cons[src_in] = n_cons[src_in] + 1;
                            m_occ[src_in] = m_occ[src_in] - 1;
                        end
                        // packet structure
                        if (out_type[2*e +: 2] == `HY_FT_HEADER) begin
                            if (o_src[e] != -1) fail("header while output holds an open packet");
                            if (in_open[src_in] != 0) fail("second header before tail of same input");
                            o_src[e] = src_in; o_flits[e] = 1; pk_out[src_in] = e; in_open[src_in] = 1;
                            // route check
                            ob_hdr = out_data[16*e +: 16];
                            #0;
                            if (active_mode == `HY_MODE_XY) begin
                                exp_port = or_xy;
                                cov_xy_hdr = cov_xy_hdr + 1;
                            end else begin
                                exp_port = exp_adapt(or_oe, occq_m, nbr_avail);
                                cov_ad_hdr = cov_ad_hdr + 1;
                                if (pc5(or_oe & {1'b1, nbr_avail}) > 1) cov_ad_choice = cov_ad_choice + 1;
                                if (tied(or_oe, occq_m, nbr_avail) > 1 && pc5(or_oe & {1'b1, nbr_avail}) > 1) cov_tie = cov_tie + 1;
                            end
                            if (exp_port !== (5'b1 << e)) fail("header routed to wrong output");
                            if (e == 4) cov_local = cov_local + 1;
                        end else begin
                            if (o_src[e] != src_in) fail("interleaved or orphan flit on output");
                            if (pk_out[src_in] != e) fail("packet changed output");
                            o_flits[e] = o_flits[e] + 1;
                            if (out_type[2*e +: 2] == `HY_FT_TAIL) begin
                                if (o_flits[e] != 4) fail("packet length != 4");
                                o_src[e] = -1; in_open[src_in] = 0; pk_out[src_in] = -1;
                                packets_done = packets_done + 1;
                            end
                        end
                    end
                end else if (o_src[e] != -1 && !out_ready[e]) begin
                    cov_stall_hold = cov_stall_hold + 1;
                end
            end
            // ================= clock edge =================
            in_acc = in_valid & in_ready;
            occq_pre = occq_m; ewma_en_pre = ewma_enable;
            @(posedge clk);
            #1;
            // accepted pushes
            for (q = 0; q < 5; q = q + 1) begin
                if (in_acc[q]) begin
                    logq[q*4096 + (n_push[q] % 4096)] = {i_type[q], i_data[q]};
                    n_push[q] = n_push[q] + 1;
                    m_occ[q] = m_occ[q] + 1;
                    i_has[q] = 1'b0;
                    if (i_f[q] == 3) begin i_f[q] = 0; i_serial[q] = i_serial[q] + 1; end
                    else i_f[q] = i_f[q] + 1;
                end
            end
            // sideband copy and EWMA model (use pre-edge sample)
            if (ewma_en_pre) begin
                mo = 0;
                for (dd = 0; dd < 4; dd = dd + 1)
                    if (nbr_avail[dd] && occq_pre[3*dd +: 3] > mo) mo = occq_pre[3*dd +: 3];
                S_m = S_m - (S_m >> 3) + map_occ(mo);
            end
            occq_m = nbr_occ_in;
            cycle = cycle + 1;
            @(negedge clk);
        end
        // ---------------- end of run ----------------
        #1;
        for (q = 0; q < 5; q = q + 1) begin
            if (n_cons[q] != n_push[q]) fail("flits left undelivered at end");
            if (in_open[q] != 0) fail("packet left open at end");
        end
        if (router_empty !== 1'b1) fail("router not empty at end");
        err_count = errors; pk_count_o = packets_done;
        cov_o = {cov_xy_hdr[7:0], cov_ad_choice[7:0], cov_tie[7:0], cov_stall_hold[7:0]};
        $display("INFO: router(%0d,%0d) packets=%0d xy_hdr=%0d adaptive_hdr=%0d multi_cand=%0d ties=%0d stalled_reserved=%0d mode_flips=%0d local_hdr=%0d errors=%0d",
                 X, Y, packets_done, cov_xy_hdr, cov_ad_hdr, cov_ad_choice, cov_tie, cov_stall_hold, cov_modeflip, cov_local, errors);
        if (cov_xy_hdr == 0 || cov_ad_hdr == 0 || cov_stall_hold == 0 || cov_modeflip == 0) begin
            err_count = errors + 1;
            $display("ERROR %0d,%0d: coverage corner not hit", X, Y);
        end
        done = 1'b1;
    end
endmodule

module tb_noc_router;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire [15:0] d;
    wire [31:0] e [0:15];
    wire [31:0] pk [0:15];
    wire [31:0] cv [0:15];

    genvar gx, gy;
    generate
        for (gy = 0; gy < 4; gy = gy + 1) begin : g_y
            for (gx = 0; gx < 4; gx = gx + 1) begin : g_x
                rt_env #(.X(gx), .Y(gy), .SEED(32'h1000 + 16*gy + gx), .CYCLES(20000)) env (
                    .clk(clk), .rst_n(rst_n), .done(d[4*gy+gx]),
                    .err_count(e[4*gy+gx]), .pk_count_o(pk[4*gy+gx]), .cov_o(cv[4*gy+gx]));
            end
        end
    endgenerate

    integer i, total_err, total_pk;
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        wait (&d);
        #5;
        total_err = 0; total_pk = 0;
        for (i = 0; i < 16; i = i + 1) begin total_err = total_err + e[i]; total_pk = total_pk + pk[i]; end
        $display("INFO: 16 positions, total packets routed = %0d", total_pk);
        if (total_err == 0) $display("TB_RESULT: PASS");
        else                $display("TB_RESULT: FAIL (%0d errors)", total_err);
        $finish;
    end

    initial begin
        #900000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
