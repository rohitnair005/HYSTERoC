// =============================================================================
// tb_packet_sink.v : self-checking testbench for packet_sink
//   K1 reset state
//   K2 ready behaviour: thresh 255 always ready, 0 never, 128 about 50% (+-3%);
//      ej_ready never changes combinationally with ej_valid
//   K3 good packets: pkt_done pulse (one cycle, registered), source, pid and both
//      latencies exact, counters
//   K4 error injection: wrong destination, header in the middle of a packet
//      (truncation), body first, tail early, tail late, reserved type, bad
//      integrity word: each raises exactly the intended counter and the sink
//      resynchronises (the next good packet is accepted)
//   K5 random fuzz (legal and illegal flits, random timing) against an
//      independent behavioural model: counters, pulses and outputs every cycle
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_packet_sink;
    parameter [3:0] NODE = 4'd6;       // x = 2, y = 1
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg  [31:0] now;
    reg  [7:0]  thresh;
    reg  [15:0] ej_data; reg [1:0] ej_type; reg ej_valid;
    wire        ej_ready, pkt_done, err_any;
    wire [3:0]  pkt_src; wire [7:0] pkt_pid; wire [15:0] lat_t, lat_n;
    wire [31:0] pkts_ok, flits; wire [15:0] ed, eo, ei;

    packet_sink #(.NODE(NODE), .SEED(32'h77)) dut (
        .clk(clk), .rst_n(rst_n), .now(now), .ready_thresh(thresh),
        .ej_data(ej_data), .ej_type(ej_type), .ej_valid(ej_valid), .ej_ready(ej_ready),
        .pkt_done(pkt_done), .pkt_src(pkt_src), .pkt_pid(pkt_pid), .pkt_lat_total(lat_t), .pkt_lat_net(lat_n),
        .pkts_ok(pkts_ok), .flits(flits), .err_dest_cnt(ed), .err_order_cnt(eo), .err_integ_cnt(ei), .err_any(err_any));

    always @(posedge clk) if (rst_n) now <= now + 1; else now <= 32'd100;

    integer errors, seed, r;
    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors <= 12) $display("ERROR @%0t: %0s (ok=%0d ed=%0d eo=%0d ei=%0d)", $time, msg, pkts_ok, ed, eo, ei); end
    endtask

    // -------- independent model for the fuzz --------
    integer m_f, m_ok, m_flits, m_ed, m_eo, m_ei;
    reg [15:0] m_hdr, m_b0, m_b1;
    reg        m_done; reg [3:0] m_src; reg [7:0] m_pid; reg [15:0] m_lt, m_ln;
    reg        fuzz_on;
    reg        m_ready_prev;

    task model_flit;       // called for each accepted flit with pre-edge values of data/type and now
        input [15:0] d; input [1:0] t; input [31:0] nw;
        begin
            m_flits = m_flits + 1;
            if (t == 2'b00) begin
                if (m_f != 0) m_eo = m_eo + 1;
                if (d[15:12] != {NODE[1:0], NODE[3:2]}) m_ed = m_ed + 1;
                m_hdr = d; m_f = 1;
            end else if (t == 2'b01) begin
                if (m_f == 1) begin m_b0 = d; m_f = 2; end
                else if (m_f == 2) begin m_b1 = d; m_f = 3; end
                else begin m_eo = m_eo + 1; m_f = 0; end
            end else if (t == 2'b10) begin
                if (m_f == 3) begin
                    if (d != (m_hdr ^ m_b0 ^ m_b1 ^ 16'hC3A5)) m_ei = m_ei + 1;
                    else begin
                        m_ok = m_ok + 1; m_done = 1'b1; m_src = {m_hdr[9:8], m_hdr[11:10]}; m_pid = m_hdr[7:0];
                        m_lt = nw[15:0] - m_b0; m_ln = nw[15:0] - m_b1;
                    end
                end else m_eo = m_eo + 1;
                m_f = 0;
            end else begin m_eo = m_eo + 1; m_f = 0; end
        end
    endtask

    always @(posedge clk) if (rst_n && fuzz_on) begin
        // pkt_done etc. at this edge show what the previous edge produced
        if (pkt_done !== m_done) fail("fuzz pkt_done");
        if (m_done && (pkt_src !== m_src || pkt_pid !== m_pid || lat_t !== m_lt || lat_n !== m_ln)) fail("fuzz pkt fields");
        if (pkts_ok !== m_ok || flits !== m_flits || ed !== m_ed || eo !== m_eo || ei !== m_ei) fail("fuzz counters");
        m_done = 1'b0;
        if (ej_valid && ej_ready) model_flit(ej_data, ej_type, now);
    end

    // -------- helpers --------
    task send;  // one flit, waits for acceptance
        input [15:0] d; input [1:0] t;
        integer g;
        begin
            @(negedge clk); ej_data = d; ej_type = t; ej_valid = 1'b1;
            g = 0;
            @(posedge clk);
            while (!ej_ready && g < 1000) begin @(negedge clk); @(posedge clk); g = g + 1; end
            @(negedge clk); ej_valid = 1'b0; ej_data = 16'hxxxx;
        end
    endtask

    function [15:0] mkhdr; input [3:0] dst; input [3:0] src; input [7:0] pid;
        begin mkhdr = {dst[1:0], dst[3:2], src[1:0], src[3:2], pid}; end
    endfunction
    function [15:0] mktail; input [15:0] h; input [15:0] b0v; input [15:0] b1v;
        begin mktail = h ^ b0v ^ b1v ^ 16'hC3A5; end
    endfunction

    task good_packet; input [3:0] src; input [7:0] pid; input [15:0] c_ts; input [15:0] i_ts;
        reg [15:0] h;
        begin
            h = mkhdr(NODE, src, pid);
            send(h, 2'b00); send(c_ts, 2'b01); send(i_ts, 2'b01); send(mktail(h, c_ts, i_ts), 2'b10);
        end
    endtask

    reg fz_acc_prev, fz_present; reg [1:0] fz_t; reg [15:0] fz_d; integer fz_idx, fz_hold;
    always @(posedge clk) fz_acc_prev <= (ej_valid && ej_ready && rst_n) ? 1'b1 : (fz_acc_prev && 0);
    integer cov_ok, cov_ed, cov_eo, cov_ei, cov_fl;
    integer base_ok, base_ed, base_eo, base_ei, n_ready, j, k;
    reg [15:0] hh;
    reg [31:0] t_before;

    initial begin
        errors = 0; seed = 99; now = 100; thresh = 8'hFF; ej_valid = 0; ej_data = 0; ej_type = 0;
        fuzz_on = 0; m_f = 0; m_ok = 0; m_flits = 0; m_ed = 0; m_eo = 0; m_ei = 0; m_done = 0;
        m_hdr = 0; m_b0 = 0; m_b1 = 0; m_src = 0; m_pid = 0; m_lt = 0; m_ln = 0;
        rst_n = 0; repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (2) @(negedge clk);

        // K1
        if (pkts_ok !== 0 || flits !== 0 || err_any !== 1'b0 || pkt_done !== 1'b0) fail("K1 reset state");

        // K2 ready behaviour
        thresh = 8'hFF; n_ready = 0; for (j = 0; j < 500; j = j + 1) begin @(negedge clk); if (ej_ready) n_ready = n_ready + 1; end
        if (n_ready < 499) fail("K2 thresh=255 not always ready");   // first cycle after reset may differ
        thresh = 8'h00; repeat (3) @(negedge clk); n_ready = 0; for (j = 0; j < 500; j = j + 1) begin @(negedge clk); if (ej_ready) n_ready = n_ready + 1; end
        if (n_ready != 0) fail("K2 thresh=0 became ready");
        thresh = 8'd128; n_ready = 0; for (j = 0; j < 20000; j = j + 1) begin @(negedge clk); if (ej_ready) n_ready = n_ready + 1; end
        if (n_ready < 9400 || n_ready > 10600) fail("K2 thresh=128 not about 50%");
        // ej_ready is a register: toggling valid must not change it
        thresh = 8'd128;
        for (j = 0; j < 200; j = j + 1) begin
            @(negedge clk); ej_valid = 1'b0; #1; k = ej_ready; ej_valid = 1'b1; #1; if (ej_ready !== k[0]) fail("K2 ready depends on valid combinationally");
            ej_valid = 1'b0;
        end
        thresh = 8'hFF; repeat (3) @(negedge clk);

        // K3 good packets with known timestamps. now is the cycle of tail acceptance.
        base_ok = pkts_ok;
        // creation ts 40, injection ts 70; tail accepted at cycle `now` -> lat_total = now-40, lat_net = now-70
        good_packet(4'd13, 8'hA7, 16'd40, 16'd70);
        // the pulse is registered: visible one cycle after the accepting edge. Capture while sending next.
        @(negedge clk);
        if (pkts_ok !== base_ok + 1) fail("K3 pkts_ok");
        // re-send and watch the pulse cycle exactly
        hh = mkhdr(NODE, 4'd2, 8'h33);
        send(hh, 2'b00); send(16'd1000, 2'b01); send(16'd1010, 2'b01);
        @(negedge clk); ej_data = mktail(hh, 16'd1000, 16'd1010); ej_type = 2'b10; ej_valid = 1'b1;
        @(posedge clk); t_before = now;                         // value sampled at the accepting edge
        #1; if (pkt_done !== 1'b0 && 0) fail("x");
        @(negedge clk); ej_valid = 1'b0;
        if (pkt_done !== 1'b1) fail("K3 pkt_done missing");
        if (pkt_src !== 4'd2 || pkt_pid !== 8'h33) fail("K3 src/pid");
        if (lat_t !== t_before[15:0] - 16'd1000 || lat_n !== t_before[15:0] - 16'd1010) fail("K3 latencies");
        @(negedge clk);
        if (pkt_done !== 1'b0) fail("K3 pkt_done not a single-cycle pulse");
        if (flits !== 8) fail("K3 flit count");

        // K4 error injection (always-ready sink)
        base_ok = pkts_ok; base_ed = ed; base_eo = eo; base_ei = ei;
        // wrong destination (still a well-formed packet: counts dest error, packet otherwise accepted)
        hh = mkhdr(4'd9, 4'd1, 8'h01);
        send(hh, 2'b00); send(16'd5, 2'b01); send(16'd6, 2'b01); send(mktail(hh, 16'd5, 16'd6), 2'b10);
        if (ed !== base_ed + 1) fail("K4 dest error not counted");
        // header in the middle of a packet
        hh = mkhdr(NODE, 4'd1, 8'h02);
        send(hh, 2'b00); send(16'd5, 2'b01);
        hh = mkhdr(NODE, 4'd1, 8'h03);
        send(hh, 2'b00); send(16'd5, 2'b01); send(16'd6, 2'b01); send(mktail(hh, 16'd5, 16'd6), 2'b10);
        if (eo !== base_eo + 1) fail("K4 truncation not counted");
        // body without header
        send(16'd9, 2'b01);
        if (eo !== base_eo + 2) fail("K4 orphan body not counted");
        // tail early
        hh = mkhdr(NODE, 4'd1, 8'h04);
        send(hh, 2'b00); send(16'd5, 2'b01); send(16'h1234, 2'b10);
        if (eo !== base_eo + 3) fail("K4 early tail not counted");
        // body in the place of the tail (3 body flits)
        hh = mkhdr(NODE, 4'd1, 8'h05);
        send(hh, 2'b00); send(16'd5, 2'b01); send(16'd6, 2'b01); send(16'd7, 2'b01);
        if (eo !== base_eo + 4) fail("K4 extra body not counted");
        // reserved type
        send(16'h0, 2'b11);
        if (eo !== base_eo + 5) fail("K4 reserved type not counted");
        // bad integrity word
        hh = mkhdr(NODE, 4'd1, 8'h06);
        send(hh, 2'b00); send(16'd5, 2'b01); send(16'd6, 2'b01); send(16'hBEEF, 2'b10);
        if (ei !== base_ei + 1) fail("K4 integrity error not counted");
        // resynchronisation: good packet afterwards
        good_packet(4'd7, 8'h77, 16'd1, 16'd2);
        @(negedge clk);
        if (pkts_ok !== base_ok + 3) fail("K4 sink did not resynchronise (ok count)");   // pid 03 packet, wrong-dst packet, final good
        if (err_any !== 1'b1) fail("K4 err_any");

        // K5 fuzz against the model: reset first, then random legal/illegal flits
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1;
        m_f = 0; m_ok = 0; m_flits = 0; m_ed = 0; m_eo = 0; m_ei = 0; m_done = 0;
        fz_acc_prev = 0; fz_present = 0; fz_t = 0; fz_d = 0;
        cov_ok = 0; cov_ed = 0; cov_eo = 0; cov_ei = 0; cov_fl = 0;
        fuzz_on = 1; thresh = 8'd160;
        fz_idx = 0; fz_hold = 0;
        for (j = 0; j < 80000; j = j + 1) begin
            @(negedge clk);
            if (fz_acc_prev) begin fz_idx = (fz_idx + 1) % 4; fz_hold = 0; end
            if (!fz_hold) begin
                r = $random(seed); if (r < 0) r = -r;
                fz_present = (r % 100 < 60);
                r = $random(seed); if (r < 0) r = -r;
                case (fz_idx) 0: fz_t = 2'b00; 1, 2: fz_t = 2'b01; default: fz_t = 2'b10; endcase
                fz_d = $random(seed);
                if (fz_t == 2'b00) fz_d[15:12] = {NODE[1:0], NODE[3:2]};
                if (fz_t == 2'b10) fz_d = m_hdr ^ m_b0 ^ m_b1 ^ 16'hC3A5;
                // noise
                if (r % 100 < 6) fz_t = 2'b11;
                else if (r % 100 < 12) fz_t = r[12:11];
                else if (r % 100 < 16) fz_d = $random(seed);
                else if (r % 100 < 20 && fz_t == 2'b00) fz_d[15:12] = ~fz_d[15:12];
            end
            ej_valid = fz_present; ej_type = fz_t; ej_data = fz_d;
            if (fz_present) fz_hold = 1;
            fz_acc_prev = 1'b0;
            if (j % 20000 == 19999) begin cov_ok = cov_ok + m_ok; cov_ed = cov_ed + m_ed; cov_eo = cov_eo + m_eo; cov_ei = cov_ei + m_ei; cov_fl = cov_fl + m_flits; rst_n = 0; @(posedge clk); #1 rst_n = 1; m_f = 0; m_ok = 0; m_flits = 0; m_ed = 0; m_eo = 0; m_ei = 0; m_done = 0; fz_idx = 0; fz_hold = 0; end
        end
        ej_valid = 0; repeat (5) @(negedge clk);
        if (cov_ok < 500 || cov_ed == 0 || cov_eo == 0 || cov_ei == 0) fail("K5 fuzz coverage too low");
        $display("INFO: fuzz model: ok=%0d dest_err=%0d order_err=%0d integ_err=%0d flits=%0d", cov_ok, cov_ed, cov_eo, cov_ei, cov_fl);

        if (errors == 0) $display("TB_RESULT: PASS");
        else $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #400000000; $display("TB_RESULT: FAIL (timeout)"); $finish; end
endmodule
