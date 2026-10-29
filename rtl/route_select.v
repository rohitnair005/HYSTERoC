// =============================================================================
// route_select.v : choose ONE output port for a header flit (spec 5.5)
//
// Purely combinational. Inputs come from route_compute (xy_port, oe_cand), the
// registered neighbour-occupancy sideband (occ_*, avail_*) and the shared
// global active_mode. Output sel_port is a 5-bit one-hot mask (bit i = port id
// i: N0 S1 E2 W3 L4) or all-zero when nothing can be selected.
//
//   active_mode = XY    : sel = xy_port           (occupancy and oe_cand ignored)
//   active_mode = ADAPT : sel = the available Odd-Even candidate whose
//                         neighbour input FIFO has the LOWEST occupancy;
//                         ties are broken in the frozen order East, South,
//                         West, North (spec 5.5; separate from round-robin
//                         arbitration).
//
// Rules (all tested exhaustively in tb_route_select):
//   * A cardinal direction whose avail_* bit is 0 (mesh boundary) is never
//     selected, in either mode. Local is always available.
//   * Local has priority in adaptive mode. route_compute never combines Local
//     with another candidate (Local only at the destination), so this rule only
//     matters for illegal inputs.
//   * A single available candidate is selected whatever its occupancy.
//   * occ_* are registered, one-cycle-old values 0..4 (spec 9.4). Values 5..7
//     are not produced by input_fifo; their behaviour is not specified.
//   * sel_valid = |sel_port. With a real route_compute result it is 0 only when
//     the router has no packet to route (the caller then does not use sel_port);
//     an in-range candidate is never unavailable, which tb_route_select checks
//     for every router position and destination.
//
// The selection may change from cycle to cycle while a header is stalled
// because it follows the sideband. That is safe: nothing is reserved until the
// header transfer is accepted (spec 5.6), and every candidate is legal.
// Verilog-2001, no latches.
// =============================================================================
`include "hysteroc_defs.vh"

module route_select (
    input  wire        active_mode,        // 0 = XY, 1 = adaptive Odd-Even
    input  wire [4:0]  xy_port,            // from route_compute
    input  wire [4:0]  oe_cand,            // from route_compute

    input  wire [2:0]  occ_n,              // neighbour input-FIFO occupancy 0..4
    input  wire [2:0]  occ_s,
    input  wire [2:0]  occ_e,
    input  wire [2:0]  occ_w,
    input  wire        avail_n,            // 0 on a mesh boundary
    input  wire        avail_s,
    input  wire        avail_e,
    input  wire        avail_w,

    output wire [4:0]  sel_port,           // one-hot, or 0 if none
    output wire        sel_valid
);

    // availability per port id: bit0 N, bit1 S, bit2 E, bit3 W, bit4 Local
    wire [4:0] avail_mask = {1'b1, avail_w, avail_e, avail_s, avail_n};

    wire [4:0] xy_sel = xy_port & avail_mask;
    wire [4:0] oe_el  = oe_cand & avail_mask;

    wire n_el = oe_el[`HY_PORT_N];
    wire s_el = oe_el[`HY_PORT_S];
    wire e_el = oe_el[`HY_PORT_E];
    wire w_el = oe_el[`HY_PORT_W];
    wire l_el = oe_el[`HY_PORT_L];

    // Running minimum in tie-break order E, S, W, N. A later port replaces the
    // current best only if its occupancy is STRICTLY lower, so an earlier port
    // wins every tie.
    reg [4:0] adapt_sel;
    reg [2:0] best_occ;
    reg       found;

    always @(*) begin
        adapt_sel = 5'b00000;
        best_occ  = 3'd0;
        found     = 1'b0;
        if (e_el) begin
            adapt_sel = `HY_PM_E; best_occ = occ_e; found = 1'b1;
        end
        if (s_el && (!found || occ_s < best_occ)) begin
            adapt_sel = `HY_PM_S; best_occ = occ_s; found = 1'b1;
        end
        if (w_el && (!found || occ_w < best_occ)) begin
            adapt_sel = `HY_PM_W; best_occ = occ_w; found = 1'b1;
        end
        if (n_el && (!found || occ_n < best_occ)) begin
            adapt_sel = `HY_PM_N; best_occ = occ_n; found = 1'b1;
        end
    end

    wire [4:0] adapt_final = l_el ? `HY_PM_L : adapt_sel;

    assign sel_port  = (active_mode == `HY_MODE_XY) ? xy_sel : adapt_final;
    assign sel_valid = |sel_port;

endmodule
