// =============================================================================
// tb_traffic_generator.v : self-checking testbench for traffic_generator
// Six environments (nodes 0,1,6,9,14,15: diagonal and off-diagonal, corners and
// centre). Per environment (see module gen_env):
//   G1 reset state
//   G2 pattern checks, link always ready: every emitted flit is parsed and compared
//      with what the creation pulses announced (dst, src, pid, creation time,
//      injection time, integrity word); uniform never self and flat; hotspot
//      fraction; transpose/complement/neighbour exact; diagonal nodes silent for
//      transpose; sequence numbers consecutive
//   G3 backpressure: valid/data/type stable while valid && !ready; queue never
//      above 4; created == injected + queued + in-progress at all times; drops
//      counted when the queue is full
//   G4 block protocol with random block pulses: ack == block & idle, src_empty ==
//      idle, no packet starts while block is high, a started packet finishes,
//      nothing starts for 150 cycles of block, resumes after release
//   G5 max_packets (exactly N created), G6 gen_enable = 0 (no creation, queue
//      drains), G7 reproducibility (twin instance with identical inputs gives
//      identical outputs every cycle; different SEED gives a different stream),
//      G8 reset in the middle of a packet
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module gen_env #(
    parameter [3:0] NODE = 4'd0,
    parameter [31:0] SEED = 32'h1234
) (
    input  wire clk,
    output reg  done,
    output reg  [31:0] err_count
);
    reg         rst_n;
    reg  [31:0] now;
    reg         gen_enable;
    reg  [15:0] rate;
    reg  [2:0]  pattern;
    reg  [3:0]  hot_node;
    reg  [7:0]  hot_pct;
    reg  [31:0] max_packets;
    reg         inj_ready, block_req;
    wire [15:0] inj_data; wire [1:0] inj_type; wire inj_valid;
    wire        ack, src_empty, create_pulse, flit_accept;
    wire [3:0]  create_dst; wire [7:0] create_seq;
    wire [31:0] created, dropped, injected;
    wire [2:0]  q_count;

    traffic_generator #(.NODE(NODE), .SEED(SEED)) dut (
        .clk(clk), .rst_n(rst_n), .now(now),
        .gen_enable(gen_enable), .rate(rate), .pattern(pattern), .hot_node(hot_node), .hot_pct(hot_pct), .max_packets(max_packets),
        .inj_data(inj_data), .inj_type(inj_type), .inj_valid(inj_valid), .inj_ready(inj_ready),
        .inject_block_req(block_req), .inject_block_ack(ack), .src_empty(src_empty),
        .create_pulse(create_pulse), .create_dst(create_dst), .create_seq(create_seq), .flit_accept(flit_accept),
        .created(created), .dropped(dropped), .injected(injected), .q_count(q_count)
    );

    // twin with identical configuration (reproducibility) and one with another seed
    wire [15:0] t_data; wire [1:0] t_type; wire t_valid, t_ack, t_se, t_cp, t_fa;
    wire [3:0] t_cd; wire [7:0] t_cs; wire [31:0] t_cr, t_dr, t_in; wire [2:0] t_qc;
    traffic_generator #(.NODE(NODE), .SEED(SEED)) twin (
        .clk(clk), .rst_n(rst_n), .now(now),
        .gen_enable(gen_enable), .rate(rate), .pattern(pattern), .hot_node(hot_node), .hot_pct(hot_pct), .max_packets(max_packets),
        .inj_data(t_data), .inj_type(t_type), .inj_valid(t_valid), .inj_ready(inj_ready),
        .inject_block_req(block_req), .inject_block_ack(t_ack), .src_empty(t_se),
        .create_pulse(t_cp), .create_dst(t_cd), .create_seq(t_cs), .flit_accept(t_fa),
        .created(t_cr), .dropped(t_dr), .injected(t_in), .q_count(t_qc));
    wire [31:0] o_cr, o_dr, o_in; wire o_cp, o_valid, o_ack, o_se, o_fa; wire [3:0] o_cd; wire [7:0] o_cs; wire [15:0] o_data; wire [1:0] o_type; wire [2:0] o_qc;
    traffic_generator #(.NODE(NODE), .SEED(SEED ^ 32'h5A5A5A5A)) other (
        .clk(clk), .rst_n(rst_n), .now(now),
        .gen_enable(gen_enable), .rate(rate), .pattern(pattern), .hot_node(hot_node), .hot_pct(hot_pct), .max_packets(max_packets),
        .inj_data(o_data), .inj_type(o_type), .inj_valid(o_valid), .inj_ready(inj_ready),
        .inject_block_req(block_req), .inject_block_ack(o_ack), .src_empty(o_se),
        .create_pulse(o_cp), .create_dst(o_cd), .create_seq(o_cs), .flit_accept(o_fa),
        .created(o_cr), .dropped(o_dr), .injected(o_in), .q_count(o_qc));

    integer errors, seed, r;
    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors <= 5) $display("ERROR[node %0d] @%0t: %0s", NODE, $time, msg); end
    endtask

    always @(posedge clk) if (rst_n) now <= now + 1; else now <= 32'd0;

    // ---------------- creation record queue (expected packets) ----------------
    reg [3:0]  e_dst [0:255];
    reg [7:0]  e_seq [0:255];
    reg [15:0] e_ts  [0:255];
    integer    e_wr, e_rd;
    integer    seq_expect;
    integer    hist [0:15];
    integer    n_created_seen;
    integer    pat_check;            // 1: check destination against pattern
    reg [3:0]  exp_dst_fixed;
    integer    cov_drop, cov_stall_stable, cov_block_start_ok;

    always @(posedge clk) if (rst_n) begin
        if (create_pulse) begin
            e_dst[e_wr % 256] = create_dst; e_seq[e_wr % 256] = create_seq; e_ts[e_wr % 256] = now[15:0];
            e_wr = e_wr + 1;
            if (create_seq !== seq_expect[7:0]) fail("sequence number not consecutive");
            seq_expect = seq_expect + 1;
            hist[create_dst] = hist[create_dst] + 1;
            n_created_seen = n_created_seen + 1;
                if (create_dst === NODE) fail("packet addressed to its own node");
            case (pattern)
                3'd2: if (create_dst !== {NODE[1:0], NODE[3:2]}) fail("transpose destination");
                3'd3: if (create_dst !== ~NODE) fail("complement destination");
                3'd4: if (create_dst !== {NODE[3:2], NODE[1:0] + 2'd1}) fail("neighbour destination");
                default: ;
            endcase
        end
    end

    // ---------------- link parser ----------------
    integer pf;                       // flit index being parsed
    reg [15:0] p_hdr, p_b0, p_b1;
    integer    p_start_cycle;
    reg        prev_valid;
    reg [15:0] prev_data; reg [1:0] prev_type; reg prev_ready;
    integer    n_pkts_out;
    reg        parse_en;
    always @(posedge clk) if (rst_n) begin
        // stability: valid && !ready last cycle -> same flit this cycle
        if (prev_valid && !prev_ready) begin
            if (!inj_valid || inj_data !== prev_data || inj_type !== prev_type) fail("link changed while stalled");
            else cov_stall_stable = cov_stall_stable + 1;
        end
        if (inj_valid && !prev_valid) p_start_cycle = now[15:0];
        if (inj_valid && inj_ready && parse_en) begin
            case (pf)
                0: begin
                    if (inj_type !== `HY_FT_HEADER) fail("first flit not header");
                    p_hdr = inj_data;
                    if (e_rd >= e_wr) fail("packet injected that was never created");
                    else begin
                        if (inj_data[15:14] !== e_dst[e_rd % 256][1:0] || inj_data[13:12] !== e_dst[e_rd % 256][3:2]) fail("header dst");
                        if (inj_data[11:10] !== NODE[1:0] || inj_data[9:8] !== NODE[3:2]) fail("header src");
                        if (inj_data[7:0] !== e_seq[e_rd % 256]) fail("header pid / order");
                    end
                end
                1: begin
                    if (inj_type !== `HY_FT_BODY) fail("flit 1 not body");
                    p_b0 = inj_data;
                    if (e_rd < e_wr && inj_data !== e_ts[e_rd % 256]) fail("creation timestamp");
                end
                2: begin
                    if (inj_type !== `HY_FT_BODY) fail("flit 2 not body");
                    p_b1 = inj_data;
                    if (inj_data !== p_start_cycle[15:0] - 16'd0 && inj_data !== p_start_cycle[15:0]) fail("injection timestamp");
                end
                default: begin
                    if (inj_type !== `HY_FT_TAIL) fail("flit 3 not tail");
                    if (inj_data !== (p_hdr ^ p_b0 ^ p_b1 ^ 16'hC3A5)) fail("integrity word");
                    e_rd = e_rd + 1; n_pkts_out = n_pkts_out + 1;
                end
            endcase
            pf = (pf == 3) ? 0 : pf + 1;
        end
        prev_valid = inj_valid; prev_data = inj_data; prev_type = inj_type; prev_ready = inj_ready;
    end

    // ---------------- continuous protocol checks ----------------
    reg prev_block, prev_busy_chk;
    integer block_run, nostart_run;
    always @(posedge clk) if (rst_n) begin
        if (ack !== (block_req && !inj_valid)) fail("ack != block & idle");
        if (src_empty !== !inj_valid) fail("src_empty != idle");
        if (created !== injected + q_count + (inj_valid ? 1 : 0)) fail("created != injected + queued + in progress");
        if (q_count > 4) fail("queue above depth");
        if (block_req && inj_valid && !prev_valid && !prev_block) begin end
        // a packet must not START while block is requested
        if (inj_valid && !prev_valid && prev_block) fail("packet started while block requested");
        // twin identical
        if (t_data !== inj_data || t_type !== inj_type || t_valid !== inj_valid || t_ack !== ack || t_se !== src_empty ||
            t_cp !== create_pulse || t_cd !== create_dst || t_cs !== create_seq || t_cr !== created || t_dr !== dropped ||
            t_in !== injected || t_qc !== q_count) fail("twin instance differs (not reproducible)");
        if (dropped != 0) cov_drop = cov_drop + 1;
        prev_block = block_req;
    end

    // ---------------- stimulus helpers ----------------
    task tick; input integer n; integer q; begin for (q = 0; q < n; q = q + 1) @(negedge clk); end endtask
    task wait_idle;   // until the queue is empty and nothing is in progress
        integer g; begin g = 0; while ((q_count != 0 || inj_valid) && g < 20000) begin @(negedge clk); g = g + 1; end if (g >= 20000) fail("did not drain"); end
    endtask
    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0; tick(2); rst_n = 1'b1;
            e_wr = 0; e_rd = 0; seq_expect = 0; pf = 0; prev_valid = 0; prev_ready = 1; n_pkts_out = 0; n_created_seen = 0;
            for (r = 0; r < 16; r = r + 1) hist[r] = 0;
            @(negedge clk);
        end
    endtask
    task clear_hist; integer q; begin for (q = 0; q < 16; q = q + 1) hist[q] = 0; n_created_seen = 0; end endtask
    task run_pattern;
        input [2:0] pat; input integer ncreate;
        integer g;
        begin
            pattern = pat; clear_hist;
            gen_enable = 1'b1; inj_ready = 1'b1; block_req = 1'b0;
            g = 0;
            while (n_created_seen < ncreate && g < 200000) begin @(negedge clk); g = g + 1; end
            gen_enable = 1'b0;
            wait_idle; tick(3);
        end
    endtask

    integer j, mn, mx_, hv;
    real frac, exp_frac;

    initial begin
        done = 0; err_count = 0; errors = 0; seed = SEED; now = 0;
        rst_n = 1'b0; gen_enable = 0; rate = 16'h4000; pattern = 0; hot_node = 4'd9; hot_pct = 8'd128; max_packets = 0;
        inj_ready = 1; block_req = 0; parse_en = 1; pf = 0; prev_valid = 0; prev_ready = 1; prev_block = 0;
        e_wr = 0; e_rd = 0; seq_expect = 0; n_pkts_out = 0; n_created_seen = 0; p_start_cycle = 0;
        cov_drop = 0; cov_stall_stable = 0; cov_block_start_ok = 0;
        for (r = 0; r < 16; r = r + 1) hist[r] = 0;
        tick(3); rst_n = 1'b1; tick(2);

        // G1
        if (inj_valid !== 1'b0 || src_empty !== 1'b1 || created !== 0 || q_count !== 0) fail("G1 reset state");

        // G2 patterns
        run_pattern(3'd0, 3000);
        mn = 1000000; mx_ = 0;
        for (j = 0; j < 16; j = j + 1) if (j != NODE) begin if (hist[j] < mn) mn = hist[j]; if (hist[j] > mx_) mx_ = hist[j]; end
        if (hist[NODE] != 0) fail("G2 uniform sent to self");
        if (mn < 140 || mx_ > 270) fail("G2 uniform not flat");
        hot_node = 4'd9; hot_pct = 8'd128;
        run_pattern(3'd1, 3000);
        if (NODE != 9) begin
            hv = hist[9]; frac = hv; frac = frac / 3000.0; exp_frac = 0.5 + 0.5 / 15.0;
            if (frac < exp_frac - 0.05 || frac > exp_frac + 0.05) fail("G2 hotspot fraction");
        end else begin
            if (hist[9] != 0) fail("G2 hot node sent to itself");
        end
        pattern = 3'd2; clear_hist; gen_enable = 1; tick(600); gen_enable = 0; wait_idle;
        if ({NODE[1:0], NODE[3:2]} == NODE) begin if (n_created_seen != 0) fail("G2 diagonal node must be silent for transpose"); end
        else if (n_created_seen == 0) fail("G2 transpose produced nothing");
        run_pattern(3'd3, 400);
        run_pattern(3'd4, 400);
        run_pattern(3'd6, 300);          // unused code behaves like uniform
        if (n_pkts_out != e_rd) fail("G2 packet count");
        if (e_rd != e_wr) fail("G2 created packets not all injected");

        // G3 backpressure with a queue that overflows
        rate = 16'hF000; pattern = 3'd0; gen_enable = 1; block_req = 0;
        for (j = 0; j < 6000; j = j + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            inj_ready = ((r % 100) < 12);
            @(negedge clk);
        end
        gen_enable = 0; inj_ready = 1; wait_idle; tick(3);
        if (dropped == 0) fail("G3 expected drops with a full queue");
        rate = 16'h4000;

        // G4 block protocol
        gen_enable = 1;
        for (j = 0; j < 20000; j = j + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            inj_ready = ((r % 100) < 70);
            if (r % 97 == 0) block_req = ~block_req;
            @(negedge clk);
        end
        inj_ready = 1'b1; block_req = 1'b1; tick(5);
        // wait for the packet in progress to finish
        j = 0; while (inj_valid && j < 100) begin @(negedge clk); j = j + 1; end
        if (inj_valid) fail("G4 started packet did not finish under block");
        if (ack !== 1'b1 || src_empty !== 1'b1) fail("G4 ack/src_empty after block");
        j = injected; tick(150);
        if (injected !== j || inj_valid) fail("G4 injected while blocked");
        if (q_count == 0) fail("G4 queue should hold packets while blocked");
        block_req = 1'b0; tick(40);
        if (injected == j) fail("G4 did not resume after release");
        gen_enable = 0; inj_ready = 1; wait_idle; tick(3);

        // G5 max_packets
        do_reset; rate = 16'hC000; max_packets = 37; gen_enable = 1; inj_ready = 1; block_req = 0; tick(2000);
        if (created !== 37) fail("G5 created != max_packets");
        wait_idle; if (injected !== 37) fail("G5 injected != 37");
        max_packets = 0;

        // G6 gen_enable low
        gen_enable = 0; j = created; tick(500);
        if (created !== j) fail("G6 created while disabled");

        // G7 different seed gives a different stream
        gen_enable = 1; rate = 16'h8000; pattern = 3'd0;
        j = 0; for (r = 0; r < 400; r = r + 1) begin @(negedge clk); if (o_cp !== create_pulse || (create_pulse && o_cd !== create_dst)) j = j + 1; end
        if (j == 0) fail("G7 different seeds produced identical streams");
        gen_enable = 0; wait_idle;

        // G8 reset in the middle of a packet
        do_reset; rate = 16'hFFF0; gen_enable = 1; inj_ready = 0; tick(30);
        if (!inj_valid) fail("G8 expected a packet in progress");
        parse_en = 0; gen_enable = 0;
        do_reset; parse_en = 1;
        if (inj_valid || created !== 0 || dropped !== 0 || injected !== 0 || q_count !== 0) fail("G8 reset state");
        gen_enable = 0; inj_ready = 1; tick(5);

        tick(10);
        err_count = errors;
        $display("INFO: node %0d done: created=%0d injected=%0d dropped=%0d stable-stall-checks=%0d errors=%0d", NODE, created, injected, dropped, cov_stall_stable, errors);
        if (cov_stall_stable == 0) begin err_count = errors + 1; $display("ERROR: stall stability never exercised"); end
        done = 1;
    end
endmodule

module tb_traffic_generator;
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    wire [5:0] dn;
    wire [31:0] e0, e1, e2, e3, e4, e5;
    gen_env #(.NODE(4'd0),  .SEED(32'h11)) g0 (.clk(clk), .done(dn[0]), .err_count(e0));
    gen_env #(.NODE(4'd1),  .SEED(32'h22)) g1 (.clk(clk), .done(dn[1]), .err_count(e1));
    gen_env #(.NODE(4'd6),  .SEED(32'h33)) g2 (.clk(clk), .done(dn[2]), .err_count(e2));
    gen_env #(.NODE(4'd9),  .SEED(32'h44)) g3 (.clk(clk), .done(dn[3]), .err_count(e3));
    gen_env #(.NODE(4'd14), .SEED(32'h55)) g4 (.clk(clk), .done(dn[4]), .err_count(e4));
    gen_env #(.NODE(4'd15), .SEED(32'h66)) g5 (.clk(clk), .done(dn[5]), .err_count(e5));
    initial begin
        wait (&dn); #5;
        if ((e0 + e1 + e2 + e3 + e4 + e5) == 0) $display("TB_RESULT: PASS");
        else $display("TB_RESULT: FAIL (%0d errors)", e0 + e1 + e2 + e3 + e4 + e5);
        $finish;
    end
    initial begin #400000000; $display("TB_RESULT: FAIL (timeout)"); $finish; end
endmodule
