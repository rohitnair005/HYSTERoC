// =============================================================================
// ewma_filter.v : fixed-point EWMA of the 8-bit congestion sample (spec 6.3)
//
//   S      = 8 * E, stored as an 11-bit unsigned value (max representable 2047)
//   S_next = S - (S >> 3) + C          (C = 8-bit sample)
//   E      = S >> 3                    (8-bit estimate, fraction truncated)
//
// - No signed arithmetic. S - (S>>3) is never negative, so nothing can
//   underflow. From reset with C <= 255, S never exceeds 8*255 = 2040, so the
//   11-bit state cannot overflow. (For any S <= 2047 the result is still
//   <= 2047, so the 11-bit expression below never loses a bit.)
// - Reset (synchronous, active low): S = 0, sample-period counter = 0.
// - SAMPLE_PERIOD (default 1 = update every cycle): S updates once every
//   SAMPLE_PERIOD enabled cycles, using the sample present on that cycle. It is
//   not averaged between ticks. Valid range 1..65535. The period counter is
//   generated only when SAMPLE_PERIOD > 1.
// - enable = 0 FREEZES both S and the period counter (spec 6.5: EWMA is frozen
//   whenever the global controller is outside RUN). Synchronous, no latches.
//
// Behaviour for a constant input C (proved by hand, checked in tb_ewma_filter):
//   rising  from below: S climbs by >= 1 per tick and lands exactly on 8*C.
//   falling from above: S falls to 8*C + 7 and stops; E still settles at exactly C.
//
// Directed vector: C = 255 from reset gives
//   S = 255, 479, 675, ...      E = 31, 59, 84, ...
// =============================================================================
`include "hysteroc_defs.vh"

module ewma_filter #(
    parameter SAMPLE_PERIOD = `HY_SAMPLE_PERIOD_DEFAULT
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,        // 0 = freeze state
    input  wire [7:0]  sample,        // C : mapped congestion sample 0..255
    output wire [10:0] s_out,         // S = 8*E (exposed for testing)
    output wire [7:0]  e_out          // E = S >> 3
);

    localparam [15:0] LAST_TICK = SAMPLE_PERIOD - 1;

    reg  [10:0] S;
    wire        tick;

    // Sample-period counter exists ONLY when SAMPLE_PERIOD > 1. With the default
    // period of 1 every enabled cycle is a tick and no counter flip-flops are
    // built (16 flip-flops x 16 routers saved).
    generate
        if (SAMPLE_PERIOD > 1) begin : g_period
            reg [15:0] cnt;
            assign tick = (cnt == LAST_TICK);
            always @(posedge clk) begin
                if (!rst_n)       cnt <= 16'd0;
                else if (enable)  cnt <= tick ? 16'd0 : (cnt + 16'd1);
            end
        end else begin : g_every_cycle
            assign tick = 1'b1;
        end
    endgenerate

    // S - (S>>3) + C, all in 11 bits: S - (S>>3) >= 0 and the result is <= 2047
    // for every S <= 2047 (see header comment), so no bit is ever lost.
    wire [10:0] s_next = S - {3'b000, S[10:3]} + {3'b000, sample};

    always @(posedge clk) begin
        if (!rst_n)
            S <= 11'd0;
        else if (enable && tick)
            S <= s_next;
    end

    assign s_out = S;
    assign e_out = S[10:3];

endmodule
