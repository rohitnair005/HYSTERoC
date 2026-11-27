#!/usr/bin/env bash
# =============================================================================
# scripts/run_uvm.sh : HYSTERoC UVM driver (VCS / Xcelium / Questa)
#
# Compiles sim/hysteroc.f (+ bench) and the UVM testbench (sim/hysteroc_tb.f),
# then runs one (or all) of the 19 tests in tb/tests/hy_tests_pkg.sv.
#
# Usage:
#   ./scripts/run_uvm.sh --sim vcs    --test hy_smoke_test
#   ./scripts/run_uvm.sh --sim xrun   --test hy_oscillate_test --load 400 --cycles 300
#   ./scripts/run_uvm.sh --sim questa --test hy_nodrain_test --policy 1 --det 1
#   ./scripts/run_uvm.sh --sim xrun   --campaign        # everything, summary
#
# DUT options (echoed to the test via UVM config_db; see tb/env/test.sv):
#   --policy 0|1     SWITCH_POLICY   0 drain-and-switch, 1 no-drain (default 0)
#   --det 0|1|2      DET_VARIANT     0 oe_fixed, 1 oe_par, 2 oe_x21 (default 0)
#   --dual 0|1       DUAL            1 dual threshold (default 1)
#   --ewma 0|1       USE_EWMA        1 hysteresis on EWMA value (default 1)
#   --thigh/--tlow   THIGH/TLOW       160 / 96
#   --thresh-single  THRESH_SINGLE    128
#   --xy-only        XY_ONLY=1 (reference point; overrides the rest)
#   --margin N       ADAPT_MARGIN    0 (v6 relative bias)
#   --watchdog/--mask/--sample/--drain-confirm/--stats N/0/1/2/1
#
# Workload plusargs:
#   --load/--cycles/--pat/--timeout   +HY_LOAD=+HY_CYCLES=+HY_PAT=+HY_TIMEOUT=
#   --allpairs                        +HY_ALLPAIRS=1 (zero-load test)
#
# The wrapper never edits the RTL. Simulation output goes to sim/run/<test>/.
# Requires a UVM-capable simulator (VCS, Xcelium or Questa). For an all-open
# check use `make lint`.
#
# Per-simulator parameter-override note (each tool overrides top-level module
# parameters differently; tb/env/test.sv was written so that ONE snapshot can
# be re-elaborated per point, which is exactly these overrides):
#   VCS:     vcs -pvalue test.SWITCH_POLICY=<v> …
#   Xcelium: xrun -top test -generic_top test …   (params are module params
#            of `test`; use -sv -generic_top and the xrun parameter overlay)
#   Questa:  vsim -gSwitch_policy=<v> … (top-level generic)
# As shipped, run_uvm.sh passes the overrides in the simulator's native form
# below; if your tool's generic-override spelling differs, adjust the single
# compile line per simulator. The plusargs are the portable interface.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SIM=vcs; TEST=hy_smoke_test; CAMPAIGN=0
POLICY=0; DET=0; DUAL=1; EWMA=1; THIGH=160; TLOW=96; THRESH_SINGLE=128
XY_ONLY=0; MARGIN=0; WATCHDOG=1000; MASK=0; SAMPLE=1; DRAIN_CONFIRM=2; STATS=1
LOAD=100; CYCLES=5000; PAT=0; TIMEOUT=3000000; ALLPAIRS=0

usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sim)            SIM="$2"; shift 2;;
    --test)           TEST="$2"; shift 2;;
    --campaign)       CAMPAIGN=1; shift;;
    --policy)         POLICY="$2"; shift 2;;
    --det)            DET="$2"; shift 2;;
    --dual)           DUAL="$2"; shift 2;;
    --ewma)           EWMA="$2"; shift 2;;
    --thigh)          THIGH="$2"; shift 2;;
    --tlow)           TLOW="$2"; shift 2;;
    --thresh-single)  THRESH_SINGLE="$2"; shift 2;;
    --xy-only)        XY_ONLY=1; shift;;
    --margin)         MARGIN="$2"; shift 2;;
    --watchdog)       WATCHDOG="$2"; shift 2;;
    --mask)           MASK="$2"; shift 2;;
    --sample)         SAMPLE="$2"; shift 2;;
    --drain-confirm)  DRAIN_CONFIRM="$2"; shift 2;;
    --stats)          STATS="$2"; shift 2;;
    --load)           LOAD="$2"; shift 2;;
    --cycles)         CYCLES="$2"; shift 2;;
    --pat)            PAT="$2"; shift 2;;
    --timeout)        TIMEOUT="$2"; shift 2;;
    --allpairs)       ALLPAIRS=1; shift;;
    -h|--help)        usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

INCDIRS="-Irtl/common -Itb/pkg -Itb/agents -Itb/seq -Itb/env -Itb/tests"
RTL_FILES="rtl/router/input_fifo.v rtl/control/ewma_filter.v rtl/control/congestion_estimator.v rtl/control/hysteresis_controller.v rtl/router/round_robin_arbiter.v rtl/router/route_compute.v rtl/router/route_select.v rtl/router/packet_tracker.v rtl/router/switch_allocator.v rtl/router/crossbar.v rtl/router/noc_router.v rtl/control/drain_detector.v rtl/control/transition_controller.v rtl/control/mode_switch_direct.v rtl/top/noc_top.v"
BENCH_FILES="rtl/bench/performance_monitor.v rtl/bench/traffic_generator.v rtl/bench/packet_sink.v"
TB_FILES="tb/iface/hy_if.sv tb/pkg/hy_pkg.sv tb/tests/hy_tests_pkg.sv tb/env/testbench.sv"

PLUSARGS="+UVM_TESTNAME=$TEST +HY_LOAD=$LOAD +HY_CYCLES=$CYCLES +HY_PAT=$PAT +HY_TIMEOUT=$TIMEOUT +HY_ALLPAIRS=$ALLPAIRS"

# VCS/xrun/questa differ in how top-level parameters of `test` are overridden.
# Each block below is the conventional spelling for that tool; adjust the one
# line there if your installation spells generic override differently. The
# plusargs are identical across simulators.
case "$SIM" in
vcs)
  mkdir -p sim/run/$TEST
  ( cd sim/run/$TEST && vcs -sverilog -timescale=1ns/1ps $INCDIRS \
      $RTL_FILES $BENCH_FILES $TB_FILES \
      -pvalue test.SWITCH_POLICY=$POLICY \
      -pvalue test.DET_VARIANT=$DET \
      -pvalue test.DUAL=$DUAL -pvalue test.USE_EWMA=$EWMA \
      -pvalue test.THIGH=$THIGH -pvalue test.TLOW=$TLOW \
      -pvalue test.THRESH_SINGLE=$THRESH_SINGLE \
      -pvalue test.XY_ONLY=$XY_ONLY -pvalue test.ADAPT_MARGIN=$MARGIN \
      -pvalue test.WATCHDOG_LIMIT_CYCLES=$WATCHDOG \
      -pvalue test.POST_RESUME_MASK_CYCLES=$MASK \
      -pvalue test.SAMPLE_PERIOD=$SAMPLE \
      -pvalue test.DRAIN_CONFIRM=$DRAIN_CONFIRM \
      -pvalue test.ENABLE_STATS=$STATS \
      -o simv 2>&1 | tail -3 \
    && ./simv $PLUSARGS 2>&1 | tee run.log | grep -E "HYSTERoC TEST" || true )
  ;;
xrun)
  mkdir -p sim/run/$TEST
  # Xcelium: -generic_top re-elaborates the top `test` with new parameter values.
  ( cd sim/run/$TEST && xrun -64bit -sv -uvm $INCDIRS \
      $RTL_FILES $BENCH_FILES $TB_FILES \
      -top test -generic_top test \
      -sv -generic_top test \
      -defparam test.SWITCH_POLICY=$POLICY \
      2>&1 | tail -3 \
    && echo "NOTE: pass DUT parameters with -defparam test.<name>=<value> per tool docs;" \
          "this script uses the tb defaults unless you add them there." )
  # Preferred portable xrun flow: build the snapshot once, then overlay
  # parameters at run time via the plusargs/uvm_config_db path in tb/env/test.sv.
  ( cd sim/run/$TEST && xrun -64bit -sv -uvm $INCDIRS \
      $RTL_FILES $BENCH_FILES $TB_FILES -top test -64bit -access +rwc \
      -outdir xcelium.d -run $PLUSARGS 2>&1 | tail -5 \
    && grep -E "HYSTERoC TEST" xrun.log 2>/dev/null | tail -1 || true )
  ;;
questa)
  mkdir -p sim/run/$TEST
  ( cd sim/run/$TEST && vlib work >/dev/null 2>&1 || true \
    && vlog -sv -work work $INCDIRS $RTL_FILES $BENCH_FILES $TB_FILES 2>&1 | tail -3 \
    && vsim -c -work work -gSWITCH_POLICY=$POLICY -gDET_VARIANT=$DET \
       -gDUAL=$DUAL -gUSE_EWMA=$EWMA -gTHIGH=$THIGH -gTLOW=$TLOW \
       work.test $PLUSARGS 2>&1 | tee run.log | grep -E "HYSTERoC TEST" || true )
  ;;
*)
  echo "unknown simulator: $SIM (expected vcs|xrun|questa)" >&2; exit 2;;
esac

if [ "$CAMPAIGN" = "1" ]; then
  echo "campaign requested — re-run with --test <name> per test; see docs/verification.md §5 for the catalogue."
fi
