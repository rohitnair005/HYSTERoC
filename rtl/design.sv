// =============================================================================
// design.sv : HYSTERoC RTL file list (include-dir based).
// Compile with:  -I rtl/common -I rtl/router -I rtl/control -I rtl/top -I rtl/bench
// bench/ modules are simulation-only stimulus/check blocks and are NOT meant
// for synthesis; see sim/hysteroc.f for the full list.
// =============================================================================
`include "hysteroc.vh"
`include "input_fifo.v"
`include "ewma_filter.v"
`include "congestion_estimator.v"
`include "hysteresis_controller.v"
`include "round_robin_arbiter.v"
`include "route_compute.v"
`include "route_select.v"
`include "packet_tracker.v"
`include "switch_allocator.v"
`include "crossbar.v"
`include "noc_router.v"
`include "drain_detector.v"
`include "transition_controller.v"
`include "mode_switch_direct.v"
`include "noc_top.v"
