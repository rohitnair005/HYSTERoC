// =============================================================================
// congestion_estimator.v : router-wide congestion sample (spec 6.1, 6.2, 9.4)
//
// Inputs are the registered, one-cycle-old neighbour occupancy sideband values
// (3 bits each, 0..4) with one availability bit per cardinal direction.
// Local is never an input (spec 6.1).
//
//   max_occ = max over AVAILABLE directions of occupancy   (0 if none available)
//   cong    = map(max_occ) with the FROZEN table 0,64,128,192,255 (spec 6.2)
//
// - An unavailable (boundary) direction is excluded by masking it to 0 before
//   the max, which is exactly "excluded" because 0 is the minimum value. It is
//   NOT the same as an available direction with occupancy 0: any_avail tells
//   the two cases apart (spec 9.4).
// - All directions unavailable: max_occ = 0, cong = 0, any_avail = 0.
// - Defensive: an illegal occupancy value 5..7 is clamped to 4 (-> 255). The
//   FIFO never produces it; this keeps cong monotonic and bounded.
// - Purely combinational (inputs are already registered in the router).
// - max_occ is also exposed because the raw-occupancy baseline configurations
//   (spec 12.1) need the un-filtered value.
// =============================================================================
`include "hysteroc_defs.vh"

module congestion_estimator (
    input  wire [2:0] occ_n,
    input  wire [2:0] occ_s,
    input  wire [2:0] occ_e,
    input  wire [2:0] occ_w,
    input  wire       avail_n,
    input  wire       avail_s,
    input  wire       avail_e,
    input  wire       avail_w,

    output wire [2:0] max_occ,      // 0..4
    output wire [7:0] cong,         // mapped 0/64/128/192/255
    output wire       any_avail     // at least one direction available
);

    function [2:0] clamp4;
        input [2:0] v;
        begin
            clamp4 = (v > 3'd4) ? 3'd4 : v;
        end
    endfunction

    function [2:0] max2;
        input [2:0] a;
        input [2:0] b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    function [7:0] map_occ;
        input [2:0] o;
        begin
            case (o)
                3'd0:    map_occ = `HY_CONG_OCC0;
                3'd1:    map_occ = `HY_CONG_OCC1;
                3'd2:    map_occ = `HY_CONG_OCC2;
                3'd3:    map_occ = `HY_CONG_OCC3;
                default: map_occ = `HY_CONG_OCC4;   // 4 (inputs are clamped)
            endcase
        end
    endfunction

    wire [2:0] m_n = avail_n ? clamp4(occ_n) : 3'd0;
    wire [2:0] m_s = avail_s ? clamp4(occ_s) : 3'd0;
    wire [2:0] m_e = avail_e ? clamp4(occ_e) : 3'd0;
    wire [2:0] m_w = avail_w ? clamp4(occ_w) : 3'd0;

    assign max_occ   = max2(max2(m_n, m_s), max2(m_e, m_w));
    assign cong      = map_occ(max_occ);
    assign any_avail = avail_n | avail_s | avail_e | avail_w;

endmodule
