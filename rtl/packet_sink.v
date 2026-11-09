// =============================================================================
// packet_sink.v : one ejection endpoint per mesh node (spec 8 item 11)
//
// ej_ready is a REGISTERED random bit (never depends on ej_valid, DECISIONS 38):
//   ready_thresh = 8'hFF -> always ready; otherwise ready with probability
//   ready_thresh/256 each cycle (0 = never ready).
// Every accepted flit (ej_valid & ej_ready) is checked against the packet
// format produced by traffic_generator:
//   flit 0 header whose destination equals NODE        (else err_dest)
//   flits 1,2 body, flit 3 tail, no early/late header, no reserved type (err_order)
//   tail == header ^ body1 ^ body2 ^ 16'hC3A5            (else err_integrity)
// After a violation the sink resynchronises on the next header. On a good tail
// it raises pkt_done for one cycle (registered) with
//   pkt_src, pkt_pid, pkt_lat_total = now - creation time (16-bit modulo)
//   pkt_lat_net = now - injection time   (`now` = cycle of the tail accept)
// Counters: pkts_ok, flits, err_dest_cnt, err_order_cnt, err_integ_cnt; err_any
// is the OR of the three counters being non-zero (sticky until reset).
// Verilog-2001, synchronous active-low reset.
// =============================================================================
`include "hysteroc_defs.vh"

module packet_sink #(
    parameter [3:0]  NODE = 4'd0,
    parameter [31:0] SEED = 32'h1
) (
    input  wire        clk,
    input  wire        rst_n,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] now,             // only now[15:0] is used
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [7:0]  ready_thresh,

    input  wire [15:0] ej_data,
    input  wire [1:0]  ej_type,
    input  wire        ej_valid,
    output reg         ej_ready,

    output reg         pkt_done,
    output reg  [3:0]  pkt_src,
    output reg  [7:0]  pkt_pid,
    output reg  [15:0] pkt_lat_total,
    output reg  [15:0] pkt_lat_net,

    output reg  [31:0] pkts_ok,
    output reg  [31:0] flits,
    output reg  [15:0] err_dest_cnt,
    output reg  [15:0] err_order_cnt,
    output reg  [15:0] err_integ_cnt,
    output wire        err_any
);

    reg [31:0] rnd;
    wire [31:0] rx1 = rnd ^ (rnd << 13);
    wire [31:0] rx2 = rx1 ^ (rx1 >> 17);
    wire [31:0] rx3 = rx2 ^ (rx2 << 5);

    reg [1:0]  f;
    reg [15:0] hdr, b0, b1;

    wire acc = ej_valid & ej_ready;
    wire is_hdr  = (ej_type == `HY_FT_HEADER);
    wire is_body = (ej_type == `HY_FT_BODY);
    wire is_tail = (ej_type == `HY_FT_TAIL);

    wire dst_match = (ej_data[`HY_HDR_DSTX_HI:`HY_HDR_DSTX_LO] == NODE[1:0]) &&
                     (ej_data[`HY_HDR_DSTY_HI:`HY_HDR_DSTY_LO] == NODE[3:2]);
    wire [15:0] expect_tail = hdr ^ b0 ^ b1 ^ 16'hC3A5;

    assign err_any = (err_dest_cnt != 16'd0) | (err_order_cnt != 16'd0) | (err_integ_cnt != 16'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            rnd           <= (SEED ^ ({28'd0, NODE} * 32'h85EBCA6B) ^ 32'hC2B2AE35) | 32'h1;
            ej_ready      <= 1'b0;
            f             <= 2'd0;
            hdr <= 16'd0; b0 <= 16'd0; b1 <= 16'd0;
            pkt_done      <= 1'b0;
            pkt_src       <= 4'd0;
            pkt_pid       <= 8'd0;
            pkt_lat_total <= 16'd0;
            pkt_lat_net   <= 16'd0;
            pkts_ok       <= 32'd0;
            flits         <= 32'd0;
            err_dest_cnt  <= 16'd0;
            err_order_cnt <= 16'd0;
            err_integ_cnt <= 16'd0;
        end else begin
            rnd      <= rx3;
            ej_ready <= (ready_thresh == 8'hFF) ? 1'b1 : (rnd[7:0] < ready_thresh);
            pkt_done <= 1'b0;

            if (acc) begin
                flits <= flits + 32'd1;
                if (is_hdr) begin
                    if (f != 2'd0) err_order_cnt <= err_order_cnt + 16'd1;   // previous packet truncated
                    if (!dst_match) err_dest_cnt <= err_dest_cnt + 16'd1;
                    hdr <= ej_data;
                    f   <= 2'd1;
                end else if (is_body) begin
                    if (f == 2'd1)      begin b0 <= ej_data; f <= 2'd2; end
                    else if (f == 2'd2) begin b1 <= ej_data; f <= 2'd3; end
                    else begin err_order_cnt <= err_order_cnt + 16'd1; f <= 2'd0; end
                end else if (is_tail) begin
                    if (f == 2'd3) begin
                        if (ej_data != expect_tail) err_integ_cnt <= err_integ_cnt + 16'd1;
                        else begin
                            pkts_ok       <= pkts_ok + 32'd1;
                            pkt_done      <= 1'b1;
                            pkt_src       <= {hdr[`HY_HDR_SRCY_HI:`HY_HDR_SRCY_LO], hdr[`HY_HDR_SRCX_HI:`HY_HDR_SRCX_LO]};
                            pkt_pid       <= hdr[`HY_HDR_PID_HI:`HY_HDR_PID_LO];
                            pkt_lat_total <= now[15:0] - b0;
                            pkt_lat_net   <= now[15:0] - b1;
                        end
                    end else begin
                        err_order_cnt <= err_order_cnt + 16'd1;
                    end
                    f <= 2'd0;
                end else begin                       // reserved type
                    err_order_cnt <= err_order_cnt + 16'd1;
                    f <= 2'd0;
                end
            end
        end
    end

endmodule
