// =============================================================================
// hy_if.sv : the one interface between the UVM environment and noc_top.
// Connect every port of noc_top to the member of the same name (tb top does it).
//
// Timing rule used by every UVM component (no clocking blocks, simulator
// independent): DRIVE with non-blocking assignments right after @(posedge clk);
// SAMPLE in the active region of @(posedge clk). Samples then equal what the
// DUT flip-flops see at that edge.
//
// Source side of the transition protocol (DECISIONS 41, 56). The 16 sources are
// modelled here so they can be driven bit by bit by 16 independent drivers:
//     src_empty[n]         = !(src_busy[n] | src_force_busy[n])
//     inject_block_ack[n]  = inject_block_req & src_empty[n]
// `src_busy[n]` is set by the inject driver of node n while a started packet is
// not yet fully accepted. `src_force_busy[n]` is a test knob (a source that never
// acknowledges, used to provoke the watchdog).
// =============================================================================
interface hy_if (input logic clk, input logic rst_n);

    // ------------------------------------------------ local ports (flat, node n at [16n+:16], [2n+:2], [n])
    logic [255:0] inj_data;    logic [31:0] inj_type;    logic [15:0] inj_valid;    logic [15:0] inj_ready;
    logic [255:0] ej_data;     logic [31:0] ej_type;     logic [15:0] ej_valid;     logic [15:0] ej_ready;

    // ------------------------------------------------ transition protocol
    logic        inject_block_req;
    logic [15:0] inject_block_ack;
    logic [15:0] src_empty;
    logic [15:0] src_busy;
    logic [15:0] src_force_busy;

    assign src_empty        = ~(src_busy | src_force_busy);
    assign inject_block_ack = {16{inject_block_req}} & src_empty;

    // ------------------------------------------------ reset request from a test
    // The tb top builds the reset as   assign rst_n = por_n & vif.test_rst_n;   A test pulls
    // test_rst_n low for a few cycles to reset the whole network in the middle of traffic.
    logic        test_rst_n = 1'b1;

    // ------------------------------------------------ status outputs of noc_top
    logic        active_mode, req_mode, transition_busy, drain_timeout, network_drained;
    logic [7:0]  global_congestion, global_raw;
    logic [2:0]  ctrl_state;
    logic [15:0] router_empty;
    logic [239:0] fifo_occ_all;
    logic [127:0] ewma_all;
    logic        proto_err_any, alloc_err_any;
    logic [31:0] cycle_cnt, tr_blocked, tr_ackwait, tr_drain, tot_blocked, tot_ackwait, tot_drain, transitions;
    logic [31:0] t_block, t_ack, t_drained, t_switch, t_resume;

    // ------------------------------------------------ router output taps (hop monitor)
    // The tb top connects these to the router-output buses inside noc_top (hierarchical
    // references) and sets link_taps = 1. Router n, port p (N0 S1 E2 W3 L4):
    //   valid/ready [5n+p], data [80n+16p +: 16], type [10n+2p +: 2]
    logic [1279:0] link_out_data;
    logic [159:0]  link_out_type;
    logic [79:0]   link_out_valid;
    logic [79:0]   link_out_ready;
    bit            link_taps = 0;

    // ------------------------------------------------ assertion failures counted by hy_sva (checked at the end of the test)
    int unsigned sva_errors = 0;
    function automatic void sva_hit();  sva_errors = sva_errors + 1;  endfunction

    // ------------------------------------------------ testbench time base
    int unsigned cyc;                       // cycles since reset was released
    always @(posedge clk) begin
        if (!rst_n) cyc <= 0;
        else        cyc <= cyc + 1;
    end

    // ------------------------------------------------ safe idle values at time 0
    initial begin
        inj_data = '0; inj_type = '0; inj_valid = '0;
        ej_ready = '0; src_busy = '0; src_force_busy = '0;
    end

    // ------------------------------------------------ small helpers used by components
    function automatic logic [15:0] inj_word(int n);  return inj_data[16*n +: 16];  endfunction
    function automatic logic [1:0]  inj_ty(int n);    return inj_type[2*n +: 2];    endfunction
    function automatic logic [15:0] ej_word(int n);   return ej_data[16*n +: 16];   endfunction
    function automatic logic [1:0]  ej_ty(int n);     return ej_type[2*n +: 2];     endfunction

endinterface
