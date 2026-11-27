// =============================================================================
// round_robin_arbiter.v : parameterised round-robin arbiter (spec 5.6)
//
// One instance arbitrates ONE output among N requesting inputs (default N = 5).
//
//   grant      : one-hot (or all-zero when nothing requests); grant is always a
//                subset of req, so at most one input is granted per cycle.
//   grant_idx  : binary index of the granted input (0 when no grant).
//   any_grant  : at least one request present.
//
// Priority: starting at the pointer `ptr`, the first requesting input in the
// order ptr, ptr+1, ..., wrapping at N, wins. Reset: ptr = 0.
//
// Pointer rule (spec 5.6): the pointer moves ONLY when `advance` says the
// granted transfer actually took place. If the transfer is stalled (no
// `advance`), ptr stays and, for an unchanged request set, the same input is
// granted again next cycle. On advance the pointer moves to granted index + 1
// (mod N), so the winner becomes lowest priority. `advance` with no grant is
// ignored.
//
// `advance` is an accepted-transfer strobe (valid && ready) for the granted
// flit. How the allocator reserves an output across a whole packet (header to
// tail) is NOT done here; the switch allocator holds the grant of a packet
// that owns the output and only offers a new arbitration when it is free.
//
// Requirement: N <= 2**IDX_W. Combinational grant, registered pointer, no
// latches, no vendor primitives. Verilog-2001.
// =============================================================================
module round_robin_arbiter #(
    parameter N     = 5,
    parameter IDX_W = 3
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [N-1:0]      req,
    input  wire              advance,       // granted transfer accepted this cycle

    output wire [N-1:0]      grant,
    output reg  [IDX_W-1:0]  grant_idx,
    output wire              any_grant
);

    reg [IDX_W-1:0] ptr;

    // Structure (small, no adders, no dynamic indexing):
    //   mask_ge[i] = (i >= ptr)                  requests at or after the pointer
    //   if any request has index >= ptr, pick the lowest of those,
    //   otherwise pick the lowest request overall (wrap-around).
    wire [N-1:0] mask_ge;
    wire [N-1:0] req_hi  = req & mask_ge;
    wire         use_hi  = |req_hi;
    wire [N-1:0] sel     = use_hi ? req_hi : req;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_arb
            localparam [IDX_W-1:0] KI = i;
            assign mask_ge[i] = (ptr <= KI);
            if (i == 0) begin : g_first
                assign grant[i] = sel[i];
            end else begin : g_rest
                assign grant[i] = sel[i] & ~(|sel[i-1:0]);   // lowest set bit
            end
        end
    endgenerate

    assign any_grant = |req;

    // one-hot grant -> binary index, and the index + 1 (mod N) for the pointer
    integer k;
    reg [IDX_W-1:0] next_ptr;
    always @(*) begin
        grant_idx = {IDX_W{1'b0}};
        next_ptr  = {IDX_W{1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            if (grant[k]) begin
                grant_idx = grant_idx | k[IDX_W-1:0];
                next_ptr  = next_ptr  | ((k == N - 1) ? {IDX_W{1'b0}} : (k[IDX_W-1:0] + 1'b1));
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n)
            ptr <= {IDX_W{1'b0}};
        else if (advance && any_grant)
            ptr <= next_ptr;
    end

endmodule
