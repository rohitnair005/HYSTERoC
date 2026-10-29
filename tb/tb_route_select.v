// =============================================================================
// tb_route_select.v : self-checking testbench for route_select (Verilog-2001)
//
// 1. Directed cases with hard-coded expected outputs: XY ignores occupancy and
//    candidates, every tie-break pair (E>S>W>N), lowest-occupancy choice,
//    unavailable-direction skipping, Local priority, no-candidate cases.
// 2. Exhaustive adaptive: every candidate mask (32) x every occupancy tuple
//    0..4 on N,S,E,W (625) x every availability pattern (16) = 320,000 cases,
//    against an independent model that finds the minimum first and then picks
//    the first port in order E,S,W,N holding it.
// 3. Exhaustive XY: every xy_port mask (32) x availability (16) x 9 candidate/
//    occupancy backgrounds.
// 4. Chain test with the real route_compute: all 1024 (x, y, src_x, dst_x,
//    dst_y) inputs x both modes x 6 random occupancy tuples, with the
//    availability of the real router position. A selection must always exist,
//    be one-hot, stay in the mesh and reduce the distance by exactly 1.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_route_select;

    // ---------------- DUT 1: direct stimulus ----------------
    reg         mode;
    reg  [4:0]  xy_port, oe_cand;
    reg  [2:0]  occ_n, occ_s, occ_e, occ_w;
    reg         av_n, av_s, av_e, av_w;
    wire [4:0]  sel_port;
    wire        sel_valid;

    route_select dut (
        .active_mode(mode), .xy_port(xy_port), .oe_cand(oe_cand),
        .occ_n(occ_n), .occ_s(occ_s), .occ_e(occ_e), .occ_w(occ_w),
        .avail_n(av_n), .avail_s(av_s), .avail_e(av_e), .avail_w(av_w),
        .sel_port(sel_port), .sel_valid(sel_valid));

    // ---------------- DUT 2: route_compute -> route_select chain ----------------
    reg  [1:0]  cx, cy, cdx, cdy, csx;
    reg         cmode;
    reg  [2:0]  c_on, c_os, c_oe, c_ow;
    wire [4:0]  c_xy, c_oe_cand, c_sel;
    wire        c_valid;
    wire        c_an = (cy != 2'd0);          // North exists unless y == 0
    wire        c_as = (cy != 2'd3);          // South exists unless y == 3
    wire        c_aw = (cx != 2'd0);          // West  exists unless x == 0
    wire        c_ae = (cx != 2'd3);          // East  exists unless x == 3

    route_compute rc (.x(cx), .y(cy), .dst_x(cdx), .dst_y(cdy), .src_x(csx),
                      .xy_port(c_xy), .oe_cand(c_oe_cand));
    route_select  rs (
        .active_mode(cmode), .xy_port(c_xy), .oe_cand(c_oe_cand),
        .occ_n(c_on), .occ_s(c_os), .occ_e(c_oe), .occ_w(c_ow),
        .avail_n(c_an), .avail_s(c_as), .avail_e(c_ae), .avail_w(c_aw),
        .sel_port(c_sel), .sel_valid(c_valid));

    integer errors;
    integer checked;
    integer tie_decisions;        // two eligible candidates with equal occupancy
    integer lower_decisions;      // two eligible candidates with different occupancy
    integer skipped_unavail;      // a candidate was dropped because its direction is unavailable
    integer local_cases;

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | mode=%b xy=%b cand=%b occ N%0d S%0d E%0d W%0d av(nsew)=%b%b%b%b -> sel=%b valid=%b",
                         $time, msg, mode, xy_port, oe_cand, occ_n, occ_s, occ_e, occ_w,
                         av_n, av_s, av_e, av_w, sel_port, sel_valid);
        end
    endtask

    // independent model: minimum first, then first holder in order E, S, W, N
    function [4:0] model_sel;
        input        m;
        input [4:0]  xy;
        input [4:0]  cand;
        input integer on_, os_, oe_, ow_;
        input [3:0]  av;                  // {west, east, south, north}
        reg [4:0] am;
        reg [4:0] el;
        integer   mn;
        begin
            am = {1'b1, av};              // bit4 Local always available
            if (!m) begin
                model_sel = xy & am;
            end else begin
                el = cand & am;
                if (el[4]) begin
                    model_sel = 5'b10000;
                end else begin
                    mn = 99;
                    if (el[2] && oe_ < mn) mn = oe_;
                    if (el[1] && os_ < mn) mn = os_;
                    if (el[3] && ow_ < mn) mn = ow_;
                    if (el[0] && on_ < mn) mn = on_;
                    model_sel = 5'b00000;
                    if (mn != 99) begin
                        if      (el[2] && oe_ == mn) model_sel = 5'b00100;
                        else if (el[1] && os_ == mn) model_sel = 5'b00010;
                        else if (el[3] && ow_ == mn) model_sel = 5'b01000;
                        else if (el[0] && on_ == mn) model_sel = 5'b00001;
                    end
                end
            end
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

    task apply;
        input        m;
        input [4:0]  xy;
        input [4:0]  cand;
        input integer on_, os_, oe_, ow_;
        input [3:0]  av;
        begin
            mode = m; xy_port = xy; oe_cand = cand;
            occ_n = on_; occ_s = os_; occ_e = oe_; occ_w = ow_;
            av_n = av[0]; av_s = av[1]; av_e = av[2]; av_w = av[3];
            #1;
        end
    endtask

    // directed case with a hard-coded expected selection
    task expect_case;
        input        m;
        input [4:0]  xy;
        input [4:0]  cand;
        input integer on_, os_, oe_, ow_;
        input [3:0]  av;
        input [4:0]  exp_sel;
        begin
            apply(m, xy, cand, on_, os_, oe_, ow_, av);
            checked = checked + 1;
            if (sel_port  !== exp_sel)         fail("directed: sel_port");
            if (sel_valid !== (exp_sel != 0))  fail("directed: sel_valid");
        end
    endtask

    // check DUT 1 against the model for the currently applied inputs
    reg [4:0] ms;
    reg [4:0] elig;
    task check_model;
        begin
            ms = model_sel(mode, xy_port, oe_cand, occ_n, occ_s, occ_e, occ_w, {av_w, av_e, av_s, av_n});
            checked = checked + 1;
            if (sel_port  !== ms)                 fail("sel_port differs from the independent model");
            if (sel_valid !== (ms != 5'b0))       fail("sel_valid differs from the independent model");
            // structural properties independent of the model
            // One-hot holds for adaptive mode always, and for XY mode whenever the XY port
            // is one-hot (route_compute guarantees that; the XY sweep also feeds illegal
            // multi-bit masks only to check the pass-through and availability masking).
            if ((mode || popc(xy_port) <= 1) && popc(sel_port) > 1)
                fail("selection is not one-hot");
            if (mode && (sel_port & ~(oe_cand & {1'b1, av_w, av_e, av_s, av_n})) != 5'b0)
                fail("adaptive selection outside available candidates");
            if (!mode && (sel_port & ~(xy_port & {1'b1, av_w, av_e, av_s, av_n})) != 5'b0)
                fail("XY selection outside available XY port");
            // coverage counters (adaptive, no Local)
            if (mode) begin
                elig = oe_cand & {1'b1, av_w, av_e, av_s, av_n};
                if (!elig[4] && popc(elig) >= 2) begin
                    if (popc(oe_cand & ~{1'b1,4'b0}) > popc(elig)) skipped_unavail = skipped_unavail + 1;
                end
                if (elig[4]) local_cases = local_cases + 1;
            end
        end
    endtask

    integer c, on_i, os_i, oe_i, ow_i, a, xp, k, seed, r;
    integer ix, iy, isx, idx, idy, md, t;
    integer d0, d1, nx, ny;
    reg [4:0] xy_exp;

    initial begin
        errors = 0; checked = 0; tie_decisions = 0; lower_decisions = 0;
        skipped_unavail = 0; local_cases = 0;
        seed = 32'h5E1EC7ED;

        // ---- D1: XY mode ignores candidates and occupancy ----
        //          mode xy      cand     n s e w   av(wesn)  expected
        expect_case(0, 5'b00100, 5'b00010, 0,0,0,0, 4'b1111, 5'b00100);   // XY=E although cand=S
        expect_case(0, 5'b00010, 5'b00100, 4,0,4,4, 4'b1111, 5'b00010);   // occupancy ignored
        expect_case(0, 5'b00001, 5'b00001, 0,0,0,0, 4'b1110, 5'b00000);   // XY=N but North unavailable
        expect_case(0, 5'b10000, 5'b00000, 0,0,0,0, 4'b0000, 5'b10000);   // Local always available
        expect_case(0, 5'b00000, 5'b11111, 0,0,0,0, 4'b1111, 5'b00000);   // no XY port -> nothing

        // ---- D2: adaptive, lowest occupancy wins ----
        //          mode xy      cand       n s e w   av       expected
        expect_case(1, 5'b0, 5'b00110, 0,1,3,0, 4'b1111, 5'b00010);   // E(3) vs S(1) -> S
        expect_case(1, 5'b0, 5'b00110, 0,3,1,0, 4'b1111, 5'b00100);   // E(1) vs S(3) -> E
        expect_case(1, 5'b0, 5'b00101, 0,0,3,0, 4'b1111, 5'b00001);   // E(3) vs N(0) -> N
        expect_case(1, 5'b0, 5'b01010, 0,2,0,0, 4'b1111, 5'b01000);   // W(0) vs S(2) -> W
        expect_case(1, 5'b0, 5'b01001, 1,0,0,4, 4'b1111, 5'b00001);   // W(4) vs N(1) -> N

        // ---- D3: tie-break order East, South, West, North ----
        expect_case(1, 5'b0, 5'b00110, 0,2,2,0, 4'b1111, 5'b00100);   // E,S tie -> E
        expect_case(1, 5'b0, 5'b00101, 3,0,3,0, 4'b1111, 5'b00100);   // E,N tie -> E
        expect_case(1, 5'b0, 5'b01010, 0,2,0,2, 4'b1111, 5'b00010);   // W,S tie -> S
        expect_case(1, 5'b0, 5'b01001, 1,0,0,1, 4'b1111, 5'b01000);   // W,N tie -> W
        expect_case(1, 5'b0, 5'b00110, 4,4,4,4, 4'b1111, 5'b00100);   // both full -> E
        expect_case(1, 5'b0, 5'b01111, 1,1,1,1, 4'b1111, 5'b00100);   // all four tie -> E
        expect_case(1, 5'b0, 5'b01111, 0,1,1,1, 4'b1111, 5'b00001);   // N strictly lowest
        expect_case(1, 5'b0, 5'b01111, 1,1,1,0, 4'b1111, 5'b01000);   // W strictly lowest
        expect_case(1, 5'b0, 5'b01110, 4,0,1,1, 4'b1111, 5'b00010);   // S strictly lowest (N not a candidate)

        // ---- D4: single candidate, unavailable directions, Local, empty ----
        expect_case(1, 5'b0, 5'b00010, 0,4,0,0, 4'b1111, 5'b00010);   // single candidate even if full
        expect_case(1, 5'b0, 5'b00110, 0,4,0,0, 4'b1011, 5'b00010);   // E unavailable -> S despite occ 4
        expect_case(1, 5'b0, 5'b00110, 0,0,0,0, 4'b1101, 5'b00100);   // S unavailable -> E
        expect_case(1, 5'b0, 5'b00110, 0,0,0,0, 4'b1001, 5'b00000);   // both unavailable -> none
        expect_case(1, 5'b0, 5'b10000, 4,4,4,4, 4'b0000, 5'b10000);   // Local only
        expect_case(1, 5'b0, 5'b10100, 0,0,0,0, 4'b1111, 5'b10000);   // Local has priority over E
        expect_case(1, 5'b0, 5'b00000, 0,0,0,0, 4'b1111, 5'b00000);   // empty candidate set

        // ---- E1: exhaustive adaptive: 32 x 625 x 16 = 320,000 cases ----
        xy_exp = 5'b11111;                          // must be ignored in adaptive mode
        for (c = 0; c < 32; c = c + 1)
         for (on_i = 0; on_i < 5; on_i = on_i + 1)
          for (os_i = 0; os_i < 5; os_i = os_i + 1)
           for (oe_i = 0; oe_i < 5; oe_i = oe_i + 1)
            for (ow_i = 0; ow_i < 5; ow_i = ow_i + 1)
             for (a = 0; a < 16; a = a + 1) begin
                 apply(1'b1, xy_exp, c[4:0], on_i, os_i, oe_i, ow_i, a[3:0]);
                 check_model;
                 if (!(oe_cand[4]) && popc(oe_cand & {1'b0, a[3:0]}) == 2) begin
                     if (((oe_cand[2] & a[2]) && (oe_cand[1] & a[1]) && oe_i == os_i) ||
                         ((oe_cand[2] & a[2]) && (oe_cand[0] & a[0]) && oe_i == on_i) ||
                         ((oe_cand[1] & a[1]) && (oe_cand[3] & a[3]) && os_i == ow_i) ||
                         ((oe_cand[3] & a[3]) && (oe_cand[0] & a[0]) && ow_i == on_i))
                         tie_decisions = tie_decisions + 1;
                     else
                         lower_decisions = lower_decisions + 1;
                 end
             end

        // ---- E2: exhaustive XY: every xy mask x availability x 9 backgrounds ----
        for (xp = 0; xp < 32; xp = xp + 1)
         for (a = 0; a < 16; a = a + 1)
          for (k = 0; k < 9; k = k + 1) begin
              case (k % 3)
                  0: c = 0;
                  1: c = 31;
                  default: c = 6;
              endcase
              case (k / 3)
                  0: apply(1'b0, xp[4:0], c[4:0], 0,0,0,0, a[3:0]);
                  1: apply(1'b0, xp[4:0], c[4:0], 4,4,4,4, a[3:0]);
                  default: apply(1'b0, xp[4:0], c[4:0], 1,2,3,4, a[3:0]);
              endcase
              check_model;
          end

        // ---- C1: chain with the real route_compute: all positions and destinations ----
        for (ix = 0; ix < 4; ix = ix + 1)
         for (iy = 0; iy < 4; iy = iy + 1)
          for (isx = 0; isx < 4; isx = isx + 1)
           for (idx = 0; idx < 4; idx = idx + 1)
            for (idy = 0; idy < 4; idy = idy + 1)
             for (md = 0; md < 2; md = md + 1)
              for (t = 0; t < 6; t = t + 1) begin
                  cx = ix; cy = iy; csx = isx; cdx = idx; cdy = idy; cmode = md;
                  r = $random(seed); if (r < 0) r = -r;   c_on = (t == 0) ? 3'd0 : (r % 5);
                  r = $random(seed); if (r < 0) r = -r;   c_os = (t == 0) ? 3'd0 : (r % 5);
                  r = $random(seed); if (r < 0) r = -r;   c_oe = (t == 0) ? 3'd0 : (r % 5);
                  r = $random(seed); if (r < 0) r = -r;   c_ow = (t == 0) ? 3'd0 : (r % 5);
                  #1;
                  checked = checked + 1;
                  // model with the real availability of this router
                  ms = model_sel(cmode, c_xy, c_oe_cand, c_on, c_os, c_oe, c_ow, {c_aw, c_ae, c_as, c_an});
                  if (c_sel !== ms)                     fail("chain: differs from independent model");
                  if (c_valid !== 1'b1)                 fail("chain: no selection for a real route");
                  if (popc(c_sel) != 1)                 fail("chain: selection not one-hot");
                  if (cmode == 1'b0 && c_sel !== c_xy)  fail("chain: XY mode must select the XY port");
                  if (cmode == 1'b1 && (c_sel & ~c_oe_cand) != 5'b0) fail("chain: adaptive selection not a candidate");
                  // in-bounds and progress for cardinal selections
                  d0 = ((ix > idx) ? ix - idx : idx - ix) + ((iy > idy) ? iy - idy : idy - iy);
                  if (c_sel[4]) begin
                      if (d0 != 0) fail("chain: Local selected away from destination");
                  end else begin
                      nx = ix; ny = iy;
                      if (c_sel[0]) ny = iy - 1;
                      if (c_sel[1]) ny = iy + 1;
                      if (c_sel[2]) nx = ix + 1;
                      if (c_sel[3]) nx = ix - 1;
                      if (nx < 0 || nx > 3 || ny < 0 || ny > 3) fail("chain: selection leaves the mesh");
                      d1 = ((nx > idx) ? nx - idx : idx - nx) + ((ny > idy) ? ny - idy : idy - ny);
                      if (d1 != d0 - 1) fail("chain: selection does not reduce the distance by 1");
                  end
              end

        $display("INFO: cases checked=%0d (directed + 320,000 adaptive + 4,608 XY + 12,288 chain)", checked);
        $display("INFO: coverage: two-candidate ties=%0d, two-candidate lowest-occupancy=%0d, candidate dropped as unavailable=%0d, Local-bit cases=%0d",
                 tie_decisions, lower_decisions, skipped_unavail, local_cases);
        if (tie_decisions   < 1000) begin errors = errors + 1; $display("ERROR: tie-break not exercised enough"); end
        if (lower_decisions < 1000) begin errors = errors + 1; $display("ERROR: occupancy decision not exercised enough"); end
        if (skipped_unavail == 0)   begin errors = errors + 1; $display("ERROR: unavailable-direction skipping never exercised"); end
        if (local_cases == 0)       begin errors = errors + 1; $display("ERROR: Local priority never exercised"); end
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
