// =============================================================================
// tb_packet_tracker.v : self-checking testbench for packet_tracker (Verilog-2001)
//
// An independent behavioural model (lock flag + port) is compared with every DUT
// output at every cycle. Stimulus:
//   * directed cases (stalled header, continuation, long backpressure, tail
//     release, xfer without valid, route_port==0, reset while locked, fields)
//   * random LEGAL traffic emulating a FIFO head: 4-flit packets, head stable
//     until accepted, random gaps, random one-hot (or zero) route_port that
//     changes every cycle, random acceptance
//   * random ILLEGAL traffic (any type/xfer/route_port) checked against the model
// Packet-level checks on the legal run: every accepted packet is exactly four
// flits (H,B,B,T), all four use the output chosen at the accepted header, and
// route_port changes after the header do not matter.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_packet_tracker;

    reg         clk, rst_n;
    reg         head_valid;
    reg  [1:0]  head_type;
    reg  [15:0] head_data;
    reg  [4:0]  route_port;
    reg         xfer;

    wire [1:0]  hdr_dst_x, hdr_dst_y, hdr_src_x, hdr_src_y;
    wire        req_valid, req_new, locked, proto_err;
    wire [4:0]  req_port, locked_port;

    packet_tracker dut (
        .clk(clk), .rst_n(rst_n),
        .head_valid(head_valid), .head_type(head_type), .head_data(head_data),
        .route_port(route_port), .xfer(xfer),
        .hdr_dst_x(hdr_dst_x), .hdr_dst_y(hdr_dst_y),
        .hdr_src_x(hdr_src_x), .hdr_src_y(hdr_src_y),
        .req_valid(req_valid), .req_port(req_port), .req_new(req_new),
        .locked(locked), .locked_port(locked_port), .proto_err(proto_err)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- model ----------------
    reg        m_locked;
    reg [4:0]  m_port;
    integer    errors, checks;
    integer    n_stalled_hdr, n_cont, n_release, n_err_flags, n_zero_route, n_xfer_novalid;
    integer    n_packets, n_hold_cycles;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | v=%b t=%b rp=%b x=%b | req_v=%b req_p=%b new=%b lk=%b lp=%b pe=%b (model lk=%b lp=%b)",
                         $time, msg, head_valid, head_type, route_port, xfer,
                         req_valid, req_port, req_new, locked, locked_port, proto_err, m_locked, m_port);
        end
    endtask

    // expected combinational outputs from the model and the current inputs
    reg        e_new, e_valid, e_err;
    reg [4:0]  e_port;
    task expect_outputs;
        begin
            e_new   = head_valid && !m_locked && (head_type == `HY_FT_HEADER) && (route_port != 5'b0);
            e_valid = head_valid && (m_locked || e_new);
            e_port  = !e_valid ? 5'b0 : (m_locked ? m_port : route_port);
            e_err   = head_valid && ( (head_type == `HY_FT_RSVD) ||
                                      (!m_locked && head_type != `HY_FT_HEADER) ||
                                      ( m_locked && head_type == `HY_FT_HEADER) );
        end
    endtask

    task check_outputs;
        begin
            checks = checks + 1;
            expect_outputs;
            if (req_new    !== e_new)    fail("req_new");
            if (req_valid  !== e_valid)  fail("req_valid");
            if (req_port   !== e_port)   fail("req_port");
            if (proto_err  !== e_err)    fail("proto_err");
            if (locked     !== m_locked) fail("locked");
            if (locked_port !== m_port)  fail("locked_port");
            if (hdr_dst_x !== head_data[15:14]) fail("dst_x");
            if (hdr_dst_y !== head_data[13:12]) fail("dst_y");
            if (hdr_src_x !== head_data[11:10]) fail("src_x");
            if (hdr_src_y !== head_data[9:8])   fail("src_y");
            if (e_err) n_err_flags = n_err_flags + 1;
            if (head_valid && !m_locked && head_type == `HY_FT_HEADER && route_port == 5'b0)
                n_zero_route = n_zero_route + 1;
            if (xfer && !head_valid) n_xfer_novalid = n_xfer_novalid + 1;
        end
    endtask

    // advance model state on the clock edge using pre-edge inputs
    task model_update;
        reg xfer_ok, new_ok;
        begin
            xfer_ok = xfer && head_valid;
            new_ok  = head_valid && !m_locked && (head_type == `HY_FT_HEADER) && (route_port != 5'b0);
            if (xfer_ok) begin
                if (!m_locked) begin
                    if (new_ok) begin m_locked = 1'b1; m_port = route_port; end
                end else if (head_type == `HY_FT_TAIL) begin
                    m_locked = 1'b0; m_port = 5'b0;
                    n_release = n_release + 1;
                end
            end
            if (head_valid && !xfer && !m_locked && head_type == `HY_FT_HEADER && route_port != 0)
                n_stalled_hdr = n_stalled_hdr + 1;
            if (head_valid && m_locked && !xfer) n_hold_cycles = n_hold_cycles + 1;
            if (xfer_ok && m_locked && head_type != `HY_FT_HEADER) n_cont = n_cont + 1;
        end
    endtask

    // one cycle: drive, check, clock, update model
    task step;
        input        v;
        input [1:0]  t;
        input [15:0] d;
        input [4:0]  rp;
        input        x;
        begin
            head_valid = v; head_type = t; head_data = d; route_port = rp; xfer = x;
            #1;
            check_outputs;
            @(posedge clk);
            #1;
            model_update;
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            head_valid = 1'b1; head_type = `HY_FT_TAIL; head_data = 16'hFFFF;
            route_port = `HY_PM_E; xfer = 1'b1;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1'b1; xfer = 1'b0; head_valid = 1'b0;
            m_locked = 1'b0; m_port = 5'b0;
        end
    endtask

    // ---------------- legal random traffic ----------------
    integer seed, r, c, k;
    reg [4:0] rp_rand;

    function [4:0] rnd_onehot;
        input integer rr;
        begin
            case (rr % 6)
                0: rnd_onehot = `HY_PM_N;
                1: rnd_onehot = `HY_PM_S;
                2: rnd_onehot = `HY_PM_E;
                3: rnd_onehot = `HY_PM_W;
                4: rnd_onehot = `HY_PM_L;
                default: rnd_onehot = 5'b0;
            endcase
        end
    endfunction

    // packet-level checker state
    integer    pk_pos;            // flits accepted in the current packet
    reg [4:0]  pk_port;           // port of the current packet
    reg [4:0]  hdr_rp_at_xfer;

    task legal_run;
        input integer packets;
        input integer p_valid;    // percent chance the next flit is present
        input integer p_acc;      // percent chance an offered request is accepted
        integer pk, f;
        reg [1:0] ft;
        reg [15:0] fd;
        reg done;
        begin
            for (pk = 0; pk < packets; pk = pk + 1) begin
                for (f = 0; f < 4; f = f + 1) begin
                    ft = (f == 0) ? `HY_FT_HEADER : (f == 3) ? `HY_FT_TAIL : `HY_FT_BODY;
                    fd = $random(seed);
                    // gap before the flit appears at the head
                    r = $random(seed); if (r < 0) r = -r;
                    while ((r % 100) >= p_valid) begin
                        r = $random(seed); if (r < 0) r = -r;
                        rp_rand = rnd_onehot(r);
                        step(1'b0, 2'b00, $random(seed), rp_rand, 1'b0);
                        r = $random(seed); if (r < 0) r = -r;
                    end
                    // present the flit until accepted (head stays stable)
                    done = 1'b0;
                    while (!done) begin
                        r = $random(seed); if (r < 0) r = -r;
                        rp_rand = rnd_onehot(r);
                        if ((r / 8) % 7 == 0) rp_rand = 5'b0;          // sometimes no route
                        r = $random(seed); if (r < 0) r = -r;
                        // accept only if the DUT requests, with probability p_acc
                        head_valid = 1'b1; head_type = ft; head_data = fd; route_port = rp_rand;
                        #1;
                        xfer = (req_valid === 1'b1) && ((r % 100) < p_acc);
                        // pre-sample for packet-level check
                        if (xfer) begin
                            if (f == 0) begin
                                pk_port = rp_rand; pk_pos = 1;
                                if (req_port !== rp_rand) fail("hdr accepted on wrong port");
                            end else begin
                                pk_pos = pk_pos + 1;
                                if (req_port !== pk_port)  fail("continuation left reserved port");
                                if (!locked)               fail("continuation not locked");
                            end
                            if (f == 3 && pk_pos != 4)     fail("packet length != 4");
                            done = 1'b1;
                        end
                        step(1'b1, ft, fd, rp_rand, xfer);
                    end
                end
                n_packets = n_packets + 1;
                if (locked !== 1'b0 || m_locked !== 1'b0) fail("still locked after tail");
            end
        end
    endtask

    // ---------------- random illegal traffic ----------------
    task illegal_run;
        input integer cycles;
        integer q;
        reg [4:0] rp;
        begin
            for (q = 0; q < cycles; q = q + 1) begin
                r = $random(seed); if (r < 0) r = -r;
                rp = (r % 3 == 0) ? 5'b0 : rnd_onehot(r / 3);
                step($random(seed), $random(seed), $random(seed), rp, $random(seed));
            end
        end
    endtask

    integer j;

    initial begin
        errors = 0; checks = 0; seed = 32'h0BADC0DE;
        n_stalled_hdr = 0; n_cont = 0; n_release = 0; n_err_flags = 0;
        n_zero_route = 0; n_xfer_novalid = 0; n_packets = 0; n_hold_cycles = 0;
        pk_pos = 0; pk_port = 0;
        m_locked = 1'b0; m_port = 5'b0;
        head_valid = 0; head_type = 0; head_data = 0; route_port = 0; xfer = 0; rst_n = 1'b0;
        do_reset;

        // ---- T1: idle / reset state ----
        step(0, 2'b00, 16'h0, 5'b0, 0);
        if (locked !== 1'b0 || req_valid !== 1'b0) fail("T1 reset state");

        // ---- T2: header fields parsed from every field position ----
        step(1, `HY_FT_HEADER, 16'b11_10_01_00_1010_0101, `HY_PM_E, 0);
        if (hdr_dst_x !== 2'b11 || hdr_dst_y !== 2'b10 || hdr_src_x !== 2'b01 || hdr_src_y !== 2'b00)
            fail("T2 header fields");
        if (req_valid !== 1'b1 || req_new !== 1'b1 || req_port !== `HY_PM_E) fail("T2 header request");

        // ---- T3: stalled header reserves nothing and follows route_port ----
        step(1, `HY_FT_HEADER, 16'h1234, `HY_PM_E, 0);
        step(1, `HY_FT_HEADER, 16'h1234, `HY_PM_S, 0);
        if (locked !== 1'b0) fail("T3 stalled header must not lock");
        if (req_port !== `HY_PM_S) fail("T3 request must follow route_port while stalled");

        // ---- T4: accepted header locks the port of THAT cycle ----
        step(1, `HY_FT_HEADER, 16'h1234, `HY_PM_W, 1);
        if (locked !== 1'b1 || locked_port !== `HY_PM_W) fail("T4 lock not taken");

        // ---- T5: body ignores route_port, holds under long backpressure ----
        for (j = 0; j < 25; j = j + 1) begin
            step(1, `HY_FT_BODY, 16'hB0B0, (j % 2) ? `HY_PM_N : `HY_PM_L, 0);
            if (req_port !== `HY_PM_W || req_new !== 1'b0 || locked !== 1'b1) fail("T5 hold broken");
        end
        step(1, `HY_FT_BODY, 16'hB0B0, `HY_PM_N, 1);
        step(1, `HY_FT_BODY, 16'hB0B1, 5'b0, 1);            // route_port==0 irrelevant
        if (locked !== 1'b1) fail("T5 released before tail");

        // ---- T6: tail stalled keeps lock, accepted tail releases ----
        step(1, `HY_FT_TAIL, 16'h7A11, `HY_PM_S, 0);
        step(1, `HY_FT_TAIL, 16'h7A11, `HY_PM_S, 0);
        if (locked !== 1'b1 || req_port !== `HY_PM_W) fail("T6 tail stall");
        step(1, `HY_FT_TAIL, 16'h7A11, `HY_PM_S, 1);
        if (locked !== 1'b0 || locked_port !== 5'b0) fail("T6 tail did not release");

        // ---- T7: header with route_port==0 makes no request and cannot lock ----
        step(1, `HY_FT_HEADER, 16'h4321, 5'b0, 0);
        if (req_valid !== 1'b0 || req_new !== 1'b0) fail("T7 request with no route");
        step(1, `HY_FT_HEADER, 16'h4321, 5'b0, 1);          // xfer anyway: ignored
        if (locked !== 1'b0) fail("T7 locked without route");

        // ---- T8: xfer without a valid head is ignored (unlocked and locked) ----
        step(0, `HY_FT_HEADER, 16'h0, `HY_PM_E, 1);
        if (locked !== 1'b0) fail("T8a xfer without valid locked");
        step(1, `HY_FT_HEADER, 16'h2222, `HY_PM_N, 1);
        step(0, `HY_FT_TAIL, 16'h0, `HY_PM_E, 1);           // would release if it counted
        if (locked !== 1'b1) fail("T8b xfer without valid released");
        step(1, `HY_FT_TAIL, 16'h2222, 5'b0, 1);
        if (locked !== 1'b0) fail("T8c release");

        // ---- T9: protocol errors flagged, state otherwise unchanged ----
        step(1, `HY_FT_BODY, 16'h0, `HY_PM_E, 1);           // body while unlocked
        if (proto_err !== 1'b1 || locked !== 1'b0 || req_valid !== 1'b0) fail("T9a body unlocked");
        step(1, `HY_FT_RSVD, 16'h0, `HY_PM_E, 1);
        if (proto_err !== 1'b1 || locked !== 1'b0) fail("T9b reserved type");
        step(1, `HY_FT_TAIL, 16'h0, `HY_PM_E, 1);           // tail while unlocked
        if (locked !== 1'b0) fail("T9c tail unlocked");
        step(1, `HY_FT_HEADER, 16'h0, `HY_PM_E, 1);        // legal lock
        step(1, `HY_FT_HEADER, 16'h0, `HY_PM_N, 1);        // header while locked
        if (proto_err !== 1'b1 || locked !== 1'b1 || locked_port !== `HY_PM_E) fail("T9d header while locked");
        step(1, `HY_FT_RSVD, 16'h0, `HY_PM_N, 1);          // reserved while locked: not a tail
        if (locked !== 1'b1) fail("T9e reserved released lock");
        step(0, `HY_FT_BODY, 16'h0, 5'b0, 0);
        if (proto_err !== 1'b0) fail("T9f err without valid");

        // ---- T10: reset while locked ----
        step(1, `HY_FT_BODY, 16'h0, 5'b0, 0);
        do_reset;
        step(0, 0, 16'h0, 5'b0, 0);
        if (locked !== 1'b0 || locked_port !== 5'b0) fail("T10 reset did not clear lock");

        // ---- T11: random legal traffic, several load points ----
        legal_run(3000, 100, 100);   // back-to-back
        legal_run(3000, 100, 30);    // heavy backpressure
        legal_run(3000, 30, 100);    // starved
        legal_run(3000, 50, 50);
        do_reset;
        legal_run(3000, 80, 20);

        // ---- T12: random illegal traffic vs. model ----
        illegal_run(60000);
        do_reset;
        illegal_run(60000);
        step(0, 0, 16'h0, 5'b0, 0);

        $display("INFO: cycles checked=%0d packets=%0d", checks, n_packets);
        $display("INFO: coverage stalled_hdr=%0d continuation_xfers=%0d releases=%0d hold_cycles=%0d proto_err_cycles=%0d zero_route_hdr=%0d xfer_without_valid=%0d",
                 n_stalled_hdr, n_cont, n_release, n_hold_cycles, n_err_flags, n_zero_route, n_xfer_novalid);
        if (n_stalled_hdr == 0 || n_cont == 0 || n_release == 0 || n_hold_cycles == 0 ||
            n_err_flags == 0 || n_zero_route == 0 || n_xfer_novalid == 0) begin
            errors = errors + 1;
            $display("ERROR: a coverage corner was never exercised");
        end

        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
