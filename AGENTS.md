# AGENTS.md — Working with the HYSTERoC Repository

This document provides operational instructions for AI agents and human developers editing this repository. Read this document before making changes.

---

## 1. System overview

HYSTERoC is an FPGA-oriented 4×4 mesh Network-on-Chip (NoC) with 16 wormhole routers and 5 ports per router. The design uses a **hysteresis-based routing controller**:
* Applies an EWMA filter to congestion data.
* Compares congestion against dual thresholds (`THIGH = 160`, `TLOW = 96`).
* Switches between deterministic XY and adaptive Odd–Even routing using a global drain-and-switch FSM or a direct no-drain controller.
* Suppresses ping-pong switching under fluctuating traffic while preserving routing deadlock safety.

Design characteristics:
- **RTL**: Synthesizable Verilog-2001 in `rtl/`. Simulation modules reside in `rtl/bench/`.
- **Testbench**: SystemVerilog and UVM 1.2 in `tb/`. Primary verification environment.
- **Status**: Research prototype (V6). Deadlock safety is argued and tested; this repository does not include a formal proof.

---

## 2. Repository layout

Do not flatten this directory structure:

```
rtl/common/hysteroc.vh        Frozen shared constants and macro values
rtl/router/                   input_fifo, packet_tracker, route_compute,
                              route_select, round_robin_arbiter,
                              switch_allocator, crossbar, noc_router
rtl/control/                  congestion_estimator, ewma_filter,
                              hysteresis_controller, drain_detector,
                              transition_controller, mode_switch_direct
rtl/top/noc_top.v             4×4 mesh and global control logic
rtl/bench/                    SIMULATION ONLY: traffic_generator, packet_sink,
                              performance_monitor (do not synthesise)
rtl/design.sv                 RTL include list
tb/iface/hy_if.sv             DUT interface
tb/pkg/                       hy_pkg package and helper files
tb/agents/                    Inject, eject, and hop agents; monitors; drivers
tb/seq/                       Base sequences and virtual sequence library
tb/env/                       Scoreboard, reference model, protocol checker,
                              coverage, SVA assertions, test top
tb/tests/hy_tests_pkg.sv      19 tests and base test class
sim/                          Compile file lists (hysteroc.f, hysteroc_bench.f, hysteroc_tb.f)
scripts/run_uvm.sh            Simulation runner script for VCS, Xcelium, and Questa
docs/                         Architecture, verification, experiments, FPGA, FAQ, glossary
fpga/                         FPGA integration notes and constraints stub
.github/workflows/ci.yml      CI workflow: Icarus Verilog, Verilator, docs link checker
```

Include directories:
* RTL: `-I rtl/common -I rtl/router -I rtl/control -I rtl/top -I rtl/bench`
* UVM: RTL include directories plus `-I tb/pkg -I tb/agents -I tb/seq -I tb/env -I tb/tests`

Compilation order: `hy_if.sv` → `hy_pkg.sv` → `hy_tests_pkg.sv` → `testbench.sv` (or `rtl/design.sv` for RTL-only compilation).

---

## 3. Engineering rules and conventions

### 3.1 RTL guidelines

- **Use Verilog-2001 only** for files in `rtl/` (except `.sv` include shells). Do not introduce SystemVerilog constructs in `rtl/`. Do not use vendor primitives or transparent latches.
- **Store frozen constants in `rtl/common/hysteroc.vh`**. Reference them with `` `HY_* `` macros. Never hardcode frozen specification constants in module logic. Tunable thresholds are `noc_top` parameters.
- **Maintain module header contracts**. Every module header specifies ports, rules, and edge cases. When modifying module behaviour, update the header in the same commit.
- **Follow interface boundaries**:
  * `in_ready` must derive from registered FIFO state only. It must never depend on `pop` or combinational paths.
  * Assert `out_valid` only when `out_ready` is 1.
  * Register neighbour occupancy once (`occ_q`).
  * Exactly one module (`transition_controller` or `mode_switch_direct`) drives `active_mode`.
  * `ej_ready` must never depend combinationally on `ej_valid`.
- **Maintain lint pragmas**: Preserve `/* verilator lint_off UNUSEDSIGNAL */` blocks for intentionally unused inputs.

### 3.2 Verification guidelines (`tb/`)

- **Interface timing rule**: Drive signals with non-blocking assignments (`<=`) immediately after `@(posedge clk)`. Sample signals in the active region of `@(posedge clk)`. Do not use clocking blocks.
- **Add tests for every new feature**: Extend `hy_base_test` in `tb/tests/hy_tests_pkg.sv`. Access knobs using `plus("HY_LOAD", ...)` rather than hardcoded constants. Ensure `hy_reset_test` and `hy_regress_test` pass.
- **Update reference model**: `tb/env/hy_model.svh` compares control outputs every clock cycle. Update the model whenever you modify the control path.
- **Pass criterion**: The test passes when UVM severity count equals zero (`*** HYSTERoC TEST PASSED ***`). Unexpected hangs or watchdog timeouts count as failures.

### 3.3 Decisions and documentation

- **Keep DECISIONS.md numbers stable**: Never renumber existing decisions. When modifying frozen parameters or policies, assign the next sequential decision number.
- **Update documentation in the same commit**: Update module headers, [docs/architecture.md](docs/architecture.md), [docs/verification.md](docs/verification.md), and [docs/experiments.md](docs/experiments.md) when changing interfaces, checkers, or metrics.
- **Maintain CHANGELOG.md**: Add new version entries at the top of the file.

### 3.4 Git branch and commit rules

- **Do not commit directly to `main`**. Create a descriptive branch (such as `feat/<name>`, `fix/<name>`, or `chore/<name>`), commit changes, and submit a pull request.
- **Use Conventional Commits** formatting (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- **Run validation commands**: Always execute `make lint && make docs` before you commit.

---

## 4. Common commands

```bash
make lint          # Elaborate complete design with iverilog
make docs          # Verify Markdown relative links
./scripts/run_uvm.sh --sim vcs   --test hy_smoke_test                 # Run smoke test
./scripts/run_uvm.sh --sim xrun  --test hy_oscillate_test --load 400 --cycles 300
./scripts/run_uvm.sh --sim xrun  --test hy_nodrain_test  --policy 1 --det 1
./scripts/run_uvm.sh --help      # Show options and parameter flags
```

---

## 5. Orientation guide for new contributors

1. [README.md](README.md): Claims, architecture overview, quick start, and layout.
2. [docs/architecture.md](docs/architecture.md): Module interfaces and invariants.
3. [docs/verification.md](docs/verification.md): How to execute and create tests.
4. [docs/faq.md](docs/faq.md): Answers to common questions and troubleshooting.
5. [docs/glossary.md](docs/glossary.md): Definitions of terms and acronyms.
6. [DECISIONS.md](DECISIONS.md): Architectural decisions and rationales.
7. `rtl/common/hysteroc.vh`: Frozen constants and macro definitions.

---

## 6. Known limitations

1. Deadlock freedom is argued from turn models, not formally proven with mathematical tools.
2. The 4-flit packet length is a source contract. Routers do not enforce length limits.
3. Latency counters wrap at 16 bits (65536 cycles).
4. RTL does not harden against X-propagation in hardware. Assertions check for X values in simulation.
5. Board-specific FPGA project files are not checked into this repository.
