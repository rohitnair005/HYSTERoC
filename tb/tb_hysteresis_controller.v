// =============================================================================
// tb_hysteresis_controller.v : self-checking testbench (Verilog-2001)
//
// Five DUTs on the same stimulus:
//   A : HYSTERoC            DUAL=1 USE_EWMA=1  160/96
//   B : Ablation B          DUAL=1 USE_EWMA=0  160/96
//   C : Ablation A          DUAL=0 USE_EWMA=1  single 128
//   D : conventional hybrid DUAL=0 USE_EWMA=0  single 128
//   E : configurability     DUAL=1 USE_EWMA=1  200/50
// Checks: hard-coded edge cases, EXHAUSTIVE (start state x all 256 values) for
// every DUT, band hold, enable hold, mode_change_request, input-source selection
// (value_ewma != value_raw), the oscillation demo (dual vs single), and a long
// random run against an independent model.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_hysteresis_controller;

    reg         clk;
    reg         rst_n;
    reg         enable;
    reg  [7:0]  v_ewma;
    reg  [7:0]  v_raw;
    reg         active_mode;

    wire reqA, reqB, reqC, reqD, reqE;
    wire mcrA, mcrB, mcrC, mcrD, mcrE;

    hysteresis_controller #(.DUAL(1), .USE_EWMA(1), .THIGH(8'd160), .TLOW(8'd96), .THRESH_SINGLE(8'd128)) dA (
        .clk(clk), .rst_n(rst_n), .enable(enable), .value_ewma(v_ewma), .value_raw(v_raw),
        .active_mode(active_mode), .req_mode(reqA), .mode_change_request(mcrA));
    hysteresis_controller #(.DUAL(1), .USE_EWMA(0), .THIGH(8'd160), .TLOW(8'd96), .THRESH_SINGLE(8'd128)) dB (
        .clk(clk), .rst_n(rst_n), .enable(enable), .value_ewma(v_ewma), .value_raw(v_raw),
        .active_mode(active_mode), .req_mode(reqB), .mode_change_request(mcrB));
    hysteresis_controller #(.DUAL(0), .USE_EWMA(1), .THIGH(8'd160), .TLOW(8'd96), .THRESH_SINGLE(8'd128)) dC (
        .clk(clk), .rst_n(rst_n), .enable(enable), .value_ewma(v_ewma), .value_raw(v_raw),
        .active_mode(active_mode), .req_mode(reqC), .mode_change_request(mcrC));
    hysteresis_controller #(.DUAL(0), .USE_EWMA(0), .THIGH(8'd160), .TLOW(8'd96), .THRESH_SINGLE(8'd128)) dD (
        .clk(clk), .rst_n(rst_n), .enable(enable), .value_ewma(v_ewma), .value_raw(v_raw),
        .active_mode(active_mode), .req_mode(reqD), .mode_change_request(mcrD));
    hysteresis_controller #(.DUAL(1), .USE_EWMA(1), .THIGH(8'd200), .TLOW(8'd50), .THRESH_SINGLE(8'd128)) dE (
        .clk(clk), .rst_n(rst_n), .enable(enable), .value_ewma(v_ewma), .value_raw(v_raw),
        .active_mode(active_mode), .req_mode(reqE), .mode_change_request(mcrE));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- independent model ----------------
    reg mA, mB, mC, mD, mE;          // model states (requested mode)
    integer errors;
    integer cycles;
    integer en_hold_cycles;
    integer band_hold_cycles;

    // next-state function written differently from the RTL (arithmetic form)
    function nxt;
        input        st;
        input integer v;
        input integer dual;
        input integer thigh;
        input integer tlow;
        input integer tsingle;
        begin
            if (dual != 0) begin
                if (st == 1'b0) nxt = (v >= thigh) ? 1'b1 : 1'b0;
                else            nxt = (v <= tlow)  ? 1'b0 : 1'b1;
            end else begin
                nxt = (v >= tsingle) ? 1'b1 : 1'b0;
            end
        end
    endfunction

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | ewma=%0d raw=%0d en=%b act=%b | dut A%b B%b C%b D%b E%b | model A%b B%b C%b D%b E%b",
                         $time, msg, v_ewma, v_raw, enable, active_mode,
                         reqA, reqB, reqC, reqD, reqE, mA, mB, mC, mD, mE);
        end
    endtask

    task compare;
        begin
            if (reqA !== mA) fail("A (HYSTERoC) req_mode mismatch");
            if (reqB !== mB) fail("B (dual raw) req_mode mismatch");
            if (reqC !== mC) fail("C (single EWMA) req_mode mismatch");
            if (reqD !== mD) fail("D (single raw) req_mode mismatch");
            if (reqE !== mE) fail("E (200/50) req_mode mismatch");
            if (mcrA !== (reqA != active_mode)) fail("A mode_change_request");
            if (mcrB !== (reqB != active_mode)) fail("B mode_change_request");
            if (mcrC !== (reqC != active_mode)) fail("C mode_change_request");
            if (mcrD !== (reqD != active_mode)) fail("D mode_change_request");
            if (mcrE !== (reqE != active_mode)) fail("E mode_change_request");
        end
    endtask

    // one clock cycle: drive inputs, clock, update models, compare
    task cyc;
        input        en;
        input [7:0]  ve;
        input [7:0]  vr;
        begin
            enable = en; v_ewma = ve; v_raw = vr;
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            if (!rst_n) begin
                mA = 0; mB = 0; mC = 0; mD = 0; mE = 0;
            end else if (en) begin
                mA = nxt(mA, ve, 1, 160, 96, 128);
                mB = nxt(mB, vr, 1, 160, 96, 128);
                mC = nxt(mC, ve, 0, 160, 96, 128);
                mD = nxt(mD, vr, 0, 160, 96, 128);
                mE = nxt(mE, ve, 1, 200, 50, 128);
            end else begin
                en_hold_cycles = en_hold_cycles + 1;
            end
            compare;
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            cyc(1'b1, 8'd255, 8'd255);       // big values during reset must be ignored
            rst_n = 1'b1;
        end
    endtask

    // drive both value inputs to the same v
    task cv;
        input [7:0] v;
        begin
            cyc(1'b1, v, v);
        end
    endtask

    integer s, v, k, i;
    integer toggles_A, toggles_B, toggles_C, toggles_D;
    reg pA, pB, pC, pD;
    integer seed, r;
    reg [7:0] re, rr;
    reg ren;

    initial begin
        errors = 0; cycles = 0; en_hold_cycles = 0; band_hold_cycles = 0;
        mA = 0; mB = 0; mC = 0; mD = 0; mE = 0;
        seed = 32'h5EED1234;
        rst_n = 1'b0; enable = 1'b1; v_ewma = 8'd0; v_raw = 8'd0; active_mode = 1'b0;
        do_reset;

        // ---- T1: reset state is XY, no change request while active mode is XY ----
        if (reqA !== 1'b0 || reqB !== 1'b0 || reqC !== 1'b0 || reqD !== 1'b0 || reqE !== 1'b0)
            fail("T1 reset request must be XY");
        if (mcrA !== 1'b0) fail("T1 mode_change_request must be 0 at reset");

        // ---- T2: HYSTERoC (A) hard-coded edge cases, 160 / 96 ----
        cv(8'd0);
        cv(8'd159);  if (reqA !== 1'b0) fail("T2 159 must stay XY");
        cv(8'd160);  if (reqA !== 1'b1) fail("T2 160 (== THIGH) must request ADAPT");
        cv(8'd159);  if (reqA !== 1'b1) fail("T2 159 in band must hold ADAPT");
        cv(8'd130);  if (reqA !== 1'b1) fail("T2 130 in band must hold ADAPT");
        cv(8'd97);   if (reqA !== 1'b1) fail("T2 97 (TLOW+1) must hold ADAPT");
        cv(8'd96);   if (reqA !== 1'b0) fail("T2 96 (== TLOW) must request XY");
        cv(8'd97);   if (reqA !== 1'b0) fail("T2 97 in band must hold XY");
        cv(8'd130);  if (reqA !== 1'b0) fail("T2 130 in band must hold XY");
        cv(8'd255);  if (reqA !== 1'b1) fail("T2 255 must request ADAPT");
        cv(8'd96);   if (reqA !== 1'b0) fail("T2 returning via TLOW");

        // ---- T3: single threshold (D) hard-coded: 127 -> XY, 128 -> ADAPT, no memory ----
        do_reset;
        cv(8'd127);  if (reqD !== 1'b0) fail("T3 127 must be XY");
        cv(8'd128);  if (reqD !== 1'b1) fail("T3 128 (== threshold) must be ADAPT");
        cv(8'd127);  if (reqD !== 1'b0) fail("T3 single threshold has no memory: 127 returns to XY");

        // ---- T4: input source selection: A uses EWMA, B uses raw ----
        do_reset;
        cyc(1'b1, 8'd200, 8'd0);
        if (reqA !== 1'b1) fail("T4 A must follow value_ewma (200 -> ADAPT)");
        if (reqB !== 1'b0) fail("T4 B must ignore value_ewma and follow value_raw");
        cyc(1'b1, 8'd0, 8'd200);
        if (reqB !== 1'b1) fail("T4 B must follow value_raw (200 -> ADAPT)");
        do_reset;
        cyc(1'b1, 8'd200, 8'd0);       // A,C -> ADAPT ; B,D -> XY
        cyc(1'b1, 8'd0, 8'd200);       // A back to XY (0<=96), C XY (0<128); B,D ADAPT
        if (reqA !== 1'b0 || reqC !== 1'b0) fail("T4b EWMA-fed DUTs must follow value_ewma=0 -> XY");
        if (reqB !== 1'b1 || reqD !== 1'b1) fail("T4b raw-fed DUTs must follow value_raw=200 -> ADAPT");

        // ---- T5: configurability (E: 200/50) ----
        do_reset;
        cv(8'd199);  if (reqE !== 1'b0) fail("T5 E 199 must stay XY");
        cv(8'd200);  if (reqE !== 1'b1) fail("T5 E 200 must request ADAPT");
        cv(8'd51);   if (reqE !== 1'b1) fail("T5 E 51 must hold");
        cv(8'd50);   if (reqE !== 1'b0) fail("T5 E 50 must request XY");

        // ---- T6: mode_change_request follows (req_mode != active_mode) ----
        do_reset;
        cv(8'd255);                          // req ADAPT (A)
        if (mcrA !== 1'b1) fail("T6 req ADAPT while active XY must raise mode_change_request");
        active_mode = 1'b1; #1;
        if (mcrA !== 1'b0) fail("T6 mode_change_request must drop when active_mode catches up");
        cv(8'd0);                            // A req XY while active ADAPT
        if (mcrA !== 1'b1) fail("T6 req XY while active ADAPT must raise mode_change_request");
        active_mode = 1'b0; #1;
        if (mcrA !== 1'b0) fail("T6 mode_change_request must drop (active XY, req XY)");
        // mode_change_request must not by itself alter req_mode
        for (k = 0; k < 5; k = k + 1) begin active_mode = ~active_mode; cv(8'd130); end
        active_mode = 1'b0;

        // ---- T7: enable = 0 holds req_mode whatever the value ----
        do_reset;
        cv(8'd255);                          // A -> ADAPT
        for (k = 0; k < 10; k = k + 1) cyc(1'b0, 8'd0, 8'd0);
        if (reqA !== 1'b1) fail("T7 enable=0 must hold ADAPT even with value 0");
        cv(8'd0);                            // enable again: now it may go XY
        if (reqA !== 1'b0) fail("T7 after enable, value 0 must request XY");
        for (k = 0; k < 10; k = k + 1) cyc(1'b0, 8'd255, 8'd255);
        if (reqA !== 1'b0) fail("T7 enable=0 must hold XY even with value 255");

        // ---- T8: EXHAUSTIVE: every start state x every value, for all five DUTs ----
        for (s = 0; s < 2; s = s + 1)
            for (v = 0; v < 256; v = v + 1) begin
                do_reset;
                if (s == 1) cv(8'd255);      // 255 puts every DUT into ADAPT (255 >= 200 for E too)
                if (s == 1 && (reqA !== 1'b1 || reqB !== 1'b1 || reqC !== 1'b1 || reqD !== 1'b1 || reqE !== 1'b1))
                    fail("T8 setup: could not reach ADAPT start state");
                cv(v[7:0]);                  // compare() checks all five against the model
            end

        // ---- T9: oscillation demo: values alternating 120 / 136 around the single threshold 128 ----
        do_reset;
        toggles_A = 0; toggles_B = 0; toggles_C = 0; toggles_D = 0;
        pA = reqA; pB = reqB; pC = reqC; pD = reqD;
        for (k = 0; k < 200; k = k + 1) begin
            if (k % 2 == 0) cv(8'd120); else cv(8'd136);
            if (reqA !== pA) toggles_A = toggles_A + 1;
            if (reqB !== pB) toggles_B = toggles_B + 1;
            if (reqC !== pC) toggles_C = toggles_C + 1;
            if (reqD !== pD) toggles_D = toggles_D + 1;
            pA = reqA; pB = reqB; pC = reqC; pD = reqD;
        end
        $display("INFO: oscillation 120/136 for 200 cycles -> request changes: HYSTERoC(A)=%0d dual-raw(B)=%0d single-EWMA(C)=%0d single-raw(D)=%0d",
                 toggles_A, toggles_B, toggles_C, toggles_D);
        if (toggles_A !== 0 || toggles_B !== 0) fail("T9 dual-threshold must not change inside its band");
        if (toggles_C < 190 || toggles_D < 190) fail("T9 single threshold should flip almost every cycle");

        // ---- T10: long random run (independent ewma/raw values, random enable, rare resets) ----
        for (k = 0; k < 300000; k = k + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            case (r % 5)
                0: re = 8'd0;
                1: re = 8'd255;
                2: re = 8'd96 + (r % 3);        // around TLOW
                3: re = 8'd159 + (r % 3);       // around THIGH
                default: re = $random(seed);
            endcase
            r = $random(seed); if (r < 0) r = -r;
            case (r % 4)
                0: rr = 8'd127 + (r % 3);       // around single threshold
                1: rr = re;
                default: rr = $random(seed);
            endcase
            r = $random(seed); if (r < 0) r = -r;
            ren = ((r % 100) < 85);
            r = $random(seed); if (r < 0) r = -r;
            if ((r % 9000) == 0) do_reset;
            else begin
                if ((r % 50) == 1) active_mode = ~active_mode;
                cyc(ren, re, rr);
            end
        end

        $display("INFO: cycles=%0d enable_hold_cycles=%0d", cycles, en_hold_cycles);
        if (en_hold_cycles < 1000) begin errors = errors + 1; $display("ERROR: enable hold not exercised enough"); end
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
