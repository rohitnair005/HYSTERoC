# Changelog — HYSTERoC

This document records the version history of the HYSTERoC project. Entries appear in reverse chronological order.

---

## v6.1 — Repository Restructure and Documentation Upgrade

- **Layout reorganization**: Separated the codebase into modular directories:
  * `rtl/`: Divided into `common/`, `router/`, `control/`, `top/`, and `bench/`.
  * `tb/`: Divided into `iface/`, `pkg/`, `agents/`, `seq/`, `env/`, and `tests/`.
  * Updated include paths across build scripts (`-I rtl/common -I rtl/router ...`).
  * Renamed `hysteroc_defs.vh` to `hysteroc.vh`.
  * Added missing `noc_router.v` include to `rtl/design.sv`.
- **Documentation**:
  * Rewrote all repository documentation in 50% ASD-STE100 technical style.
  * Added `docs/faq.md` and `docs/glossary.md`.
  * Updated `README.md`, `docs/architecture.md`, `docs/verification.md`, `docs/experiments.md`, `docs/fpga.md`, and `DECISIONS.md`.
  * Added UVM regression, block-level test, minimum-dwell, deadlock-check, and simulation comparison results to `docs/verification.md`, `docs/experiments.md`, and `README.md`.
  * Updated license to standard MIT License.
- **Build and verification scripts**:
  * Maintained compile file lists in `sim/` (`hysteroc.f`, `hysteroc_bench.f`, `hysteroc_tb.f`).
  * Updated test runner `scripts/run_uvm.sh` to support VCS, Xcelium, and Questa.
  * Added convenience targets in `Makefile` (`lint`, `sim-rtl`, `docs`).
- **Continuous integration**: Maintained `.github/workflows/ci.yml` for linting and link verification.

---

## v6.0 — Adaptive Margin (`ADAPT_MARGIN`)

- **Adaptive bias**: Added optional `ADAPT_MARGIN` parameter in `route_select.v`.
- When `ADAPT_MARGIN = m > 0`, adaptive mode retains the deterministic port unless an alternative candidate has at least `m` fewer flits.
- Configurable via top-level `ADAPT_MARGIN` parameter in `noc_top.v`.

---

## v5.0 — Column Balancing Route (`oe_x21`) and Source Column Turn Rule

- **Column balancing**: Added `route_compute.oe_x21` (`DET_VARIANT = 2`). Balances vertical link load between columns 1 and 2 for complement traffic.
- **Turn exception**: Added `x == src_x` exception in Odd–Even candidate logic. Allows eastbound packets to turn vertically at the source column.

---

## v4.0 — Unified Verification Environment

- Consolidated block-level testbenches into the top-level UVM environment.
- Implemented cycle-exact reference model (`hy_model.svh`) and concurrent SVA checkers.

---

## v3.0 — Source-Parity Deterministic Route (`oe_par`)

- **Parity routing**: Added `route_compute.oe_par` (`DET_VARIANT = 1`). Packets from even-parity sources (`src_x ⊕ src_y == 0`) choose vertical routing first when allowed.
- Distributes deterministic traffic across both dimensions within legal Odd–Even turns.

---

## v2.0 — No-Drain Direct Mode Switching

- **Direct mode switch**: Added `mode_switch_direct.v` for `SWITCH_POLICY = 1`.
- Enables switching between deterministic Odd–Even (`oe_fixed`) and adaptive Odd–Even with traffic in flight.
- Removes drain delays, injection stalls, and handshake requirements.

---

## v1.0 — Baseline Drain-and-Switch Architecture

- **Initial release**: Implemented 4×4 mesh wormhole NoC with EWMA congestion filtering and dual-threshold hysteresis.
- Global FSM (`transition_controller.v`) executes safe drain-and-switch mode changes between XY and adaptive Odd–Even routing.
