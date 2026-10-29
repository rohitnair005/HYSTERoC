// =============================================================================
// switch_allocator.v : packet-level output allocation for one 5x5 router
// (spec 5.6). Combinational except for the five round-robin pointers.
//
// Inputs come from the five packet_tracker instances (index i = input port id):
//   req_valid[i]  head flit of input i wants to move
//   req_new[i]    ... and it is a header that needs arbitration
//   req_port[i]   its one-hot output (5 bits at [5*i +: 5])
//   locked[i], locked_port[i]  reservation held by input i
// and from downstream:
//   out_ready[o]  link ready of output o (0 for boundary/unused outputs)
//
// Rules:
//   * An output is BUSY while any input holds a reservation on it. A busy
//     output is never offered to arbitration, so no competing input can use a
//     reserved output, whatever the stalls (spec 5.6).
//   * A locked input continues on its own output whenever out_ready is 1
//     (body and tail never arbitrate).
//   * A free output arbitrates among headers requesting it with a round-robin
//     arbiter. The pointer moves only when the transfer really happens
//     (granted AND out_ready), so an unchanged request set keeps the same
//     winner while the output is stalled.
//   * The reservation is released by the packet_tracker on the accepted tail.
//     The output is therefore busy during the tail cycle and free from the next
//     cycle: one idle arbitration cycle between packets (documented trade-off).
//
// Outputs:
//   in_grant[i]     input i's head flit is transferred this cycle (= FIFO pop and
//                   packet_tracker xfer)
//   xbar_sel[o*5+i] one-hot select for the crossbar, all-zero when output o
//                   does not transfer this cycle
//   alloc_err       an output has two owners, or two inputs selected (never in
//                   a legal run; checked by assertions)
//
// Verilog-2001, no latches.
// =============================================================================
`include "hysteroc_defs.vh"

module switch_allocator (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [4:0]  req_valid,
    input  wire [4:0]  req_new,
    input  wire [24:0] req_port,       // input i at [5*i +: 5]
    input  wire [4:0]  locked,
    input  wire [24:0] locked_port,
    input  wire [4:0]  out_ready,

    output wire [4:0]  in_grant,
    output wire [24:0] xbar_sel,       // output o at [5*o +: 5], bit i = input i
    output wire [4:0]  out_busy,       // output o has a reservation
    output wire        alloc_err
);

    // ---- per-output views, built from per-input vectors ----
    wire [24:0] owner_any;   // [5*o+i]: input i holds a reservation on output o
    wire [24:0] owner_now;   // ... and has a flit at the head this cycle
    wire [24:0] arb_req;     // [5*o+i]: header i requests free output o
    wire [24:0] arb_gnt;
    wire [4:0]  arb_any;
    wire [14:0] arb_idx;
    wire [24:0] sel_pre;
    wire [4:0]  fire;
    wire [4:0]  multi_owner;
    wire [4:0]  multi_sel;

    // "more than one bit set" without adders
    function gt1;
        input [4:0] v;
        begin
            gt1 = (v[0] & (v[1] | v[2] | v[3] | v[4])) |
                  (v[1] & (v[2] | v[3] | v[4])) |
                  (v[2] & (v[3] | v[4])) |
                  (v[3] & v[4]);
        end
    endfunction

    genvar o, i;
    generate
        for (o = 0; o < 5; o = o + 1) begin : g_out
            for (i = 0; i < 5; i = i + 1) begin : g_in
                assign owner_any[5*o+i] = locked[i] & locked_port[5*i+o];
                assign owner_now[5*o+i] = locked[i] & locked_port[5*i+o] & req_valid[i];
            end

            assign out_busy[o] = |owner_any[5*o +: 5];

            for (i = 0; i < 5; i = i + 1) begin : g_req
                assign arb_req[5*o+i] = req_new[i] & req_port[5*i+o] & ~out_busy[o];
            end

            round_robin_arbiter #(.N(5), .IDX_W(3)) u_arb (
                .clk(clk), .rst_n(rst_n),
                .req(arb_req[5*o +: 5]),
                .advance(fire[o]),
                .grant(arb_gnt[5*o +: 5]),
                .grant_idx(arb_idx[3*o +: 3]),
                .any_grant(arb_any[o])
            );

            // reserved output: its owner; free output: the arbitration winner
            assign sel_pre[5*o +: 5] = out_busy[o] ? owner_now[5*o +: 5] : arb_gnt[5*o +: 5];

            assign fire[o]    = (|sel_pre[5*o +: 5]) & out_ready[o];
            assign xbar_sel[5*o +: 5] = {5{fire[o]}} & sel_pre[5*o +: 5];

            // sanity: at most one owner per output and at most one selected input
            assign multi_owner[o] = gt1(owner_any[5*o +: 5]);
            assign multi_sel[o]   = gt1(sel_pre[5*o +: 5]);
        end

        for (i = 0; i < 5; i = i + 1) begin : g_grant
            assign in_grant[i] = xbar_sel[i] | xbar_sel[5+i] | xbar_sel[10+i] |
                                 xbar_sel[15+i] | xbar_sel[20+i];
        end
    endgenerate

    assign alloc_err = |multi_owner | |multi_sel;

    // arb_any is only informational (the arbiter ignores advance without a grant)
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_ok = &{1'b0, arb_any, arb_idx};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
