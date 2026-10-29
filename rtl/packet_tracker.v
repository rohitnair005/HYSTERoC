// =============================================================================
// packet_tracker.v : header parsing + packet-level output reservation for ONE
// input port (spec 5.3, 5.6). One instance per input FIFO.
//
// Per-port state: `locked` and `locked_port` (one-hot output owned by the packet
// currently crossing this input). Nothing else is stored: the router is
// TYPE-driven. The fixed four-flit length is produced by the sources and
// checked by the testbenches and the sink, not by a counter per port (saves
// 2 flip-flops and compare logic on each of the 80 ports; recorded in
// DECISIONS.md).
//
// Behaviour (spec 5.6, ACCEPTED):
//   * Unlocked, head is a HEADER, route_port != 0 : the input REQUESTS
//     route_port (req_new = 1: this request needs output arbitration).
//     A stalled header reserves nothing. route_port may change from cycle to
//     cycle while it waits (it follows the occupancy sideband).
//   * `xfer` = the head flit was accepted this cycle (granted AND downstream
//     ready AND head valid), i.e. the FIFO pop strobe. On an accepted HEADER
//     the reservation starts: locked <= 1, locked_port <= the port that was
//     requested in that same cycle.
//   * Locked: every flit, whatever route_port says, requests locked_port
//     (req_new = 0: continuation, already owns the output). Ownership is stable
//     under backpressure because state only changes on `xfer`.
//   * An accepted TAIL releases the reservation (locked <= 0). Nothing else
//     releases it.
//   * Body and tail flits carry no destination and never use route_port.
//
// Protocol violations (never produced by a legal network) are reported by the
// combinational `proto_err` and otherwise ignored: unlocked and head is not a
// header; locked and head is a header; reserved flit type 2'b11.
// Defensive: `xfer` without a valid head, or on an unlocked non-request, is
// ignored.
//
// route_port must be one-hot or zero (route_select guarantees it).
// Header fields are exposed for route_compute; they are meaningful only while
// head is a header. Verilog-2001, no latches. Reset: synchronous, active low.
// =============================================================================
`include "hysteroc_defs.vh"

module packet_tracker (
    input  wire        clk,
    input  wire        rst_n,

    // head of the input FIFO (first-word-fall-through)
    input  wire        head_valid,
    input  wire [1:0]  head_type,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [15:0] head_data,       // [7:0] packet ID is not used here
    /* verilator lint_on UNUSEDSIGNAL */

    // output chosen for a header by route_select (one-hot, 0 = none)
    input  wire [4:0]  route_port,

    // accepted transfer of the head flit this cycle (granted && ready && valid)
    input  wire        xfer,

    // parsed header fields (spec 4.3)
    output wire [1:0]  hdr_dst_x,
    output wire [1:0]  hdr_dst_y,
    output wire [1:0]  hdr_src_x,
    output wire [1:0]  hdr_src_y,

    // request to the switch allocator
    output wire        req_valid,        // the head flit wants to move this cycle
    output wire [4:0]  req_port,         // one-hot output it wants (0 if !req_valid)
    output wire        req_new,          // request starts a new packet (needs arbitration)

    // reservation state
    output wire        locked,
    output wire [4:0]  locked_port,

    output wire        proto_err         // combinational protocol-violation flag
);

    // header fields, bit positions from hysteroc_defs.vh
    assign hdr_dst_x = head_data[`HY_HDR_DSTX_HI:`HY_HDR_DSTX_LO];
    assign hdr_dst_y = head_data[`HY_HDR_DSTY_HI:`HY_HDR_DSTY_LO];
    assign hdr_src_x = head_data[`HY_HDR_SRCX_HI:`HY_HDR_SRCX_LO];
    assign hdr_src_y = head_data[`HY_HDR_SRCY_HI:`HY_HDR_SRCY_LO];

    wire head_is_header = (head_type == `HY_FT_HEADER);
    wire head_is_tail   = (head_type == `HY_FT_TAIL);
    wire head_is_rsvd   = (head_type == `HY_FT_RSVD);

    reg        locked_r;
    reg [4:0]  locked_port_r;

    // a new packet may request only with a valid header and a selected route
    wire new_ok = head_valid & ~locked_r & head_is_header & (route_port != 5'b00000);

    assign req_new   = new_ok;
    assign req_valid = head_valid & (locked_r | new_ok);
    assign req_port  = {5{req_valid}} & (locked_r ? locked_port_r : route_port);

    assign locked      = locked_r;
    assign locked_port = locked_port_r;

    assign proto_err = head_valid & (head_is_rsvd |
                                     (~locked_r & ~head_is_header) |
                                     ( locked_r &  head_is_header));

    // an accepted transfer only counts if a flit is really at the head
    wire xfer_ok = xfer & head_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            locked_r      <= 1'b0;
            locked_port_r <= 5'b00000;
        end else if (xfer_ok) begin
            if (!locked_r) begin
                if (new_ok) begin                    // accepted HEADER: reservation starts
                    locked_r      <= 1'b1;
                    locked_port_r <= route_port;
                end
            end else if (head_is_tail) begin         // accepted TAIL: reservation ends
                locked_r      <= 1'b0;
                locked_port_r <= 5'b00000;
            end
        end
    end

endmodule
