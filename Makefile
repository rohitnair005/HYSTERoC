# =============================================================================
# Makefile : HYSTERoC convenience targets
#
#   make lint       elaborate the full design with iverilog (no licence needed)
#   make sim-rtl    same, via the sim/ file lists (needs iverilog)
#   make docs       check that every README link resolves (links + headings)
#   make help       list targets
#   make clean      remove build artifacts
#
# Simulator runs (UVM) go through scripts/run_uvm.sh (needs VCS/Xcelium/Questa).
# =============================================================================

SHELL := /bin/bash
INCDIRS = -Irtl/common -Irtl/router -Irtl/control -Irtl/top -Irtl/bench
RTL = rtl/router/input_fifo.v rtl/control/ewma_filter.v rtl/control/congestion_estimator.v \
      rtl/control/hysteresis_controller.v rtl/router/round_robin_arbiter.v rtl/router/route_compute.v \
      rtl/router/route_select.v rtl/router/packet_tracker.v rtl/router/switch_allocator.v \
      rtl/router/crossbar.v rtl/router/noc_router.v rtl/control/drain_detector.v \
      rtl/control/transition_controller.v rtl/control/mode_switch_direct.v rtl/top/noc_top.v \
      rtl/bench/performance_monitor.v rtl/bench/traffic_generator.v rtl/bench/packet_sink.v

.PHONY: all lint sim-rtl docs help clean

all: lint

lint: ## elaborate the full design (synthesisable + bench) with iverilog
	iverilog -g2005-sv $(INCDIRS) -o /tmp/hysteroc.vvp $(RTL)

sim-rtl: ## elaboration via sim/ file lists (iverilog only)
	iverilog -g2005-sv $(INCDIRS) -o /tmp/hysteroc.f.vvp @sim/hysteroc.f @sim/hysteroc_bench.f

docs: ## check README/docs relative links resolve
	python3 scripts/check_links.py

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

clean: ## remove build artifacts
	rm -rf sim/run /tmp/hysteroc.vvp /tmp/hysteroc.f.vvp
	find . -name '*.vvp' -not -path './.git/*' -delete
	find . -name '*.fsdb' -not -path './.git/*' -delete
