// =============================================================================
// tb_route_compute.v : exhaustive self-checking testbench for route_compute
//
// All 4 x 4 x 4 x 4 x 4 = 1024 combinations of (x, y, src_x, dst_x, dst_y).
// 1. Equality with an independent model written in the literal e0/e1 style of
//    Chiu's pseudocode (integers, if/else), for both xy_port and oe_cand.
// 2. Properties that do not depend on the model: oe_cand never empty; Local
//    only at the destination (and then alone); every candidate in bounds and
//    reducing the distance by exactly 1; xy_port one-hot and X-first; XY is
//    NOT always a member of the Odd-Even set (counted, must be > 0).
// 3. Hard-coded directed cases taken from the spec v5 table.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_route_compute;

    reg  [1:0] x, y, dst_x, dst_y, src_x;
    wire [4:0] xy_port, oe_cand;

    route_compute dut (.x(x), .y(y), .dst_x(dst_x), .dst_y(dst_y), .src_x(src_x),
                       .xy_port(xy_port), .oe_cand(oe_cand));

    integer errors;
    integer checked;
    integer xy_not_in_oe;
    integer multi_cand;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR: %0s | x=%0d y=%0d src_x=%0d dst=(%0d,%0d) -> xy=%b oe=%b",
                         msg, x, y, src_x, dst_x, dst_y, xy_port, oe_cand);
        end
    endtask

    // independent model, literal Chiu-style
    function [4:0] model_oe;
        input integer cx, cy, sx, dx, dy;
        integer e0, e1;
        reg [4:0] m;
        reg [4:0] vert;
        begin
            e0 = dx - cx;
            e1 = dy - cy;
            vert = (e1 > 0) ? `HY_PM_S : `HY_PM_N;
            m = 5'b00000;
            if (e0 == 0 && e1 == 0) begin
                m = `HY_PM_L;
            end else if (e0 == 0) begin
                m = vert;
            end else if (e0 > 0) begin
                if (e1 == 0) begin
                    m = `HY_PM_E;
                end else begin
                    if ((cx % 2) == 1 || cx == sx) m = m | vert;
                    if ((dx % 2) == 1 || e0 != 1)  m = m | `HY_PM_E;
                end
            end else begin
                m = `HY_PM_W;
                if (e1 != 0 && (cx % 2) == 0) m = m | vert;
            end
            model_oe = m;
        end
    endfunction

    function [4:0] model_xy;
        input integer cx, cy, dx, dy;
        begin
            if (dx > cx)      model_xy = `HY_PM_E;
            else if (dx < cx) model_xy = `HY_PM_W;
            else if (dy > cy) model_xy = `HY_PM_S;
            else if (dy < cy) model_xy = `HY_PM_N;
            else              model_xy = `HY_PM_L;
        end
    endfunction

    function integer popc;
        input [4:0] v;
        integer j;
        begin
            popc = 0;
            for (j = 0; j < 5; j = j + 1) if (v[j]) popc = popc + 1;
        end
    endfunction

    function integer dist;
        input integer ax, ay, bx, by;
        begin
            dist = ((ax > bx) ? (ax - bx) : (bx - ax)) + ((ay > by) ? (ay - by) : (by - ay));
        end
    endfunction

    // check a mask of candidate outputs for in-bounds + progress
    task check_progress;
        input [4:0] m;
        input [255:0] who;
        integer nx, ny;
        integer d0;
        begin
            d0 = dist(x, y, dst_x, dst_y);
            if (m[0]) begin nx = x;     ny = y - 1; if (ny < 0 || dist(nx, ny, dst_x, dst_y) != d0 - 1) fail(who); end
            if (m[1]) begin nx = x;     ny = y + 1; if (ny > 3 || dist(nx, ny, dst_x, dst_y) != d0 - 1) fail(who); end
            if (m[2]) begin nx = x + 1; ny = y;     if (nx > 3 || dist(nx, ny, dst_x, dst_y) != d0 - 1) fail(who); end
            if (m[3]) begin nx = x - 1; ny = y;     if (nx < 0 || dist(nx, ny, dst_x, dst_y) != d0 - 1) fail(who); end
        end
    endtask

    task expect_case;
        input integer cx, cy, sx, dx, dy;
        input [4:0] exp_xy;
        input [4:0] exp_oe;
        begin
            x = cx; y = cy; src_x = sx; dst_x = dx; dst_y = dy;
            #1;
            checked = checked + 1;
            if (xy_port !== exp_xy) fail("directed: xy_port");
            if (oe_cand !== exp_oe) fail("directed: oe_cand");
        end
    endtask

    integer ix, iy, isx, idx, idy;
    reg [4:0] mo, mx;

    initial begin
        errors = 0; checked = 0; xy_not_in_oe = 0; multi_cand = 0;

        // ---- D: directed cases from the spec v5 table ----
        //            x y sx dx dy   xy             oe
        expect_case(1,0,0, 3,3, `HY_PM_E, `HY_PM_S | `HY_PM_E);   // x odd: vertical ok; dst odd: East ok
        expect_case(0,0,0, 3,3, `HY_PM_E, `HY_PM_S | `HY_PM_E);   // x == src_x: vertical ok
        expect_case(2,0,0, 3,3, `HY_PM_E, `HY_PM_E);              // x even, not src: no vertical
        expect_case(1,0,0, 2,2, `HY_PM_E, `HY_PM_S);              // ex==1, dst even: no East; vertical ok
        expect_case(2,1,3, 0,3, `HY_PM_W, `HY_PM_W | `HY_PM_S);   // westbound, x even: vertical too
        expect_case(3,1,3, 0,3, `HY_PM_W, `HY_PM_W);              // westbound, x odd: West only
        expect_case(1,3,1, 1,0, `HY_PM_N, `HY_PM_N);              // same column: vertical only
        expect_case(2,2,2, 2,2, `HY_PM_L, `HY_PM_L);              // at destination
        expect_case(2,2,2, 3,2, `HY_PM_E, `HY_PM_E);              // ey==0: East only
        expect_case(2,0,2, 3,2, `HY_PM_E, `HY_PM_S | `HY_PM_E);   // x even but == src_x: vertical ok
        expect_case(2,2,0, 3,0, `HY_PM_E, `HY_PM_E);              // north-east, x even not src: East only
        expect_case(1,0,0, 2,0, `HY_PM_E, `HY_PM_E);              // ey==0, ex==1, dst even: still East
        expect_case(3,3,0, 0,0, `HY_PM_W, `HY_PM_W);              // westbound, x odd, ey<0: West only
        expect_case(0,3,0, 0,0, `HY_PM_N, `HY_PM_N);              // same column north

        // ---- E: exhaustive 1024 inputs ----
        for (ix = 0; ix < 4; ix = ix + 1)
         for (iy = 0; iy < 4; iy = iy + 1)
          for (isx = 0; isx < 4; isx = isx + 1)
           for (idx = 0; idx < 4; idx = idx + 1)
            for (idy = 0; idy < 4; idy = idy + 1) begin
                x = ix; y = iy; src_x = isx; dst_x = idx; dst_y = idy;
                #1;
                checked = checked + 1;
                mo = model_oe(ix, iy, isx, idx, idy);
                mx = model_xy(ix, iy, idx, idy);
                if (oe_cand  !== mo) fail("oe_cand differs from the independent model");
                if (xy_port  !== mx) fail("xy_port differs from the independent model");

                // properties
                if (oe_cand == 5'b0)                         fail("oe_cand empty");
                if (popc(xy_port) != 1)                      fail("xy_port not one-hot");
                if (oe_cand[4] && oe_cand != `HY_PM_L)       fail("Local mixed with other outputs");
                if (xy_port[4] && xy_port != `HY_PM_L)       fail("XY Local mixed with other outputs");
                if (oe_cand[4] != (ix == idx && iy == idy))  fail("Local only at the destination");
                if (xy_port[4] != (ix == idx && iy == idy))  fail("XY Local only at the destination");
                check_progress(oe_cand & 5'b01111, "oe candidate out of bounds / no progress");
                check_progress(xy_port & 5'b01111, "xy output out of bounds / no progress");
                if (idx != ix && xy_port[0] | xy_port[1])    fail("XY not X-first");
                if (popc(oe_cand) > 1) multi_cand = multi_cand + 1;
                if ((xy_port & oe_cand) == 5'b0)             xy_not_in_oe = xy_not_in_oe + 1;
            end

        $display("INFO: cases checked=%0d (14 directed + 1024 exhaustive); inputs with 2 OE candidates=%0d; inputs where XY output is NOT an Odd-Even candidate=%0d",
                 checked, multi_cand, xy_not_in_oe);
        if (xy_not_in_oe == 0) begin errors = errors + 1; $display("ERROR: expected XY not to be a subset of Odd-Even"); end
        if (multi_cand   == 0) begin errors = errors + 1; $display("ERROR: no adaptive (two-candidate) case seen"); end
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
