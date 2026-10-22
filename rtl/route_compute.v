// =============================================================================
// route_compute.v : XY and adaptive Odd-Even route candidates (spec 4.4, 5.4 v5)
//
// Purely combinational. One instance per input FIFO head (header flit).
// Coordinates: x grows East, y grows South, 2-bit values 0..3 (4x4 mesh).
// There is NO incoming-direction input (spec 5.4). Inputs:
//   x, y        this router            dst_x, dst_y  from header [15:14],[13:12]
//   src_x       source column          from header [11:10]  (src_y is not needed)
//
// Outputs are 5-bit port masks, bit i = port id i (N=0 S=1 E=2 W=3 L=4):
//   xy_port : exactly one bit. Deterministic XY: X first, then Y; Local at the
//             destination.
//   oe_cand : legal adaptive Odd-Even candidate set (1 or 2 bits).
//
// Odd-Even candidate table (spec v5 5.4; ex = dst_x - x, ey = dst_y - y):
//   ex==0, ey==0 : Local
//   ex==0, ey!=0 : vertical toward destination
//   ex> 0, ey==0 : East
//   ex> 0, ey!=0 : vertical if (x odd) OR (x == src_x);
//                  East     if (dst_x odd) OR (ex != 1)       (independent tests)
//   ex< 0        : West; also vertical (if ey != 0) when x is even
// "Vertical toward destination" = South if dst_y > y, North if dst_y < y.
//
// Boundary: every candidate is a progress direction toward an in-range
// destination, so it can never point out of the mesh. No separate mask is built
// because that logic would be provably redundant for 2-bit coordinates in a 4x4
// mesh; tb_route_compute checks "in bounds" exhaustively for all 1024 inputs.
// The set is never empty (checked exhaustively).
//
// Status: "Odd-Even candidate implementation". Verified against Chiu's two turn
// rules, minimality and CDG acyclicity by scripts/cdg_check.py. Not a proof of
// whole-router deadlock freedom (see DECISIONS.md).
// =============================================================================
`include "hysteroc_defs.vh"

module route_compute (
    input  wire [1:0] x,
    input  wire [1:0] y,
    input  wire [1:0] dst_x,
    input  wire [1:0] dst_y,
    input  wire [1:0] src_x,

    output wire [4:0] xy_port,
    output wire [4:0] oe_cand
);

    // comparisons (unsigned, 2-bit)
    wire east_needed  = (dst_x > x);          // ex > 0
    wire west_needed  = (dst_x < x);          // ex < 0
    wire same_col     = (dst_x == x);         // ex == 0
    wire south_needed = (dst_y > y);          // ey > 0
    wire north_needed = (dst_y < y);          // ey < 0
    wire same_row     = (dst_y == y);         // ey == 0
    wire at_dest      = same_col & same_row;

    wire ex_is_one    = ({1'b0, dst_x} == ({1'b0, x} + 3'd1));   // ex == 1
    wire x_odd        = x[0];
    wire dst_x_odd    = dst_x[0];
    wire x_is_src     = (x == src_x);

    // ---------------- XY ----------------
    wire xy_e = east_needed;
    wire xy_w = west_needed;
    wire xy_s = same_col & south_needed;
    wire xy_n = same_col & north_needed;
    wire xy_l = at_dest;

    assign xy_port = ({5{xy_n}} & `HY_PM_N) | ({5{xy_s}} & `HY_PM_S) |
                     ({5{xy_e}} & `HY_PM_E) | ({5{xy_w}} & `HY_PM_W) |
                     ({5{xy_l}} & `HY_PM_L);

    // ---------------- Odd-Even ----------------
    wire east_vert_ok = x_odd | x_is_src;            // ex > 0, ey != 0: vertical allowed
    wire east_east_ok = dst_x_odd | ~ex_is_one;      // ex > 0, ey != 0: East allowed

    // East: straight (ey == 0) or ex > 0 and the East test passes
    wire oe_e = east_needed & (same_row | east_east_ok);

    // vertical allowed when ey != 0 (implied by south_needed / north_needed):
    //   same column          : always
    //   eastbound (ex > 0)   : x odd or x == src_x
    //   westbound (ex < 0)   : x even
    wire vert_ok = same_col | (east_needed & east_vert_ok) | (west_needed & ~x_odd);

    wire oe_s = south_needed & vert_ok;
    wire oe_n = north_needed & vert_ok;
    wire oe_w = west_needed;
    wire oe_l = at_dest;

    assign oe_cand = ({5{oe_n}} & `HY_PM_N) | ({5{oe_s}} & `HY_PM_S) |
                     ({5{oe_e}} & `HY_PM_E) | ({5{oe_w}} & `HY_PM_W) |
                     ({5{oe_l}} & `HY_PM_L);

endmodule
