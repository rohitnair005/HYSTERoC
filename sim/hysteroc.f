# =============================================================================
# sim/hysteroc.f : HYSTERoC RTL file list (synthesis + simulation)
# Usage: vcs -f sim/hysteroc.f  |  xrun -f sim/hysteroc.f  |  iverilog -f sim/hysteroc.f
# Include dirs must be passed too: -I rtl/common
# NOTE: bench/ modules (traffic_generator, packet_sink, performance_monitor)
# are simulation-only and are excluded from synthesis builds.
# =============================================================================
+incdir+rtl/common

rtl/router/input_fifo.v
rtl/control/ewma_filter.v
rtl/control/congestion_estimator.v
rtl/control/hysteresis_controller.v
rtl/router/round_robin_arbiter.v
rtl/router/route_compute.v
rtl/router/route_select.v
rtl/router/packet_tracker.v
rtl/router/switch_allocator.v
rtl/router/crossbar.v
rtl/router/noc_router.v
rtl/control/drain_detector.v
rtl/control/transition_controller.v
rtl/control/mode_switch_direct.v
rtl/top/noc_top.v
