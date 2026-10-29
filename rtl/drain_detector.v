// =============================================================================
// drain_detector.v : network-wide quiescence reduction (spec 7.3, 9.3)
//
// Per mesh node n (N nodes, default 16) three status bits, all describing the
// SAME clock cycle:
//   router_empty[n]  all five FIFOs empty and no packet reservation (noc_router)
//   src_empty[n]     the source at node n holds no admitted packet: queue empty
//                    and no injection in progress (traffic_generator, batch 12)
//   link_active[n]   a flit is on a link attached to node n THIS cycle (any
//                    router out_valid or source in_valid). Links are plain
//                    wires, so a flit in transit is exactly a valid on a link.
//
// drained_now = every router empty AND every source empty AND no link active.
// network_drained = drained_now held for CONFIRM consecutive cycles (default 2)
// AND drained_now this cycle. It therefore drops in the same cycle as any
// activity and rises only after CONFIRM quiet cycles. Counting is race free:
// all inputs are sampled in one cycle and the reduction is a single AND tree.
// Because injection is blocked before DRAIN is entered, once the network is
// drained it stays drained; the confirm window and the re-check in SWITCH are
// extra conservatism, not a requirement.
// Verilog-2001.
// =============================================================================
module drain_detector #(
    parameter N       = 16,
    parameter CONFIRM = 2          // >= 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] router_empty,
    input  wire [N-1:0] src_empty,
    input  wire [N-1:0] link_active,

    output wire         drained_now,
    output wire         network_drained
);

    assign drained_now = (&router_empty) & (&src_empty) & ~(|link_active);

    // consecutive quiet cycles, saturating at CONFIRM
    reg [7:0] quiet;
    always @(posedge clk) begin
        if (!rst_n)                              quiet <= 8'd0;
        else if (!drained_now)                   quiet <= 8'd0;
        else if (quiet < CONFIRM[7:0])           quiet <= quiet + 8'd1;
    end

    // quiet counts completed quiet cycles BEFORE this one; this cycle is the
    // CONFIRM-th when quiet == CONFIRM-1
    assign network_drained = drained_now & (quiet >= (CONFIRM[7:0] - 8'd1));

endmodule
