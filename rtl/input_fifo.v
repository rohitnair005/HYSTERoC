// =============================================================================
// input_fifo.v : synchronous input FIFO for one router port (spec 5.2, 9.1)
//
// - Stores {flit_type, data}; default depth 4 (PTR_W = 2), occupancy 0..4.
// - First-word-fall-through: data_out/type_out always show the head entry, so
//   they stay stable while valid_out && !pop (link rule, spec 3.2).
// - ACCEPTED policy (spec 5.2):  ready_in = (count != DEPTH).
//   ready_in depends only on registered state, never on pop, so a full FIFO
//   does NOT accept a push in the same cycle as a pop (no comb. path through
//   the router).
// - push is an accepted-transfer strobe from the upstream link
//   (valid && ready_in); pop is an accepted-transfer strobe downstream.
//   Defensive behaviour: push while full and pop while empty are IGNORED and
//   never corrupt state (testbench checks this).
// - Simultaneous push+pop at 1..DEPTH-1 entries: count unchanged, both pointers
//   advance.
// - Synchronous active-low reset (rst_n) clears pointers and count; storage is
//   not reset (valid_out gates its use).
//
// Verilog-2001, no vendor primitives, no latches.
// =============================================================================
`include "hysteroc_defs.vh"

module input_fifo #(
    parameter DATA_W = `HY_DATA_W,        // 16
    parameter TYPE_W = `HY_TYPE_W,        // 2
    parameter PTR_W  = `HY_FIFO_PTR_W     // depth = 2**PTR_W = 4
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // write side (upstream link, accepted transfer)
    input  wire                 push,
    input  wire [DATA_W-1:0]    data_in,
    input  wire [TYPE_W-1:0]    type_in,
    output wire                 ready_in,

    // read side (downstream, accepted transfer)
    input  wire                 pop,
    output wire [DATA_W-1:0]    data_out,
    output wire [TYPE_W-1:0]    type_out,
    output wire                 valid_out,

    // occupancy 0..DEPTH (3 bits at default depth 4)
    output wire [PTR_W:0]       occupancy
);

    localparam DEPTH = (1 << PTR_W);
    localparam W     = TYPE_W + DATA_W;

    reg [W-1:0]     mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [PTR_W:0]   count;

    // status derived from registered state only
    assign ready_in  = (count != DEPTH);
    assign valid_out = (count != {(PTR_W+1){1'b0}});
    assign occupancy = count;

    // head entry (first-word-fall-through)
    wire [W-1:0] head = mem[rd_ptr];
    assign data_out = head[DATA_W-1:0];
    assign type_out = head[W-1:DATA_W];

    // guarded strobes: illegal push/pop are ignored
    wire push_ok = push & ready_in;
    wire pop_ok  = pop  & valid_out;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {(PTR_W+1){1'b0}};
        end else begin
            if (push_ok) begin
                mem[wr_ptr] <= {type_in, data_in};
                wr_ptr      <= wr_ptr + 1'b1;   // wraps naturally at DEPTH
            end
            if (pop_ok) begin
                rd_ptr <= rd_ptr + 1'b1;        // wraps naturally at DEPTH
            end
            case ({push_ok, pop_ok})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;        // 00 or simultaneous 11
            endcase
        end
    end

endmodule
