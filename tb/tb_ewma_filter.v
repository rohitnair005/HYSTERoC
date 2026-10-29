// =============================================================================
// tb_ewma_filter.v : self-checking testbench for ewma_filter (Verilog-2001)
//
// Two DUTs share the same stimulus: SAMPLE_PERIOD = 1 (default) and = 4.
// An integer reference model (S - S/8 + C) is compared with both DUTs after
// every clock edge. Hard-coded expected values (not taken from the model) cover
// the spec vector 255,479,675,... and the settling rules.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_ewma_filter;

    reg         clk;
    reg         rst_n;
    reg         enable;
    reg  [7:0]  sample;

    wire [10:0] s1;  wire [7:0] e1;      // SAMPLE_PERIOD = 1
    wire [10:0] s4;  wire [7:0] e4;      // SAMPLE_PERIOD = 4

    ewma_filter #(.SAMPLE_PERIOD(1)) dut1 (
        .clk(clk), .rst_n(rst_n), .enable(enable), .sample(sample), .s_out(s1), .e_out(e1));
    ewma_filter #(.SAMPLE_PERIOD(4)) dut4 (
        .clk(clk), .rst_n(rst_n), .enable(enable), .sample(sample), .s_out(s4), .e_out(e4));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    integer ms1;                 // model of S for period 1
    integer ms4;                 // model of S for period 4
    integer mc4;                 // model of period counter for period 4
    integer errors;
    integer cycles;
    integer ticks4;              // number of S updates seen on the period-4 model
    integer frozen_cycles;
    integer resets_seen;
    integer max_s_seen;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | S1 dut=%0d model=%0d | S4 dut=%0d model=%0d | en=%b C=%0d",
                         $time, msg, s1, ms1, s4, ms4, enable, sample);
        end
    endtask

    task compare;
        begin
            if (s1 !== ms1[10:0])      fail("period-1 S mismatch");
            if (e1 !== (ms1 / 8))      fail("period-1 E mismatch");
            if (s4 !== ms4[10:0])      fail("period-4 S mismatch");
            if (e4 !== (ms4 / 8))      fail("period-4 E mismatch");
            if (ms1 > max_s_seen) max_s_seen = ms1;
            if (ms4 > max_s_seen) max_s_seen = ms4;
            if (s1 > 11'd2040 || s4 > 11'd2040) fail("S exceeded 8*255 (overflow risk)");
        end
    endtask

    // one clock cycle with the given enable and sample; model + compare after the edge
    task cyc;
        input       en;
        input [7:0] c;
        begin
            enable = en;
            sample = c;
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (!rst_n) begin
                ms1 = 0; ms4 = 0; mc4 = 0;
            end else if (en) begin
                ms1 = ms1 - (ms1 / 8) + c;
                if (mc4 == 3) begin
                    ms4 = ms4 - (ms4 / 8) + c;
                    mc4 = 0;
                    ticks4 = ticks4 + 1;
                end else begin
                    mc4 = mc4 + 1;
                end
            end else begin
                frozen_cycles = frozen_cycles + 1;
            end
            compare;
        end
    endtask

    task do_reset;
        begin
            resets_seen = resets_seen + 1;
            rst_n = 1'b0;
            cyc(1'b1, 8'd255);       // enable and a big sample while in reset: must be ignored
            cyc(1'b0, 8'd255);
            rst_n = 1'b1;
        end
    endtask

    // ---------------- helpers ----------------
    integer k;
    integer prev_s;
    integer target;
    integer idx;
    reg [7:0] cset [0:9];
    reg       mono_ok;

    // random stimulus state
    integer seed;
    integer r;
    reg [7:0] rc;
    integer run_left;
    reg       en_r;

    initial begin
        errors = 0; cycles = 0; ticks4 = 0; frozen_cycles = 0; resets_seen = 0; max_s_seen = 0;
        ms1 = 0; ms4 = 0; mc4 = 0;
        seed = 32'h0BADF00D;
        rst_n = 1'b0; enable = 1'b0; sample = 8'd0;
        cset[0] = 8'd0;   cset[1] = 8'd1;   cset[2] = 8'd7;   cset[3] = 8'd8;   cset[4] = 8'd64;
        cset[5] = 8'd100; cset[6] = 8'd128; cset[7] = 8'd160; cset[8] = 8'd254; cset[9] = 8'd255;
        do_reset;

        // ---- T1: reset state ----
        if (s1 !== 11'd0 || e1 !== 8'd0 || s4 !== 11'd0 || e4 !== 8'd0) fail("T1 reset values not zero");

        // ---- T2: spec vector, C = 255 from reset (hard-coded expectations) ----
        cyc(1'b1, 8'd255);
        if (s1 !== 11'd255 || e1 !== 8'd31)  fail("T2 step1 expected S=255 E=31");
        cyc(1'b1, 8'd255);
        if (s1 !== 11'd479 || e1 !== 8'd59)  fail("T2 step2 expected S=479 E=59");
        cyc(1'b1, 8'd255);
        if (s1 !== 11'd675 || e1 !== 8'd84)  fail("T2 step3 expected S=675 E=84");
        cyc(1'b1, 8'd255);
        if (s1 !== 11'd846 || e1 !== 8'd105) fail("T2 step4 expected S=846 E=105");
        cyc(1'b1, 8'd255);
        if (s1 !== 11'd996 || e1 !== 8'd124) fail("T2 step5 expected S=996 E=124");

        // ---- T3: constant inputs from reset: monotone rise, E never above C, lands exactly on 8*C ----
        for (idx = 0; idx < 10; idx = idx + 1) begin
            do_reset;
            prev_s = 0; mono_ok = 1'b1;
            for (k = 0; k < 400; k = k + 1) begin
                cyc(1'b1, cset[idx]);
                if (s1 < prev_s)       mono_ok = 1'b0;
                if (e1 > cset[idx])    fail("T3 E overshoot above constant input");
                prev_s = s1;
            end
            if (!mono_ok)                       fail("T3 S not monotone on rise");
            if (s1 !== cset[idx] * 8)           fail("T3 S did not settle at 8*C");
            if (e1 !== cset[idx])               fail("T3 E did not settle at C");
        end

        // ---- T4: falling from 255 to each C: E settles exactly at C, S stops at 8*C+7 ----
        for (idx = 0; idx < 9; idx = idx + 1) begin           // C = 255 excluded (no fall)
            do_reset;
            for (k = 0; k < 300; k = k + 1) cyc(1'b1, 8'd255);
            if (s1 !== 11'd2040) fail("T4 setup: S should be 2040");
            prev_s = s1; mono_ok = 1'b1;
            for (k = 0; k < 600; k = k + 1) begin
                cyc(1'b1, cset[idx]);
                if (s1 > prev_s) mono_ok = 1'b0;
                prev_s = s1;
            end
            if (!mono_ok)                         fail("T4 S not monotone on fall");
            if (e1 !== cset[idx])                 fail("T4 E did not settle at C when falling");
            if (s1 !== cset[idx] * 8 + 7)         fail("T4 S expected to stop at 8*C+7 when falling");
        end

        // ---- T5: sample period 4 explicit timing + enable freeze (hard-coded) ----
        do_reset;
        cyc(1'b1, 8'd255); cyc(1'b1, 8'd255); cyc(1'b1, 8'd255);
        if (s4 !== 11'd0)   fail("T5 period-4 must not update before 4th enabled cycle");
        cyc(1'b1, 8'd255);
        if (s4 !== 11'd255) fail("T5 period-4 must update on 4th enabled cycle");
        do_reset;
        cyc(1'b1, 8'd255); cyc(1'b1, 8'd255);                 // 2 enabled cycles (counter = 2)
        for (k = 0; k < 9; k = k + 1) cyc(1'b0, 8'd255);      // frozen: counter must hold
        if (s4 !== 11'd0)   fail("T5 frozen period-4 changed S");
        cyc(1'b1, 8'd255);                                    // 3rd enabled cycle: still no update
        if (s4 !== 11'd0)   fail("T5 counter did not hold during freeze (updated early)");
        cyc(1'b1, 8'd255);                                    // 4th enabled cycle: update
        if (s4 !== 11'd255) fail("T5 counter did not hold during freeze (no update on 4th)");

        // ---- T6: freeze keeps S exactly, whatever the sample ----
        do_reset;
        for (k = 0; k < 30; k = k + 1) cyc(1'b1, 8'd200);
        prev_s = s1;
        for (k = 0; k < 40; k = k + 1) begin
            cyc(1'b0, k[7:0] * 8'd7);
            if (s1 !== prev_s[10:0]) fail("T6 S changed while enable=0");
        end

        // ---- T7: reset in the middle of a run ----
        for (k = 0; k < 20; k = k + 1) cyc(1'b1, 8'd180);
        do_reset;
        if (s1 !== 11'd0 || s4 !== 11'd0) fail("T7 reset did not clear");

        // ---- T8: steps up and down, with large jumps ----
        for (k = 0; k < 3; k = k + 1) begin
            for (idx = 0; idx < 80;  idx = idx + 1) cyc(1'b1, 8'd255);
            for (idx = 0; idx < 80;  idx = idx + 1) cyc(1'b1, 8'd0);
            for (idx = 0; idx < 60;  idx = idx + 1) cyc(1'b1, 8'd128);
            for (idx = 0; idx < 60;  idx = idx + 1) cyc(1'b1, 8'd64);
        end

        // ---- T9: long random run (runs of constants, extremes, random enable, rare resets) ----
        run_left = 0; rc = 8'd0; en_r = 1'b1;
        for (k = 0; k < 300000; k = k + 1) begin
            if (run_left == 0) begin
                r = $random(seed); if (r < 0) r = -r;
                case (r % 6)
                    0: rc = 8'd0;
                    1: rc = 8'd255;
                    2: rc = 8'd128;
                    default: rc = $random(seed);
                endcase
                r = $random(seed); if (r < 0) r = -r;
                run_left = 1 + (r % 60);
            end
            run_left = run_left - 1;
            r = $random(seed); if (r < 0) r = -r;
            en_r = ((r % 100) < 88);
            r = $random(seed); if (r < 0) r = -r;
            if ((r % 5000) == 0) begin
                do_reset;
            end else begin
                if ((r % 7) == 0) cyc(en_r, $random(seed)); else cyc(en_r, rc);
            end
        end

        // ---- summary ----
        $display("INFO: cycles=%0d period4_updates=%0d frozen_cycles=%0d resets=%0d max_S_seen=%0d (limit 2040)",
                 cycles, ticks4, frozen_cycles, resets_seen, max_s_seen);
        if (ticks4 < 1000)        begin errors = errors + 1; $display("ERROR: too few period-4 updates exercised"); end
        if (frozen_cycles < 1000) begin errors = errors + 1; $display("ERROR: too few frozen cycles exercised"); end
        if (max_s_seen != 2040)   begin errors = errors + 1; $display("ERROR: S never reached 2040 (max C not exercised)"); end

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
