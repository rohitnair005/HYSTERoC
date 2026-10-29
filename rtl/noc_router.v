// =============================================================================
// noc_router.v : one 5-port wormhole router (spec 9.2). Integration only: every
// block is a separately tested module.
//
//   per input port p (N0 S1 E2 W3 L4):
//     input_fifo -> packet_tracker -> route_compute -> route_select
//   shared: switch_allocator (5 round-robin arbiters), crossbar,
//           registered neighbour-occupancy sideband, congestion_estimator,
//           ewma_filter.
//
// Links (flattened, index = port id):  in_*/out_* data [16p+:16], type [2p+:2].
//   in_valid[p] && in_ready[p]   : flit accepted into FIFO p
//   out_valid[o] && out_ready[o] : flit leaves on output o
//   in_ready = FIFO ready_in = (count != 4)  (registered state only)
//   out_valid is asserted ONLY in a cycle in which out_ready is 1 (the
//   transfer happens in that same cycle). "valid && !ready" therefore never
//   occurs on an output link, so the hold-while-stalled rule holds trivially.
//   out_ready must not depend combinationally on out_valid (it is a FIFO
//   ready_in or a constant for the sink).
// Boundary outputs: out_ready is additionally masked with avail_*; a boundary
// output never transfers. Local output is always available.
//
// Sideband: nbr_occ_in[3d+:3] is the neighbour's CURRENT input-FIFO occupancy
// in direction d (N0 S1 E2 W3); it is registered here, so every consumer
// (congestion estimate, adaptive route choice) sees the same one-cycle-old
// value (spec 9.4). nbr_avail[d] = 0 on a mesh boundary (static).
//
// Mode: active_mode is shared and global (0 XY, 1 adaptive). ewma_enable = 0
// freezes the EWMA state (spec 6.5).
//
// Outputs for the rest of the system:
//   fifo_occ[3p+:3]  five local FIFO occupancies (drain detection, spec 9.2)
//   router_empty     all FIFOs empty AND no packet reservation held. The router
//                    has no other internal storage (crossbar is combinational).
//   ewma_out         E = S>>3 of this router (input to the global maximum)
//   cong_now         unfiltered mapped congestion (0/64/128/192/255)
//   max_occ_now      unfiltered max neighbour occupancy 0..4 (raw baselines)
//   proto_err        any packet_tracker protocol violation (assertions)
//   alloc_err        allocator consistency error (assertions)
// Verilog-2001.
// =============================================================================
`include "hysteroc_defs.vh"

module noc_router #(
    parameter SAMPLE_PERIOD = `HY_SAMPLE_PERIOD_DEFAULT
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [1:0]   x_coord,
    input  wire [1:0]   y_coord,

    input  wire         active_mode,
    input  wire         ewma_enable,

    // incoming links
    input  wire [79:0]  in_data,
    input  wire [9:0]   in_type,
    input  wire [4:0]   in_valid,
    output wire [4:0]   in_ready,

    // outgoing links
    output wire [79:0]  out_data,
    output wire [9:0]   out_type,
    output wire [4:0]   out_valid,
    input  wire [4:0]   out_ready,

    // neighbour occupancy sideband (N,S,E,W)
    input  wire [11:0]  nbr_occ_in,
    input  wire [3:0]   nbr_avail,

    output wire [14:0]  fifo_occ,
    output wire         router_empty,
    output wire [7:0]   ewma_out,
    output wire [7:0]   cong_now,
    output wire [2:0]   max_occ_now,
    output wire         proto_err,
    output wire         alloc_err
);

    // ------------------------------------------------------------------
    // registered neighbour occupancy sideband (one cycle old)
    // ------------------------------------------------------------------
    reg [11:0] occ_q;
    always @(posedge clk) begin
        if (!rst_n) occ_q <= 12'd0;
        else        occ_q <= nbr_occ_in;
    end
    wire [2:0] occ_n = occ_q[2:0];
    wire [2:0] occ_s = occ_q[5:3];
    wire [2:0] occ_e = occ_q[8:6];
    wire [2:0] occ_w = occ_q[11:9];
    wire avail_n = nbr_avail[0];
    wire avail_s = nbr_avail[1];
    wire avail_e = nbr_avail[2];
    wire avail_w = nbr_avail[3];

    // ------------------------------------------------------------------
    // congestion estimate + EWMA
    // ------------------------------------------------------------------
    wire any_avail_unused;
    congestion_estimator u_cong (
        .occ_n(occ_n), .occ_s(occ_s), .occ_e(occ_e), .occ_w(occ_w),
        .avail_n(avail_n), .avail_s(avail_s), .avail_e(avail_e), .avail_w(avail_w),
        .max_occ(max_occ_now), .cong(cong_now), .any_avail(any_avail_unused)
    );

    wire [10:0] ewma_s_unused;
    ewma_filter #(.SAMPLE_PERIOD(SAMPLE_PERIOD)) u_ewma (
        .clk(clk), .rst_n(rst_n), .enable(ewma_enable),
        .sample(cong_now), .s_out(ewma_s_unused), .e_out(ewma_out)
    );

    // ------------------------------------------------------------------
    // per-input datapath
    // ------------------------------------------------------------------
    wire [79:0] h_data;
    wire [9:0]  h_type;
    wire [4:0]  h_valid;
    wire [14:0] occ_w3;
    wire [4:0]  tr_req_valid, tr_req_new, tr_locked, tr_err;
    wire [24:0] tr_req_port, tr_locked_port;
    wire [4:0]  in_grant;

    genvar p;
    generate
        for (p = 0; p < 5; p = p + 1) begin : g_in
            input_fifo u_fifo (
                .clk(clk), .rst_n(rst_n),
                .push(in_valid[p] & in_ready[p]),
                .data_in(in_data[16*p +: 16]), .type_in(in_type[2*p +: 2]),
                .ready_in(in_ready[p]),
                .pop(in_grant[p]),
                .data_out(h_data[16*p +: 16]), .type_out(h_type[2*p +: 2]),
                .valid_out(h_valid[p]),
                .occupancy(occ_w3[3*p +: 3])
            );

            wire [1:0] dst_x, dst_y, src_x, src_y;
            wire [4:0] xy_port, oe_cand, sel_port;
            wire       sel_valid_unused;

            packet_tracker u_trk (
                .clk(clk), .rst_n(rst_n),
                .head_valid(h_valid[p]), .head_type(h_type[2*p +: 2]), .head_data(h_data[16*p +: 16]),
                .route_port(sel_port), .xfer(in_grant[p]),
                .hdr_dst_x(dst_x), .hdr_dst_y(dst_y), .hdr_src_x(src_x), .hdr_src_y(src_y),
                .req_valid(tr_req_valid[p]), .req_port(tr_req_port[5*p +: 5]), .req_new(tr_req_new[p]),
                .locked(tr_locked[p]), .locked_port(tr_locked_port[5*p +: 5]),
                .proto_err(tr_err[p])
            );

            route_compute u_rc (
                .x(x_coord), .y(y_coord), .dst_x(dst_x), .dst_y(dst_y), .src_x(src_x),
                .xy_port(xy_port), .oe_cand(oe_cand)
            );

            route_select u_rs (
                .active_mode(active_mode), .xy_port(xy_port), .oe_cand(oe_cand),
                .occ_n(occ_n), .occ_s(occ_s), .occ_e(occ_e), .occ_w(occ_w),
                .avail_n(avail_n), .avail_s(avail_s), .avail_e(avail_e), .avail_w(avail_w),
                .sel_port(sel_port), .sel_valid(sel_valid_unused)
            );

            // src_y and the packet-ID bits are not used by the router
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_ok = &{1'b0, src_y, sel_valid_unused};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    assign fifo_occ = occ_w3;

    // ------------------------------------------------------------------
    // allocation and switching
    // ------------------------------------------------------------------
    // boundary outputs never transfer; Local is always available
    wire [4:0] alloc_ready = out_ready & {1'b1, avail_w, avail_e, avail_s, avail_n};

    wire [24:0] xbar_sel;
    wire [4:0]  out_busy_unused;

    switch_allocator u_alloc (
        .clk(clk), .rst_n(rst_n),
        .req_valid(tr_req_valid), .req_new(tr_req_new), .req_port(tr_req_port),
        .locked(tr_locked), .locked_port(tr_locked_port),
        .out_ready(alloc_ready),
        .in_grant(in_grant), .xbar_sel(xbar_sel),
        .out_busy(out_busy_unused), .alloc_err(alloc_err)
    );

    crossbar u_xbar (
        .in_data(h_data), .in_type(h_type), .sel(xbar_sel),
        .out_data(out_data), .out_type(out_type), .out_valid(out_valid)
    );

    // ------------------------------------------------------------------
    // status
    // ------------------------------------------------------------------
    assign router_empty = ~(|h_valid) & ~(|tr_locked);
    assign proto_err    = |tr_err;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_top = &{1'b0, out_busy_unused, any_avail_unused, ewma_s_unused};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
