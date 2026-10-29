// =============================================================================
// tb_drain_detector.v : self-checking testbench for drain_detector
// Checks: every single status bit (all 48 for N=16) blocks drained_now when it
// is the only "busy" bit; confirm window exactly CONFIRM cycles for CONFIRM in
// {1,2,3}; network_drained falls in the same cycle as any activity; random
// vectors against a counting model.
// =============================================================================
`timescale 1ns/1ps
module tb_drain_detector;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg [15:0] re, se, la;
    wire dn1, nd1, dn2, nd2, dn3, nd3;

    drain_detector #(.N(16), .CONFIRM(1)) d1 (.clk(clk), .rst_n(rst_n), .router_empty(re), .src_empty(se), .link_active(la), .drained_now(dn1), .network_drained(nd1));
    drain_detector #(.N(16), .CONFIRM(2)) d2 (.clk(clk), .rst_n(rst_n), .router_empty(re), .src_empty(se), .link_active(la), .drained_now(dn2), .network_drained(nd2));
    drain_detector #(.N(16), .CONFIRM(3)) d3 (.clk(clk), .rst_n(rst_n), .router_empty(re), .src_empty(se), .link_active(la), .drained_now(dn3), .network_drained(nd3));

    integer errors, i, n, seed, r;
    integer quiet_m;        // model: consecutive quiet cycles including this one
    reg     now_m;

    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors < 15) $display("ERROR @%0t: %0s", $time, msg); end
    endtask

    // one cycle with a given vector; checks comb outputs then clocks
    task cyc;
        input [15:0] a, b, c;
        begin
            re = a; se = b; la = c;
            #1;
            now_m = (a == 16'hFFFF) && (b == 16'hFFFF) && (c == 16'h0000);
            quiet_m = now_m ? quiet_m + 1 : 0;
            if (dn1 !== now_m || dn2 !== now_m || dn3 !== now_m) fail("drained_now");
            if (nd1 !== (now_m && quiet_m >= 1)) fail("network_drained CONFIRM=1");
            if (nd2 !== (now_m && quiet_m >= 2)) fail("network_drained CONFIRM=2");
            if (nd3 !== (now_m && quiet_m >= 3)) fail("network_drained CONFIRM=3");
            @(posedge clk); #1;
        end
    endtask

    initial begin
        errors = 0; seed = 7; quiet_m = 0;
        re = 16'hFFFF; se = 16'hFFFF; la = 16'h0000; rst_n = 1'b0;
        repeat (3) @(posedge clk); #1; rst_n = 1'b1;

        // quiet window
        for (i = 0; i < 6; i = i + 1) cyc(16'hFFFF, 16'hFFFF, 16'h0000);
        // each bit alone
        for (i = 0; i < 16; i = i + 1) begin
            cyc(16'hFFFF & ~(16'h1 << i), 16'hFFFF, 16'h0000);       // router i busy
            cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000);
            cyc(16'hFFFF, 16'hFFFF & ~(16'h1 << i), 16'h0000);       // source i busy
            cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000);
            cyc(16'hFFFF, 16'hFFFF, 16'h1 << i);                     // link i active
            cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000);
        end
        // single-cycle blips between quiet cycles reset the window
        for (n = 0; n < 5; n = n + 1) begin
            cyc(16'hFFFF, 16'hFFFF, 16'h0000);
            cyc(16'hFFFF, 16'hFFFF, 16'h0000);
            cyc(16'hFFFF ^ 16'h0100, 16'hFFFF, 16'h0000);
        end
        // random vectors, biased to mostly-quiet
        for (n = 0; n < 60000; n = n + 1) begin
            r = $random(seed); if (r < 0) r = -r;
            if (r % 10 < 8) cyc(16'hFFFF, 16'hFFFF, 16'h0000);
            else begin
                r = $random(seed);
                cyc(16'hFFFF & ~(16'h1 << (r & 15)) | (r[20] ? 16'h0 : 16'hFFFF),
                    r[21] ? 16'hFFFF : (16'hFFFF & ~(16'h1 << ((r >> 4) & 15))),
                    r[22] ? 16'h0000 : (16'h1 << ((r >> 8) & 15)));
            end
        end
        // reset clears the window
        cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000); cyc(16'hFFFF, 16'hFFFF, 16'h0000);
        rst_n = 1'b0; @(posedge clk); #1; rst_n = 1'b1; quiet_m = 0;
        cyc(16'hFFFF, 16'hFFFF, 16'h0000);
        cyc(16'hFFFF, 16'hFFFF, 16'h0000);

        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
