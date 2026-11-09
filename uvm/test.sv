// =============================================================================
// test.sv : testbench top. Includes the tests package, builds clock/reset, the DUT
// (noc_top), the interface, the assertion module and starts the UVM test.
//   - DUT parameters are top-level parameters of this module, so that one compiled
//     snapshot can be elaborated for another DUT configuration (xsim -generic_top).
//     They are echoed to the test through the config_db.
//   - reset:  rst_n = por_n & vif.test_rst_n   (a test may reset the network mid-run)
// =============================================================================
`timescale 1ns/1ps
`include "uvm_macros.svh"
`include "hysteroc_defs.vh"
`include "hy_tests_pkg.sv"

module test;

    import uvm_pkg::*;
    import hy_pkg::*;
    import hy_tests_pkg::*;

    parameter       XY_ONLY                 = 0;
    parameter       DUAL                    = 1;
    parameter       USE_EWMA                = 1;
  parameter [7:0] THIGH                   = 8'd160;
  parameter [7:0] TLOW                    = 8'd96;
  parameter [7:0] THRESH_SINGLE           = 8'd128;
    parameter       SAMPLE_PERIOD           = 1;
    parameter       WATCHDOG_LIMIT_CYCLES   = 1000;
    parameter       POST_RESUME_MASK_CYCLES = 0;
    parameter       ENABLE_STATS            = 1;
    parameter       DRAIN_CONFIRM           = 2;
    parameter       DET_VARIANT             = 2;     // no-drain only: 0 oe_fixed (v2), 1 oe_par source-parity (v3)
    parameter       SWITCH_POLICY           = 1;     // 0 drain-and-switch (v1), 1 no-drain (deterministic <-> adaptive Odd-Even)
  parameter ADAPT_MARGIN = 2;

    // ---------------------------------------------------------- clock and reset
    logic clk = 1'b0;
    logic por_n = 1'b0;
    wire  rst_n;
    always #5 clk = ~clk;                       // 100 MHz
    initial begin
        por_n = 1'b0;
        repeat (8) @(posedge clk);
        por_n <= 1'b1;
    end

    hy_if vif (clk, rst_n);
    assign rst_n = por_n & vif.test_rst_n;

    // ---------------------------------------------------------- DUT
    noc_top #(
        .XY_ONLY(XY_ONLY), .DUAL(DUAL), .USE_EWMA(USE_EWMA),
        .THIGH(THIGH), .TLOW(TLOW), .THRESH_SINGLE(THRESH_SINGLE),
        .SAMPLE_PERIOD(SAMPLE_PERIOD), .WATCHDOG_LIMIT_CYCLES(WATCHDOG_LIMIT_CYCLES),
        .POST_RESUME_MASK_CYCLES(POST_RESUME_MASK_CYCLES),
        .ENABLE_STATS(ENABLE_STATS), .DRAIN_CONFIRM(DRAIN_CONFIRM),
      .SWITCH_POLICY(SWITCH_POLICY), .DET_VARIANT(DET_VARIANT),
      .ADAPT_MARGIN(ADAPT_MARGIN)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .inj_data(vif.inj_data), .inj_type(vif.inj_type), .inj_valid(vif.inj_valid), .inj_ready(vif.inj_ready),
        .ej_data(vif.ej_data),   .ej_type(vif.ej_type),   .ej_valid(vif.ej_valid),   .ej_ready(vif.ej_ready),
        .inject_block_req(vif.inject_block_req), .inject_block_ack(vif.inject_block_ack), .src_empty(vif.src_empty),
        .active_mode(vif.active_mode), .req_mode(vif.req_mode),
        .global_congestion(vif.global_congestion), .global_raw(vif.global_raw),
        .transition_busy(vif.transition_busy), .drain_timeout(vif.drain_timeout),
        .network_drained(vif.network_drained), .ctrl_state(vif.ctrl_state),
        .router_empty(vif.router_empty), .fifo_occ_all(vif.fifo_occ_all), .ewma_all(vif.ewma_all),
        .proto_err_any(vif.proto_err_any), .alloc_err_any(vif.alloc_err_any),
        .cycle_cnt(vif.cycle_cnt), .tr_blocked(vif.tr_blocked), .tr_ackwait(vif.tr_ackwait), .tr_drain(vif.tr_drain),
        .tot_blocked(vif.tot_blocked), .tot_ackwait(vif.tot_ackwait), .tot_drain(vif.tot_drain),
        .transitions(vif.transitions),
        .t_block(vif.t_block), .t_ack(vif.t_ack), .t_drained(vif.t_drained), .t_switch(vif.t_switch), .t_resume(vif.t_resume)
    );

    // ---------------------------------------------------------- router output taps for the hop monitor
    assign vif.link_out_data  = dut.r_out_data;
    assign vif.link_out_type  = dut.r_out_type;
    assign vif.link_out_valid = dut.r_out_valid;
    assign vif.link_out_ready = dut.r_out_ready;
    initial vif.link_taps = 1'b1;

    // ---------------------------------------------------------- concurrent assertions
    hy_sva #(.SWITCH_POLICY(SWITCH_POLICY)) sva (vif);

    // ---------------------------------------------------------- start UVM
    initial begin
        uvm_config_db #(virtual hy_if)::set(null, "uvm_test_top", "vif", vif);
        uvm_config_db #(int)::set(null, "uvm_test_top", "XY_ONLY", XY_ONLY);
        uvm_config_db #(int)::set(null, "uvm_test_top", "DUAL", DUAL);
        uvm_config_db #(int)::set(null, "uvm_test_top", "USE_EWMA", USE_EWMA);
        uvm_config_db #(int)::set(null, "uvm_test_top", "THIGH", int'(THIGH));
        uvm_config_db #(int)::set(null, "uvm_test_top", "TLOW", int'(TLOW));
        uvm_config_db #(int)::set(null, "uvm_test_top", "THRESH_SINGLE", int'(THRESH_SINGLE));
        uvm_config_db #(int)::set(null, "uvm_test_top", "SAMPLE_PERIOD", SAMPLE_PERIOD);
        uvm_config_db #(int)::set(null, "uvm_test_top", "WATCHDOG_LIMIT_CYCLES", WATCHDOG_LIMIT_CYCLES);
        uvm_config_db #(int)::set(null, "uvm_test_top", "POST_RESUME_MASK_CYCLES", POST_RESUME_MASK_CYCLES);
        uvm_config_db #(int)::set(null, "uvm_test_top", "ENABLE_STATS", ENABLE_STATS);
        uvm_config_db #(int)::set(null, "uvm_test_top", "DRAIN_CONFIRM", DRAIN_CONFIRM);
        uvm_config_db #(int)::set(null, "uvm_test_top", "SWITCH_POLICY", SWITCH_POLICY);
        uvm_config_db #(int)::set(null, "uvm_test_top", "DET_VARIANT", DET_VARIANT);
        run_test();
    end

endmodule
