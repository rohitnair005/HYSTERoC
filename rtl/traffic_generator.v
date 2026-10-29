// =============================================================================
// traffic_generator.v : one packet source per mesh node (spec 8 item 11, 7.3)
//
// Creation side (open loop)
//   Each cycle, if gen_enable and (max_packets == 0 or created < max_packets) and
//   a 16-bit random number is below `rate`, a packet is CREATED: destination from
//   `pattern`, 8-bit sequence number, creation timestamp now[15:0]. It goes into
//   a small queue (QDEPTH entries). If the queue is full the packet is DROPPED
//   and counted (offered = created + dropped). Offered load per node =
//   4 * rate / 65536 flits per cycle (1.0 = one flit every cycle).
//   Patterns (pattern input): 0 UNIFORM (any other node), 1 HOTSPOT (hot_pct/256
//   to hot_node, rest uniform), 2 TRANSPOSE (x,y)->(y,x) (diagonal nodes send
//   nothing), 3 COMPLEMENT (x,y)->(3-x,3-y), 4 NEIGHBOR (x,y)->(x+1 mod 4,y).
//   Unused pattern codes behave like UNIFORM.
//
// Injection side and the transition protocol (spec 7.2 / 7.3)
//   While idle, if the queue is not empty and inject_block_req = 0, the packet at
//   the queue head is STARTED: popped, and its four flits are offered on the
//   ready/valid link, valid held and data stable until accepted. A started packet
//   always finishes. No packet starts while inject_block_req = 1.
//   inject_block_ack = inject_block_req & idle   (level; will start nothing more)
//   src_empty        = idle                       (no injection in progress)
//   Packets waiting in the queue are not yet admitted into the network, so they
//   are not part of src_empty; they wait until the block is released.
//   Queued packets keep their creation timestamp, so end-to-end latency includes
//   the waiting caused by transitions (spec: latency from packet creation).
//
// Packet format (4 flits)
//   0 header {dst_x,dst_y,src_x,src_y,pid}   pid = per-node sequence number
//   1 body   creation time   now[15:0] when created
//   2 body   injection time  now[15:0] in the first cycle the header is offered
//   3 tail   header ^ body1 ^ body2 ^ 16'hC3A5       (integrity word)
//   `now` must be a free-running counter shared by all nodes and sinks that
//   increments every cycle. Latencies are differences modulo 65536, so a latency
//   of 65536 cycles or more would alias (not reachable in the planned runs).
//
// Observation outputs: create pulse (+dst, seq), counters created / dropped /
// injected (packets fully injected), flit_accept pulse, queue occupancy.
// PRNG: xorshift32 seeded from SEED and NODE (never zero).
// Verilog-2001, synchronous active-low reset.
// =============================================================================
`include "hysteroc_defs.vh"

module traffic_generator #(
    parameter [3:0]  NODE    = 4'd0,            // id = 4*y + x
    parameter [31:0] SEED    = 32'h1,
    parameter        QPTR_W  = 2                // queue depth = 2**QPTR_W (default 4)
) (
    input  wire        clk,
    input  wire        rst_n,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] now,                      // only now[15:0] is used
    /* verilator lint_on UNUSEDSIGNAL */

    // run-time configuration
    input  wire        gen_enable,
    input  wire [15:0] rate,
    input  wire [2:0]  pattern,
    input  wire [3:0]  hot_node,
    input  wire [7:0]  hot_pct,
    input  wire [31:0] max_packets,              // 0 = unlimited

    // link to the router Local input
    output wire [15:0] inj_data,
    output wire [1:0]  inj_type,
    output wire        inj_valid,
    input  wire        inj_ready,

    // transition protocol
    input  wire        inject_block_req,
    output wire        inject_block_ack,
    output wire        src_empty,

    // observation
    output wire        create_pulse,
    output wire [3:0]  create_dst,
    output wire [7:0]  create_seq,
    output wire        flit_accept,
    output reg  [31:0] created,
    output reg  [31:0] dropped,
    output reg  [31:0] injected,
    output wire [QPTR_W:0] q_count
);

    localparam QDEPTH = (1 << QPTR_W);

    // ------------------------------------------------------------------
    // PRNG
    // ------------------------------------------------------------------
    reg [31:0] rnd;
    wire [31:0] rx1 = rnd ^ (rnd << 13);
    wire [31:0] rx2 = rx1 ^ (rx1 >> 17);
    wire [31:0] rx3 = rx2 ^ (rx2 << 5);

    // x mod 15 of a 16-bit value via nibble sum (result 0..14)
    function [3:0] mod15;
        input [15:0] v;
        reg [6:0] s;
        begin
            s = {3'b000, v[3:0]} + {3'b000, v[7:4]} + {3'b000, v[11:8]} + {3'b000, v[15:12]};   // 0..60
            if (s >= 7'd45) s = s - 7'd45;
            if (s >= 7'd30) s = s - 7'd30;
            if (s >= 7'd15) s = s - 7'd15;
            mod15 = s[3:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // destination selection
    // ------------------------------------------------------------------
    wire [3:0] uni_off = mod15(rnd[31:16]) + 4'd1;              // 1..15
    wire [3:0] dst_uni = NODE ^ uni_off;                        // any node but self
    wire       hot_hit = (rnd[31:24] < hot_pct) && (NODE != hot_node);
    wire [1:0] nb_x    = NODE[1:0] + 2'd1;                  // wraps 3 -> 0

    reg [3:0] dst_sel;
    reg       dst_ok;
    always @(*) begin
        dst_sel = dst_uni;
        dst_ok  = 1'b1;
        case (pattern)
            3'd1: dst_sel = hot_hit ? hot_node : dst_uni;
            3'd2: begin
                dst_sel = {NODE[1:0], NODE[3:2]};
                dst_ok  = (dst_sel != NODE);
            end
            3'd3: dst_sel = ~NODE;
            3'd4: dst_sel = {NODE[3:2], nb_x};
            default: dst_sel = dst_uni;
        endcase
    end

    wire want = gen_enable && (rnd[15:0] < rate) &&
                ((max_packets == 32'd0) || (created < max_packets)) && dst_ok;

    // ------------------------------------------------------------------
    // queue of created packets: {dst[3:0], seq[7:0], ts[15:0]}
    // ------------------------------------------------------------------
    reg [27:0]       qmem [0:QDEPTH-1];
    reg [QPTR_W-1:0] q_wr, q_rd;
    reg [QPTR_W:0]   q_cnt;
    reg [7:0]        seq_ctr;

    wire q_full  = (q_cnt == QDEPTH);
    wire q_empty = (q_cnt == 0);
    wire do_create = want && !q_full;

    assign q_count      = q_cnt;
    assign create_pulse = do_create;
    assign create_dst   = dst_sel;
    assign create_seq   = seq_ctr;

    // ------------------------------------------------------------------
    // injection FSM
    // ------------------------------------------------------------------
    reg        busy;
    reg [1:0]  f;
    reg [3:0]  cur_dst;
    reg [7:0]  cur_seq;
    reg [15:0] cur_ts_c;
    reg [15:0] cur_ts_i;

    wire do_start = !busy && !q_empty && !inject_block_req;
    wire [27:0] q_head = qmem[q_rd];

    wire [15:0] hdr_word = {cur_dst[1:0], cur_dst[3:2], NODE[1:0], NODE[3:2], cur_seq};
    wire [15:0] tail_word = hdr_word ^ cur_ts_c ^ cur_ts_i ^ 16'hC3A5;

    reg [15:0] d_r;
    reg [1:0]  t_r;
    always @(*) begin
        case (f)
            2'd0:    begin d_r = hdr_word;  t_r = `HY_FT_HEADER; end
            2'd1:    begin d_r = cur_ts_c;  t_r = `HY_FT_BODY;   end
            2'd2:    begin d_r = cur_ts_i;  t_r = `HY_FT_BODY;   end
            default: begin d_r = tail_word; t_r = `HY_FT_TAIL;   end
        endcase
    end

    assign inj_valid = busy;
    assign inj_data  = busy ? d_r : 16'h0000;
    assign inj_type  = busy ? t_r : 2'b00;
    assign flit_accept = busy & inj_ready;

    assign src_empty        = !busy;
    assign inject_block_ack = inject_block_req & !busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            rnd      <= (SEED ^ ({28'd0, NODE} * 32'h9E3779B1) ^ 32'h2545F491) | 32'h1;
            q_wr     <= {QPTR_W{1'b0}};
            q_rd     <= {QPTR_W{1'b0}};
            q_cnt    <= {(QPTR_W+1){1'b0}};
            seq_ctr  <= 8'd0;
            created  <= 32'd0;
            dropped  <= 32'd0;
            injected <= 32'd0;
            busy     <= 1'b0;
            f        <= 2'd0;
            cur_dst  <= 4'd0;
            cur_seq  <= 8'd0;
            cur_ts_c <= 16'd0;
            cur_ts_i <= 16'd0;
        end else begin
            rnd <= rx3;

            // creation
            if (do_create) begin
                qmem[q_wr] <= {dst_sel, seq_ctr, now[15:0]};
                q_wr    <= q_wr + 1'b1;
                seq_ctr <= seq_ctr + 8'd1;
                created <= created + 32'd1;
            end else if (want && q_full) begin
                dropped <= dropped + 32'd1;
            end

            // injection
            if (do_start) begin
                cur_dst  <= q_head[27:24];
                cur_seq  <= q_head[23:16];
                cur_ts_c <= q_head[15:0];
                cur_ts_i <= now[15:0] + 16'd1;       // valid is first offered next cycle
                q_rd     <= q_rd + 1'b1;
                busy     <= 1'b1;
                f        <= 2'd0;
            end else if (busy && inj_ready) begin
                if (f == 2'd3) begin
                    busy     <= 1'b0;
                    injected <= injected + 32'd1;
                end else begin
                    f <= f + 2'd1;
                end
            end

            // queue occupancy
            case ({do_create, do_start})
                2'b10:   q_cnt <= q_cnt + 1'b1;
                2'b01:   q_cnt <= q_cnt - 1'b1;
                default: q_cnt <= q_cnt;
            endcase
        end
    end

endmodule
