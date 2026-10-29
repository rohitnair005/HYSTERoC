// =============================================================================
// tb_round_robin_arbiter.v : self-checking testbench (Verilog-2001)
//
// Two DUTs on the same stimulus: N = 5 (IDX_W = 3, the router size) and N = 3
// (IDX_W = 2, checks the parameterisation). Both are compared every cycle with
// an independent model. Hard-coded cases cover reset priority, round-robin
// order, stalled transfers (pointer must not move), pointer wrap, and
// advance-without-grant. An exhaustive sweep covers every pointer value x every
// request mask. Fairness: constant request sets are served equally; random
// traffic is checked for a bounded waiting time (<= N-1 other grants).
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps

module tb_round_robin_arbiter;

    reg         clk;
    reg         rst_n;
    reg  [4:0]  req5;
    reg         advance;

    wire [4:0]  g5;   wire [2:0] gi5;  wire any5;
    wire [2:0]  g3;   wire [1:0] gi3;  wire any3;

    round_robin_arbiter #(.N(5), .IDX_W(3)) d5 (
        .clk(clk), .rst_n(rst_n), .req(req5), .advance(advance),
        .grant(g5), .grant_idx(gi5), .any_grant(any5));
    round_robin_arbiter #(.N(3), .IDX_W(2)) d3 (
        .clk(clk), .rst_n(rst_n), .req(req5[2:0]), .advance(advance),
        .grant(g3), .grant_idx(gi3), .any_grant(any3));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- independent model ----------------
    integer p5, p3;                      // model pointers
    integer errors;
    integer cycles;
    integer adv_with_grant;
    integer adv_without_grant;
    integer stalled_cycles;

    // expected grant mask for request mask `rq`, pointer `p`, size `n`
    function [4:0] mgrant;
        input [4:0]   rq;
        input integer p;
        input integer n;
        integer j, id;
        reg     done;
        begin
            mgrant = 5'b00000;
            done   = 1'b0;
            for (j = 0; j < n; j = j + 1) begin
                id = (p + j) % n;
                if (!done && rq[id]) begin
                    mgrant[id] = 1'b1;
                    done = 1'b1;
                end
            end
        end
    endfunction

    function integer midx;
        input [4:0] gm;
        input integer n;
        integer j;
        begin
            midx = 0;
            for (j = 0; j < n; j = j + 1)
                if (gm[j]) midx = j;
        end
    endfunction

    function integer popcount;
        input [4:0] v;
        integer j;
        begin
            popcount = 0;
            for (j = 0; j < 5; j = j + 1) if (v[j]) popcount = popcount + 1;
        end
    endfunction

    reg [4:0] e5;
    reg [4:0] e3;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | req=%b adv=%b | p5=%0d g5=%b idx5=%0d | p3=%0d g3=%b idx3=%0d",
                         $time, msg, req5, advance, p5, g5, gi5, p3, g3, gi3);
        end
    endtask

    // check combinational outputs for the current inputs (pre-edge)
    task check_now;
        begin
            e5 = mgrant(req5, p5, 5);
            e3 = mgrant({2'b00, req5[2:0]}, p3, 3);
            if (g5 !== e5)                                    fail("N=5 grant mismatch");
            if (g3 !== e3[2:0])                               fail("N=3 grant mismatch");
            if (gi5 !== midx(e5, 5)) fail("N=5 grant_idx mismatch");
            if (gi3 !== midx(e3, 3)) fail("N=3 grant_idx mismatch");
            if (any5 !== (req5 != 5'b0))                      fail("N=5 any_grant mismatch");
            if (any3 !== (req5[2:0] != 3'b0))                 fail("N=3 any_grant mismatch");
            // structural properties, independent of the model
            if ((g5 & ~req5) != 5'b0)                         fail("N=5 granted a non-requester");
            if ((g5 & (g5 - 5'b1)) != 5'b0)                   fail("N=5 more than one grant");
            if ((g3 & ~req5[2:0]) != 3'b0)                    fail("N=3 granted a non-requester");
            if ((g3 & (g3 - 3'b1)) != 3'b0)                   fail("N=3 more than one grant");
        end
    endtask

    // one clock cycle: drive, check pre-edge outputs, clock, update model pointers
    task cyc;
        input [4:0] rq;
        input       adv;
        begin
            req5 = rq; advance = adv;
            #1;
            check_now;
            if (adv && rq != 5'b0)        adv_with_grant = adv_with_grant + 1;
            if (adv && rq == 5'b0)        adv_without_grant = adv_without_grant + 1;
            if (!adv && rq != 5'b0)       stalled_cycles = stalled_cycles + 1;
            @(posedge clk);
            #1;
            if (!rst_n) begin
                p5 = 0; p3 = 0;
            end else begin
                if (adv && (e5 != 5'b0)) p5 = (midx(e5, 5) + 1) % 5;
                if (adv && (e3[2:0] != 3'b0)) p3 = (midx(e3, 3) + 1) % 3;
            end
        end
    endtask

    // Reset without checking outputs: before the first reset edge the pointer is
    // unknown (X), so grant is legitimately undefined. Requests and advance are
    // driven during reset and must be ignored.
    task do_reset;
        begin
            rst_n = 1'b0;
            req5 = 5'b11111; advance = 1'b1;
            @(posedge clk);
            #1;
            p5 = 0; p3 = 0;
            rst_n = 1'b1;
            req5 = 5'b00000; advance = 1'b0;
        end
    endtask

    integer s, p, rq, k, m, i, seed, r;
    integer cnt [0:4];
    integer wait_n [0:4];
    reg [4:0] rr;
    reg       ra;

    initial begin
        errors = 0; cycles = 0; adv_with_grant = 0; adv_without_grant = 0; stalled_cycles = 0;
        p5 = 0; p3 = 0; seed = 32'h0A11CE55;
        rst_n = 1'b0; req5 = 5'b0; advance = 1'b0;
        do_reset;

        // ---- T1: after reset the pointer is 0: input 0 has top priority ----
        cyc(5'b11111, 1'b0);
        if (g5 !== 5'b00001 || gi5 !== 3'd0) fail("T1 reset priority must be input 0");

        // ---- T2: all request, advance every cycle -> strict order 0,1,2,3,4,0,1 ----
        do_reset;
        for (k = 0; k < 11; k = k + 1) begin
            req5 = 5'b11111; advance = 1'b1; #1;
            if (gi5 !== (k % 5)) fail("T2 round-robin order broken");
            if (g5 !== (5'b00001 << (k % 5))) fail("T2 one-hot order broken");
            cyc(5'b11111, 1'b1);
        end

        // ---- T3: stalled transfer: pointer must not move (same grant while advance = 0) ----
        do_reset;
        for (k = 0; k < 12; k = k + 1) begin
            cyc(5'b11111, 1'b0);
            if (gi5 !== 3'd0) fail("T3 grant moved without an accepted transfer");
        end
        cyc(5'b11111, 1'b1);                       // transfer accepted: input 0 served
        cyc(5'b11111, 1'b0);
        if (gi5 !== 3'd1) fail("T3 after accepted transfer the next input must win");
        // stalled + a higher-priority-in-order request arrives: pointer still 1, so 1 keeps priority over 0
        cyc(5'b00011, 1'b0);
        if (gi5 !== 3'd1) fail("T3 pointer-priority must stay with 1");

        // ---- T4: single requester i is granted and the pointer moves to i+1 ----
        for (i = 0; i < 5; i = i + 1) begin
            do_reset;
            cyc(5'b00001 << i, 1'b1);               // grant i, advance -> ptr = i+1
            cyc(5'b11111, 1'b0);
            if (gi5 !== ((i + 1) % 5)) fail("T4 pointer must move to granted index + 1");
        end

        // ---- T5: wrap: serving input 4 returns priority to input 0 ----
        do_reset;
        cyc(5'b10000, 1'b1);
        cyc(5'b11111, 1'b0);
        if (gi5 !== 3'd0) fail("T5 pointer must wrap to 0 after serving input 4");

        // ---- T6: advance with no request does not move the pointer ----
        do_reset;
        for (k = 0; k < 6; k = k + 1) cyc(5'b00000, 1'b1);
        cyc(5'b11111, 1'b0);
        if (gi5 !== 3'd0) fail("T6 advance without a grant moved the pointer");

        // ---- T7: EXHAUSTIVE: every pointer value x every request mask, then pointer update checked ----
        for (p = 0; p < 5; p = p + 1)
            for (rq = 0; rq < 32; rq = rq + 1) begin
                do_reset;
                if (p > 0) cyc(5'b00001 << (p - 1), 1'b1);   // sets ptr = p (N=5); N=3 ptr follows model
                cyc(rq[4:0], 1'b0);                          // grant check, no advance
                cyc(rq[4:0], 1'b1);                          // grant check, advance
                cyc(5'b11111, 1'b0);                         // exposes the updated pointer
            end

        // ---- T8: fairness: constant request set, advance every cycle, equal service ----
        for (m = 1; m < 32; m = m + 1) begin
            do_reset;
            for (i = 0; i < 5; i = i + 1) cnt[i] = 0;
            for (k = 0; k < 4 * popcount(m[4:0]) ; k = k + 1) begin
                req5 = m[4:0]; advance = 1'b1; #1;
                for (i = 0; i < 5; i = i + 1) if (g5[i]) cnt[i] = cnt[i] + 1;
                cyc(m[4:0], 1'b1);
            end
            for (i = 0; i < 5; i = i + 1)
                if (m[i] && cnt[i] != 4) fail("T8 requester not served equally");
                else if (!m[i] && cnt[i] != 0) fail("T8 non-requester served");
        end

        // ---- T9: random traffic vs model, plus bounded waiting (<= N-1 other grants) ----
        for (i = 0; i < 5; i = i + 1) wait_n[i] = 0;
        for (k = 0; k < 200000; k = k + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            case (r % 4)
                0: rr = 5'b11111;
                1: rr = 5'b10101;
                default: begin rr = $random(seed); end
            endcase
            r = $random(seed); if (r < 0) r = -r;
            ra = ((r % 100) < 70);
            r = $random(seed); if (r < 0) r = -r;
            if ((r % 20000) == 0) begin
                do_reset;
                for (i = 0; i < 5; i = i + 1) wait_n[i] = 0;
            end else begin
                req5 = rr; advance = ra; #1;
                // update waiting counters for the N=5 arbiter (advance only counts when a grant is accepted)
                for (i = 0; i < 5; i = i + 1) begin
                    if (!rr[i]) wait_n[i] = 0;
                    else if (ra && !g5[i]) begin
                        wait_n[i] = wait_n[i] + 1;
                        if (wait_n[i] > 4) fail("T9 requester waited more than N-1 other grants (starvation)");
                    end else if (ra && g5[i]) wait_n[i] = 0;
                end
                cyc(rr, ra);
            end
        end

        $display("INFO: advance_with_grant=%0d advance_without_grant=%0d stalled_cycles=%0d",
                 adv_with_grant, adv_without_grant, stalled_cycles);
        if (adv_with_grant < 1000 || adv_without_grant < 10 || stalled_cycles < 1000)
            begin errors = errors + 1; $display("ERROR: stimulus coverage too low"); end

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
