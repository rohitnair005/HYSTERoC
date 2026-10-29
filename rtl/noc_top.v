// =============================================================================
// noc_top.v : 4x4 mesh of noc_router + global control (spec 9.3)
//
//   16 x noc_router (node n = 4*y + x, x grows East, y grows South)
//   global max of the 16 EWMA estimates and of the 16 unfiltered congestion
//   values -> hysteresis_controller -> transition_controller (the ONLY writer of
//   active_mode) -> broadcast to every router; drain_detector.
//
// Link wiring. A flit leaving router A through output port q enters the
// neighbour B through the OPPOSITE input port (N<->S, E<->W):
//     out N of (x,y) -> in S of (x,y-1)       out S of (x,y) -> in N of (x,y+1)
//     out E of (x,y) -> in W of (x+1,y)       out W of (x,y) -> in E of (x-1,y)
//   in_ready of the receiving FIFO drives out_ready of the sender (registered
//   state only, no combinational loop). Boundary inputs are tied to valid = 0,
//   boundary out_ready = 0.
// Sideband: router A receives, for each direction d, the CURRENT occupancy of the
//   neighbour FIFO that would receive its flits (neighbour input port opposite(d));
//   the router registers it (one cycle old, DECISIONS 36). nbr_avail = 0 at the
//   mesh boundary.
//
// Local ports (all 16 nodes, flattened, node n at [16n+:16] / [2n+:2] / [n]):
//   inj_*  source -> router Local input  (valid/ready)
//   ej_*   router Local output -> sink   (valid/ready; ej_ready must not depend
//                                         combinationally on ej_valid, DECISIONS 38)
// Source side of the transition protocol:
//   inject_block_req   to all sources
//   inject_block_ack   one per source (level)
//   src_empty          one per source: no admitted packet queued and no injection
//                      in progress (DECISIONS 41)
// link_active[n] = any router out_valid at node n OR inj_valid[n].
//
// Configuration parameters (spec 12.1):
//   XY_ONLY=1       reference: req_mode forced to XY, the controller never leaves
//                   RUN (no transitions)
//   DUAL/USE_EWMA/THIGH/TLOW/THRESH_SINGLE   hysteresis_controller variants
//   WATCHDOG_LIMIT_CYCLES, POST_RESUME_MASK_CYCLES, ENABLE_STATS, DRAIN_CONFIRM
// Verilog-2001.
// =============================================================================
`include "hysteroc_defs.vh"

module noc_top #(
    parameter       XY_ONLY                  = 0,
    parameter       DUAL                     = 1,
    parameter       USE_EWMA                 = 1,
    parameter [7:0] THIGH                    = `HY_THIGH_DEFAULT,
    parameter [7:0] TLOW                     = `HY_TLOW_DEFAULT,
    parameter [7:0] THRESH_SINGLE            = `HY_BASE_THRESH,
    parameter       SAMPLE_PERIOD            = `HY_SAMPLE_PERIOD_DEFAULT,
    parameter       WATCHDOG_LIMIT_CYCLES    = `HY_WATCHDOG_LIMIT_DEFAULT,
    parameter       POST_RESUME_MASK_CYCLES  = `HY_POST_RESUME_MASK_DEFAULT,
    parameter       ENABLE_STATS             = 1,
    parameter       DRAIN_CONFIRM            = 2
) (
    input  wire          clk,
    input  wire          rst_n,

    // local injection (source -> router)
    input  wire [255:0]  inj_data,
    input  wire [31:0]   inj_type,
    input  wire [15:0]   inj_valid,
    output wire [15:0]   inj_ready,

    // local ejection (router -> sink)
    output wire [255:0]  ej_data,
    output wire [31:0]   ej_type,
    output wire [15:0]   ej_valid,
    input  wire [15:0]   ej_ready,

    // transition protocol with the sources
    output wire          inject_block_req,
    input  wire [15:0]   inject_block_ack,
    input  wire [15:0]   src_empty,

    // global status
    output wire          active_mode,
    output wire          req_mode,
    output wire [7:0]    global_congestion,     // max of the 16 EWMA
    output wire [7:0]    global_raw,            // max of the 16 unfiltered values
    output wire          transition_busy,
    output wire          drain_timeout,
    output wire          network_drained,
    output wire [2:0]    ctrl_state,
    output wire [15:0]   router_empty,
    output wire [239:0]  fifo_occ_all,          // router n at [15n+:15]
    output wire [127:0]  ewma_all,              // router n at [8n+:8]
    output wire          proto_err_any,
    output wire          alloc_err_any,

    // transition statistics (zero when ENABLE_STATS = 0)
    output wire [31:0]   cycle_cnt,
    output wire [31:0]   tr_blocked,
    output wire [31:0]   tr_ackwait,
    output wire [31:0]   tr_drain,
    output wire [31:0]   tot_blocked,
    output wire [31:0]   tot_ackwait,
    output wire [31:0]   tot_drain,
    output wire [31:0]   transitions,
    output wire [31:0]   t_block,
    output wire [31:0]   t_ack,
    output wire [31:0]   t_drained,
    output wire [31:0]   t_switch,
    output wire [31:0]   t_resume
);

    // ------------------------------------------------------------------
    // router interconnect buses (node n slices)
    // ------------------------------------------------------------------
    wire [16*80-1:0] r_in_data,  r_out_data;
    wire [16*10-1:0] r_in_type,  r_out_type;
    wire [16*5-1:0]  r_in_valid, r_out_valid, r_in_ready, r_out_ready;
    wire [16*12-1:0] r_nbr_occ;
    wire [16*4-1:0]  r_nbr_avail;
    wire [16*15-1:0] r_fifo_occ;
    wire [16*8-1:0]  r_ewma, r_cong;
    wire [15:0]      r_empty, r_perr, r_aerr;
    wire [16*3-1:0]  r_maxocc_unused;

    wire ewma_enable, hys_enable;

    genvar gx, gy;
    generate
        for (gy = 0; gy < 4; gy = gy + 1) begin : g_y
            for (gx = 0; gx < 4; gx = gx + 1) begin : g_x
                localparam N  = 4*gy + gx;
                localparam NN = (gy > 0) ? 4*(gy-1) + gx : 0;   // north neighbour id
                localparam NS = (gy < 3) ? 4*(gy+1) + gx : 0;
                localparam NE = (gx < 3) ? 4*gy + gx + 1 : 0;
                localparam NW = (gx > 0) ? 4*gy + gx - 1 : 0;

                // availability: [0]=N [1]=S [2]=E [3]=W
                assign r_nbr_avail[4*N +: 4] = {(gx > 0), (gx < 3), (gy < 3), (gy > 0)};

                // ---- inputs: port N (0) from north neighbour's output S (1) ----
                if (gy > 0) begin : g_inN
                    assign r_in_data [80*N +: 16]  = r_out_data[80*NN + 16*1 +: 16];
                    assign r_in_type [10*N +: 2]   = r_out_type[10*NN + 2*1 +: 2];
                    assign r_in_valid[5*N + 0]     = r_out_valid[5*NN + 1];
                    assign r_out_ready[5*NN + 1]   = r_in_ready[5*N + 0];
                    assign r_nbr_occ[12*N + 0 +: 3] = r_fifo_occ[15*NN + 3*1 +: 3];  // our N neighbour's S FIFO
                end else begin : g_inN0
                    assign r_in_data [80*N +: 16]  = 16'h0;
                    assign r_in_type [10*N +: 2]   = 2'b00;
                    assign r_in_valid[5*N + 0]     = 1'b0;
                    assign r_nbr_occ[12*N + 0 +: 3] = 3'd0;
                end
                // ---- port S (1) from south neighbour's output N (0) ----
                if (gy < 3) begin : g_inS
                    assign r_in_data [80*N + 16 +: 16] = r_out_data[80*NS + 16*0 +: 16];
                    assign r_in_type [10*N + 2 +: 2]   = r_out_type[10*NS + 2*0 +: 2];
                    assign r_in_valid[5*N + 1]         = r_out_valid[5*NS + 0];
                    assign r_out_ready[5*NS + 0]       = r_in_ready[5*N + 1];
                    assign r_nbr_occ[12*N + 3 +: 3]    = r_fifo_occ[15*NS + 3*0 +: 3];
                end else begin : g_inS0
                    assign r_in_data [80*N + 16 +: 16] = 16'h0;
                    assign r_in_type [10*N + 2 +: 2]   = 2'b00;
                    assign r_in_valid[5*N + 1]         = 1'b0;
                    assign r_nbr_occ[12*N + 3 +: 3]    = 3'd0;
                end
                // ---- port E (2) from east neighbour's output W (3) ----
                if (gx < 3) begin : g_inE
                    assign r_in_data [80*N + 32 +: 16] = r_out_data[80*NE + 16*3 +: 16];
                    assign r_in_type [10*N + 4 +: 2]   = r_out_type[10*NE + 2*3 +: 2];
                    assign r_in_valid[5*N + 2]         = r_out_valid[5*NE + 3];
                    assign r_out_ready[5*NE + 3]       = r_in_ready[5*N + 2];
                    assign r_nbr_occ[12*N + 6 +: 3]    = r_fifo_occ[15*NE + 3*3 +: 3];
                end else begin : g_inE0
                    assign r_in_data [80*N + 32 +: 16] = 16'h0;
                    assign r_in_type [10*N + 4 +: 2]   = 2'b00;
                    assign r_in_valid[5*N + 2]         = 1'b0;
                    assign r_nbr_occ[12*N + 6 +: 3]    = 3'd0;
                end
                // ---- port W (3) from west neighbour's output E (2) ----
                if (gx > 0) begin : g_inW
                    assign r_in_data [80*N + 48 +: 16] = r_out_data[80*NW + 16*2 +: 16];
                    assign r_in_type [10*N + 6 +: 2]   = r_out_type[10*NW + 2*2 +: 2];
                    assign r_in_valid[5*N + 3]         = r_out_valid[5*NW + 2];
                    assign r_out_ready[5*NW + 2]       = r_in_ready[5*N + 3];
                    assign r_nbr_occ[12*N + 9 +: 3]    = r_fifo_occ[15*NW + 3*2 +: 3];
                end else begin : g_inW0
                    assign r_in_data [80*N + 48 +: 16] = 16'h0;
                    assign r_in_type [10*N + 6 +: 2]   = 2'b00;
                    assign r_in_valid[5*N + 3]         = 1'b0;
                    assign r_nbr_occ[12*N + 9 +: 3]    = 3'd0;
                end

                // ---- boundary outputs never transfer ----
                if (gy == 0) begin : g_oN0 assign r_out_ready[5*N + 0] = 1'b0; end
                if (gy == 3) begin : g_oS0 assign r_out_ready[5*N + 1] = 1'b0; end
                if (gx == 3) begin : g_oE0 assign r_out_ready[5*N + 2] = 1'b0; end
                if (gx == 0) begin : g_oW0 assign r_out_ready[5*N + 3] = 1'b0; end

                // ---- local port ----
                assign r_in_data [80*N + 64 +: 16] = inj_data[16*N +: 16];
                assign r_in_type [10*N + 8 +: 2]   = inj_type[2*N +: 2];
                assign r_in_valid[5*N + 4]         = inj_valid[N];
                assign inj_ready[N]                = r_in_ready[5*N + 4];
                assign ej_data[16*N +: 16]         = r_out_data[80*N + 64 +: 16];
                assign ej_type[2*N +: 2]           = r_out_type[10*N + 8 +: 2];
                assign ej_valid[N]                 = r_out_valid[5*N + 4];
                assign r_out_ready[5*N + 4]        = ej_ready[N];

                noc_router #(.SAMPLE_PERIOD(SAMPLE_PERIOD)) u_router (
                    .clk(clk), .rst_n(rst_n),
                    .x_coord(gx[1:0]), .y_coord(gy[1:0]),
                    .active_mode(active_mode), .ewma_enable(ewma_enable),
                    .in_data(r_in_data[80*N +: 80]), .in_type(r_in_type[10*N +: 10]),
                    .in_valid(r_in_valid[5*N +: 5]), .in_ready(r_in_ready[5*N +: 5]),
                    .out_data(r_out_data[80*N +: 80]), .out_type(r_out_type[10*N +: 10]),
                    .out_valid(r_out_valid[5*N +: 5]), .out_ready(r_out_ready[5*N +: 5]),
                    .nbr_occ_in(r_nbr_occ[12*N +: 12]), .nbr_avail(r_nbr_avail[4*N +: 4]),
                    .fifo_occ(r_fifo_occ[15*N +: 15]), .router_empty(r_empty[N]),
                    .ewma_out(r_ewma[8*N +: 8]), .cong_now(r_cong[8*N +: 8]),
                    .max_occ_now(r_maxocc_unused[3*N +: 3]),
                    .proto_err(r_perr[N]), .alloc_err(r_aerr[N])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // global aggregation: max of 16 values (spec 6.5)
    // ------------------------------------------------------------------
    function [7:0] max16;
        input [127:0] v;
        integer k;
        reg [7:0] m;
        begin
            m = 8'd0;
            for (k = 0; k < 16; k = k + 1)
                if (v[8*k +: 8] > m) m = v[8*k +: 8];
            max16 = m;
        end
    endfunction

    assign global_congestion = max16(r_ewma);
    assign global_raw        = max16(r_cong);

    // ------------------------------------------------------------------
    // hysteresis -> transition controller
    // ------------------------------------------------------------------
    wire hys_req;
    wire mcr_unused;

    hysteresis_controller #(.DUAL(DUAL), .USE_EWMA(USE_EWMA), .THIGH(THIGH), .TLOW(TLOW),
                            .THRESH_SINGLE(THRESH_SINGLE)) u_hys (
        .clk(clk), .rst_n(rst_n), .enable(hys_enable),
        .value_ewma(global_congestion), .value_raw(global_raw), .active_mode(active_mode),
        .req_mode(hys_req), .mode_change_request(mcr_unused)
    );

    assign req_mode = (XY_ONLY != 0) ? `HY_MODE_XY : hys_req;

    // ------------------------------------------------------------------
    // drain detection
    // ------------------------------------------------------------------
    wire [15:0] link_active;
    genvar gn;
    generate
        for (gn = 0; gn < 16; gn = gn + 1) begin : g_la
            assign link_active[gn] = (|r_out_valid[5*gn +: 5]) | inj_valid[gn];
        end
    endgenerate

    wire drained_now_unused;
    drain_detector #(.N(16), .CONFIRM(DRAIN_CONFIRM)) u_drain (
        .clk(clk), .rst_n(rst_n),
        .router_empty(r_empty), .src_empty(src_empty), .link_active(link_active),
        .drained_now(drained_now_unused), .network_drained(network_drained)
    );

    transition_controller #(.N_SRC(16), .WATCHDOG_LIMIT_CYCLES(WATCHDOG_LIMIT_CYCLES),
                            .POST_RESUME_MASK_CYCLES(POST_RESUME_MASK_CYCLES),
                            .ENABLE_STATS(ENABLE_STATS)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .req_mode(req_mode), .inject_block_ack(inject_block_ack), .network_drained(network_drained),
        .active_mode(active_mode), .inject_block_req(inject_block_req),
        .ewma_enable(ewma_enable), .hys_enable(hys_enable),
        .transition_busy(transition_busy), .drain_timeout(drain_timeout),
        .state_o(ctrl_state), .target_mode_o(),
        .cycle_cnt(cycle_cnt), .tr_blocked(tr_blocked), .tr_ackwait(tr_ackwait), .tr_drain(tr_drain),
        .tot_blocked(tot_blocked), .tot_ackwait(tot_ackwait), .tot_drain(tot_drain),
        .transitions(transitions),
        .t_block(t_block), .t_ack(t_ack), .t_drained(t_drained), .t_switch(t_switch), .t_resume(t_resume)
    );

    assign router_empty  = r_empty;
    assign fifo_occ_all  = r_fifo_occ;
    assign ewma_all      = r_ewma;
    assign proto_err_any = |r_perr;
    assign alloc_err_any = |r_aerr;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_top = &{1'b0, mcr_unused, drained_now_unused, r_maxocc_unused};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
