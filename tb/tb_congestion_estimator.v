// =============================================================================
// tb_congestion_estimator.v : self-checking testbench (Verilog-2001)
//
// 1. Directed: each direction alone, all five occupancy values (hard-coded map),
//    maximum across directions, exclusion of unavailable directions, all
//    unavailable, available-with-zero vs unavailable, corner/edge router
//    availability patterns, clamp of illegal occupancy 5..7.
// 2. Exhaustive: all 8^4 occupancy combinations x 16 availability patterns
//    (65,536 cases) against an independent model.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_congestion_estimator;

    reg  [2:0] occ_n, occ_s, occ_e, occ_w;
    reg        av_n, av_s, av_e, av_w;
    wire [2:0] max_occ;
    wire [7:0] cong;
    wire       any_avail;

    congestion_estimator dut (
        .occ_n(occ_n), .occ_s(occ_s), .occ_e(occ_e), .occ_w(occ_w),
        .avail_n(av_n), .avail_s(av_s), .avail_e(av_e), .avail_w(av_w),
        .max_occ(max_occ), .cong(cong), .any_avail(any_avail));

    integer errors;
    integer checked;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | occ N%0d S%0d E%0d W%0d avail %b%b%b%b -> max=%0d cong=%0d any=%b",
                         $time, msg, occ_n, occ_s, occ_e, occ_w, av_n, av_s, av_e, av_w, max_occ, cong, any_avail);
        end
    endtask

    // independent model helpers (integers)
    function integer clampi;
        input integer v;
        begin
            clampi = (v > 4) ? 4 : v;
        end
    endfunction

    function integer mapi;
        input integer o;
        begin
            case (o)
                0: mapi = 0;
                1: mapi = 64;
                2: mapi = 128;
                3: mapi = 192;
                default: mapi = 255;
            endcase
        end
    endfunction

    integer mmax;
    reg     many;

    task model_and_check;
        begin
            #1;
            mmax = 0;
            if (av_n && clampi(occ_n) > mmax) mmax = clampi(occ_n);
            if (av_s && clampi(occ_s) > mmax) mmax = clampi(occ_s);
            if (av_e && clampi(occ_e) > mmax) mmax = clampi(occ_e);
            if (av_w && clampi(occ_w) > mmax) mmax = clampi(occ_w);
            many = av_n | av_s | av_e | av_w;
            checked = checked + 1;
            if (max_occ !== mmax[2:0])        fail("max_occ mismatch");
            if (cong    !== mapi(mmax))       fail("cong mismatch");
            if (any_avail !== many)           fail("any_avail mismatch");
        end
    endtask

    // set all inputs and check against hard-coded expectations
    task expect_case;
        input [2:0] n; input [2:0] s; input [2:0] e; input [2:0] w;
        input       an; input       as; input       ae; input       aw;
        input [2:0] exp_max; input [7:0] exp_cong; input exp_any;
        begin
            occ_n = n; occ_s = s; occ_e = e; occ_w = w;
            av_n = an; av_s = as; av_e = ae; av_w = aw;
            #1;
            checked = checked + 1;
            if (max_occ !== exp_max)     fail("directed: max_occ");
            if (cong !== exp_cong)       fail("directed: cong");
            if (any_avail !== exp_any)   fail("directed: any_avail");
        end
    endtask

    integer o;
    integer a;
    integer i0, i1, i2, i3, i4;
    reg [7:0] tbl [0:4];

    initial begin
        errors = 0; checked = 0;
        tbl[0] = 8'd0; tbl[1] = 8'd64; tbl[2] = 8'd128; tbl[3] = 8'd192; tbl[4] = 8'd255;

        // ---- D1: each direction alone, all five occupancies, hard-coded map ----
        for (o = 0; o <= 4; o = o + 1) begin
            expect_case(o[2:0], 3'd0, 3'd0, 3'd0,  1'b1,1'b0,1'b0,1'b0,  o[2:0], tbl[o], 1'b1);
            expect_case(3'd0, o[2:0], 3'd0, 3'd0,  1'b0,1'b1,1'b0,1'b0,  o[2:0], tbl[o], 1'b1);
            expect_case(3'd0, 3'd0, o[2:0], 3'd0,  1'b0,1'b0,1'b1,1'b0,  o[2:0], tbl[o], 1'b1);
            expect_case(3'd0, 3'd0, 3'd0, o[2:0],  1'b0,1'b0,1'b0,1'b1,  o[2:0], tbl[o], 1'b1);
        end

        // ---- D2: the frozen map explicitly (so a table typo cannot hide in the model) ----
        expect_case(3'd0,3'd0,3'd0,3'd0, 1,1,1,1, 3'd0, 8'd0,   1'b1);
        expect_case(3'd1,3'd0,3'd0,3'd0, 1,1,1,1, 3'd1, 8'd64,  1'b1);
        expect_case(3'd0,3'd2,3'd0,3'd0, 1,1,1,1, 3'd2, 8'd128, 1'b1);
        expect_case(3'd0,3'd0,3'd3,3'd0, 1,1,1,1, 3'd3, 8'd192, 1'b1);
        expect_case(3'd0,3'd0,3'd0,3'd4, 1,1,1,1, 3'd4, 8'd255, 1'b1);

        // ---- D3: maximum across directions ----
        expect_case(3'd1,3'd3,3'd2,3'd0, 1,1,1,1, 3'd3, 8'd192, 1'b1);
        expect_case(3'd4,3'd4,3'd4,3'd4, 1,1,1,1, 3'd4, 8'd255, 1'b1);
        expect_case(3'd2,3'd2,3'd2,3'd2, 1,1,1,1, 3'd2, 8'd128, 1'b1);

        // ---- D4: unavailable directions are excluded (even with high occupancy) ----
        expect_case(3'd4,3'd1,3'd1,3'd1, 0,1,1,1, 3'd1, 8'd64,  1'b1);   // N unavailable, occ 4 ignored
        expect_case(3'd1,3'd4,3'd1,3'd1, 1,0,1,1, 3'd1, 8'd64,  1'b1);
        expect_case(3'd1,3'd1,3'd4,3'd1, 1,1,0,1, 3'd1, 8'd64,  1'b1);
        expect_case(3'd1,3'd1,3'd1,3'd4, 1,1,1,0, 3'd1, 8'd64,  1'b1);

        // ---- D5: all unavailable ----
        expect_case(3'd4,3'd4,3'd4,3'd4, 0,0,0,0, 3'd0, 8'd0,   1'b0);
        expect_case(3'd0,3'd0,3'd0,3'd0, 0,0,0,0, 3'd0, 8'd0,   1'b0);

        // ---- D6: available with occupancy 0 differs from unavailable only by any_avail ----
        expect_case(3'd0,3'd0,3'd0,3'd0, 1,0,0,0, 3'd0, 8'd0,   1'b1);

        // ---- D7: corner router (0,0): no North, no West (x grows East, y grows South) ----
        expect_case(3'd4,3'd2,3'd3,3'd4, 0,1,1,0, 3'd3, 8'd192, 1'b1);
        // corner router (3,3): no South, no East
        expect_case(3'd2,3'd4,3'd4,3'd1, 1,0,0,1, 3'd2, 8'd128, 1'b1);

        // ---- D8: illegal occupancy 5..7 clamps to 4 (255) ----
        expect_case(3'd5,3'd0,3'd0,3'd0, 1,1,1,1, 3'd4, 8'd255, 1'b1);
        expect_case(3'd0,3'd6,3'd0,3'd0, 1,1,1,1, 3'd4, 8'd255, 1'b1);
        expect_case(3'd0,3'd0,3'd7,3'd0, 1,1,1,1, 3'd4, 8'd255, 1'b1);
        expect_case(3'd7,3'd0,3'd0,3'd0, 0,1,1,1, 3'd0, 8'd0,   1'b1);   // illegal value but unavailable

        // ---- E1: exhaustive, 8^4 x 16 = 65,536 combinations ----
        for (a = 0; a < 16; a = a + 1) begin
            av_n = a[3]; av_s = a[2]; av_e = a[1]; av_w = a[0];
            for (i1 = 0; i1 < 8; i1 = i1 + 1)
              for (i2 = 0; i2 < 8; i2 = i2 + 1)
                for (i3 = 0; i3 < 8; i3 = i3 + 1)
                  for (i4 = 0; i4 < 8; i4 = i4 + 1) begin
                      occ_n = i1[2:0]; occ_s = i2[2:0]; occ_e = i3[2:0]; occ_w = i4[2:0];
                      model_and_check;
                  end
        end

        $display("INFO: cases checked=%0d (directed + 65536 exhaustive)", checked);
        if (checked < 65536) begin errors = errors + 1; $display("ERROR: exhaustive loop incomplete"); end
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
