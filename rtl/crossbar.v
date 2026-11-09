// =============================================================================
// crossbar.v : 5x5 flit crossbar (spec 5.6), purely combinational AND-OR mux.
//
// sel[o*5+i] = 1 connects input i to output o. The switch_allocator guarantees
// at most one select per output; because selects are one-hot per output and an
// input may only be selected by the output it requested, no input/output
// conflict can occur. Output o carries valid = |sel[o] and data/type of the
// selected input, or all-zero when idle (keeps idle links quiet and makes
// "no select -> no data" checkable).
// An input selected by two outputs at once would duplicate a flit; the
// allocator never does that, and tb_switch_allocator checks it.
// Verilog-2001, no latches.
// =============================================================================
`include "hysteroc_defs.vh"

module crossbar (
    input  wire [79:0] in_data,        // input i at [16*i +: 16]
    input  wire [9:0]  in_type,        // input i at [2*i  +: 2]
    input  wire [24:0] sel,            // output o at [5*o +: 5], bit i = input i

    output wire [79:0] out_data,       // output o at [16*o +: 16]
    output wire [9:0]  out_type,
    output wire [4:0]  out_valid
);

    genvar o;
    generate
        for (o = 0; o < 5; o = o + 1) begin : g_out
            reg [15:0] d;
            reg [1:0]  t;
            integer    k;
            always @(*) begin
                d = 16'h0000;
                t = 2'b00;
                for (k = 0; k < 5; k = k + 1) begin
                    d = d | (in_data[16*k +: 16] & {16{sel[5*o+k]}});
                    t = t | (in_type[2*k +: 2]   & {2{sel[5*o+k]}});
                end
            end
            assign out_data[16*o +: 16] = d;
            assign out_type[2*o +: 2]   = t;
            assign out_valid[o]         = |sel[5*o +: 5];
        end
    endgenerate

endmodule
