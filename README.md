# HYSTERoC — Hysteresis-Based Dynamic Routing Control for FPGA NoCs

**An FPGA-oriented Network-on-Chip (NoC) router. The router switches dynamically between deterministic XY routing and adaptive Odd–Even routing. A hysteresis controller filters congestion to reduce the ping-pong effect under fluctuating load while it preserves deadlock safety.**

| Property | Description |
|---|---|
| Design status | Research prototype (V6). RTL uses synthesisable Verilog-2001. A complete UVM environment is the primary verification platform. |
| Mesh | 4×4 mesh (16 wormhole routers, 5 ports each), 18-bit flits (16-bit data), 4-flit packets |
| Control | EWMA filter → global maximum → dual-threshold hysteresis → global drain-and-switch (or direct no-drain) controller |
| Verification | UVM 1.2 testbench (`tb/`), concurrent SVA (`hy_sva`), cycle-exact reference model, functional coverage, hop legality monitors |
| Documentation | Read [docs/architecture.md](docs/architecture.md), [docs/experiments.md](docs/experiments.md), and [DECISIONS.md](DECISIONS.md) |

---

## Table of contents

1. [Quick start](#1-quick-start)
2. [What HYSTERoC does (and why)](#2-what-hysteroc-does-and-why)
3. [Architecture](#3-architecture)
4. [Configuration matrix (one DUT, all ablation points)](#4-configuration-matrix-one-dut-all-ablation-points)
5. [Traffic, packets and the measurement model](#5-traffic-packets-and-the-measurement-model)
6. [Verification](#6-verification)
7. [Repository layout](#7-repository-layout)
8. [Documentation map](#8-documentation-map)
9. [Limitations and open issues](#9-limitations-and-open-issues)
10. [Citation and licence](#10-citation-and-licence)
11. [Agent notes](#11-agent-notes)

---

## 1. Quick start

### 1.1 RTL lint (no simulator licence needed)

Run Icarus Verilog to elaborate the complete design:

```bash
iverilog -g2005-sv -I rtl/common \
  -o /tmp/hysteroc.vvp \
  rtl/router/input_fifo.v rtl/control/ewma_filter.v rtl/control/congestion_estimator.v \
  rtl/control/hysteresis_controller.v rtl/router/round_robin_arbiter.v rtl/router/route_compute.v \
  rtl/router/route_select.v rtl/router/packet_tracker.v rtl/router/switch_allocator.v \
  rtl/router/crossbar.v rtl/router/noc_router.v rtl/control/drain_detector.v \
  rtl/control/transition_controller.v rtl/control/mode_switch_direct.v rtl/top/noc_top.v \
  rtl/bench/performance_monitor.v rtl/bench/traffic_generator.v rtl/bench/packet_sink.v
```

Or run Verilator:

```bash
verilator --lint-only --top-module noc_top -I rtl/common \
  $(cat sim/hysteroc.f | grep '\.v$') $(cat sim/hysteroc_bench.f | grep '\.v$') 2>&1 | head -50
```

### 1.2 UVM smoke test (commercial simulator)

Run a test with VCS, Xcelium, or Questa:

```bash
./scripts/run_uvm.sh --sim vcs   --test hy_smoke_test
./scripts/run_uvm.sh --sim xrun  --test hy_smoke_test
./scripts/run_uvm.sh --sim questa --test hy_smoke_test
```

Every run accepts configuration parameters. Refer to [docs/verification.md](docs/verification.md) §2 and `./scripts/run_uvm.sh --help`.

### 1.3 `make` shortcuts

```bash
make lint          # elaborate the design with iverilog
make sim-rtl       # compile via file lists
make docs          # verify all documentation links
make help          # show target list
```

---

## 2. What HYSTERoC does (and why)

### 2.1 The problem

Standard hybrid adaptive routers switch modes when congestion crosses a single threshold. The raw congestion signal contains noise: FIFO occupancies change every cycle. This noise causes rapid oscillations: XY → adaptive → XY → adaptive.

Each mode switch drains the network and stops packet injection. The router moves zero packets during this drain time. We name this condition **ping-pong**. Ping-pong degrades network throughput when traffic fluctuates.

### 2.2 The idea

HYSTERoC controls mode switching with **hysteresis control and a filtered congestion signal**:

```
neighbour FIFO occupancy ── max ── mapped 0..255 ── EWMA filter ── global max
        ── dual-threshold hysteresis (TLOW < THIGH) ── request ── global
           drain-and-switch FSM ── active_mode (broadcast, one writer)
```

* **EWMA filter (α = 1/8):** Removes high-frequency noise from FIFO occupancy. The controller reacts only to continuous congestion, not to single-cycle spikes.
* **Dual thresholds (`TLOW = 96`, `THIGH = 160` default):** Create a hysteresis band. When in adaptive mode, the controller returns to XY only when congestion drops below `TLOW`. When in XY mode, it switches to adaptive only when congestion exceeds `THIGH`. Signals that stay inside this band cause **zero** switches.
* **Drain-and-switch policy (`SWITCH_POLICY = 0`, paper baseline):** The controller switches modes only when the network is empty and all sources acknowledge. Exactly one FSM writes to the mode register. The FSM checks network emptiness again during the switch cycle. In-flight packets remain safe.
* **No-drain policy (`SWITCH_POLICY = 1`):** Both deterministic and adaptive modes use the *same Odd–Even turn rules* (`oe_fixed` / `oe_par` ∈ `oe_cand`). The controller switches modes while packets are in flight. The next header flit uses the new mode immediately. This variant is efficient on FPGAs because it avoids injection stalls.

### 2.3 What is being claimed (and what is not)

| Claim status | Statement |
|---|---|
| **Supported by design** | The controller eliminates ping-pong while the filtered congestion signal stays inside `(TLOW, THIGH)` and guarantees at least `4 × SAMPLE_PERIOD` cycles between switches. In simulation, hysteresis cuts mode changes by **1.8–3.4×** vs. single-threshold EWMA (`hy_compare_test`) and **2.2–5×** vs. raw single-threshold (v6 Verilator) at equal throughput and latency. |
| **Baseline to compare** | Single-threshold control on raw congestion values (`DUAL=0, USE_EWMA=0, THRESH_SINGLE=128`). HYSTERoC must achieve fewer switches and fewer ping-pong events at equal or better latency and throughput. |
| **Not claimed** | This repository does **not** provide a mathematical proof of end-to-end deadlock freedom for the full router. Deadlock safety relies on Chiu's Odd–Even turn model and channel-dependency analysis ([docs/architecture.md](docs/architecture.md) §3). |

---

## 3. Architecture

Refer to [docs/architecture.md](docs/architecture.md) for full technical details.

### 3.1 One picture

```
 16× source ── inj ──► ┌─────────────────────────────────┐
                        │ 16× noc_router (5-port wormhole)│── ej ──► 16× sink
                        │   input_fifo → packet_tracker   │  (neighbour-FIFO occupancy
                        │   → route_compute → route_select│   sideband feeds congestion
                        │   → switch_allocator → crossbar │   estimate + adaptive choice)
                        └────┬───────────┬────────┬───────┘
                 EWMA(E)    │           │        │  router_empty
                            ▼           ▼        ▼
            max of 16 E  ──► hysteresis_controller ──► req_mode ──► transition_controller
                 ──────────────────────────▲        (the ONLY writer of active_mode)
                            congestion_estimator (per router, max neighbour occupancy)
                            ewma_filter (per router, S_next = S − S/8 + C)
                            drain_detector (router_empty ∧ src_empty ∧ ¬link_active)
                            traffic_generator / packet_sink (bench, per node)
                            performance_monitor (observer: switches, dwell, ping-pong,
                                                   drain length, latency/throughput)
```

### 3.2 Router (`rtl/router/noc_router.v`)

Each router has five ports: North (0), South (1), East (2), West (3), and Local (4). Each input port contains an instance of `input_fifo`, `packet_tracker`, `route_compute`, and `route_select`. A `switch_allocator` (five round-robin arbiters) and a `crossbar` connect the input ports to output ports.

Interface rules:

* `in_ready` depends **only on registered FIFO state**. It never depends on `pop` or combinational paths. A full FIFO does not accept a flit during a pop cycle.
* `out_valid` asserts only when `out_ready` is 1. The condition `valid && !ready` never occurs on output links.
* Neighbour occupancy is registered once (one cycle old). The congestion estimator and the adaptive route selector read the same value.
* The router is **type-driven**. `packet_tracker` locks the output port between header flits and tail flits. The router does not count flits. Sources must enforce the 4-flit packet length contract.

### 3.3 Routing modes

| Mode | Rule | Implementation |
|---|---|---|
| **XY (deterministic)** | Route in X dimension first, then Y dimension. Deliver to Local at destination. | `route_compute.xy_port` |
| **Adaptive Odd–Even** | From legal Odd–Even ports (`oe_cand`), select the neighbour FIFO with lowest occupancy. Tie-break: East → South → West → North. | `route_compute.oe_cand` + `route_select` |
| **Deterministic Odd–Even (no-drain)** | `oe_fixed` (Local > East > West > vertical) or `oe_par` (source-parity variant). Every selection belongs to `oe_cand`. Mode switches remain deadlock-free. | `route_compute` (`DET_VARIANT`) |

`route_select` also supports an optional margin (`ADAPT_MARGIN`, v6). In adaptive mode, the router keeps the deterministic port unless an alternative candidate has at least `m` fewer flits. Default `m = 0` (disabled).

### 3.4 Congestion estimation and hysteresis (`rtl/control/`)

* `congestion_estimator`: Calculates `max_occ` across available cardinal directions. Excludes boundary directions. Maps occupancy to values `0, 64, 128, 192, 255`.
* `ewma_filter`: Fixed-point EWMA filter: `S_next = S − (S >> 3) + C`, where `E = S >> 3`. State `S` uses 11 bits and cannot overflow. Setting `enable = 0` freezes filter state.
* `hysteresis_controller`: Generates mode requests. When `DUAL=1`: requests adaptive mode if `value ≥ THIGH`; requests XY mode if `value ≤ TLOW`; holds state otherwise. When `DUAL=0`: functions as a single-threshold controller.
* `drain_detector`: Asserts `network_drained` when all routers are empty, all sources are empty, and all links are idle for `CONFIRM` consecutive cycles.
* `transition_controller`: Global drain-and-switch FSM. States: `RUN → QUIESCE_REQUEST → WAIT_ACK → DRAIN → SWITCH → RESUME → RUN`. Writes `active_mode` only during the `SWITCH` state while `network_drained` is true. Transitions to sticky `ERROR` state on watchdog timeout.
* `mode_switch_direct`: Direct no-drain switch module. Sets `active_mode` to `req_mode` after one clock cycle. Safe because deterministic and adaptive modes share the Odd–Even turn set.

### 3.5 Top level (`rtl/top/noc_top.v`)

Contains sixteen routers arranged in a 4×4 mesh (`node = 4·y + x`). Boundary inputs connect to `valid = 0`. Boundary outputs connect to `out_ready = 0`. Global trees compute the maximum of 16 EWMA estimates and 16 raw values. The hysteresis controller output drives the transition controller. All parameters are top-level parameters.

### 3.6 Simulation bench modules (`rtl/bench/`)

* `traffic_generator`: Packet source for each node. Provides 5 traffic patterns and an xorshift32 PRNG. Respects the injection block protocol.
* `packet_sink`: Ejection endpoint for each node. Verifies packet integrity: destination address, flit order, and checksum (`tail = hdr ^ body1 ^ body2 ^ 16'hC3A5`).
* `performance_monitor`: Passive observer. Measures completed mode switches, dwell times, ping-pong events, drain cycles, latency, and throughput.

### 3.7 Packet format and link rules

```
flit = { flit_type[1:0], data[15:0] }        // 18 bits total
packet = header, body, body, tail             // 4 flits exactly
header = { dst_x[15:14], dst_y[13:12], src_x[11:10], src_y[9:8], pid[7:0] }
flit types: 00 header, 01 body, 10 tail, 11 reserved
Signals hold stable while stalled; ready does not depend combinationally on valid.
```

---

## 4. Configuration matrix (one DUT, all ablation points)

Top-level parameters of `noc_top` (note: `noc_top.v` defaults to `SWITCH_POLICY=0, DET_VARIANT=0, ADAPT_MARGIN=0`, while the UVM testbench `tb/env/test.sv` and v6 no-drain evaluation baseline default to `SWITCH_POLICY=1, DET_VARIANT=2, ADAPT_MARGIN=2`):

| Parameter | Default | Function |
|---|---|---|
| `XY_ONLY` | 0 | 1 = lock network to XY mode; disable switching |
| `DUAL` | 1 | 1 = dual-threshold hysteresis; 0 = single threshold |
| `USE_EWMA` | 1 | 1 = use EWMA filtered input; 0 = use raw congestion |
| `THIGH` / `TLOW` | 160 / 96 | Hysteresis thresholds (`TLOW < THIGH`) |
| `THRESH_SINGLE` | 128 | Single-threshold baseline threshold |
| `SAMPLE_PERIOD` | 1 | EWMA sample period in cycles |
| `WATCHDOG_LIMIT_CYCLES` | 1000 | Maximum drain duration before timeout (≥ 4) |
| `POST_RESUME_MASK_CYCLES` | 0 | Cycles to hold controller frozen after switch |
| `DRAIN_CONFIRM` | 2 | Required idle cycles before `network_drained` asserts |
| `SWITCH_POLICY` | 0 | 0 = drain-and-switch; 1 = no-drain |
| `DET_VARIANT` | 0 | No-drain deterministic route: 0 = `oe_fixed`, 1 = `oe_par`, 2 = `oe_x21` |
| `ADAPT_MARGIN` | 0 | Adaptive bias toward deterministic port (0 = disabled) |
| `ENABLE_STATS` | 1 | 0 = remove transition statistics registers |

Four primary evaluation points:

| # | Point | Parameters | Purpose |
|---|---|---|---|
| 1 | **HYSTERoC** | `DUAL=1, USE_EWMA=1, THIGH=160, TLOW=96` | Proposed design |
| 2 | Ablation B | `DUAL=1, USE_EWMA=0` | Evaluates hysteresis on raw signals |
| 3 | Ablation A | `DUAL=0, USE_EWMA=1, THRESH_SINGLE=128` | Evaluates filtering with a single threshold |
| 4 | Conventional hybrid | `DUAL=0, USE_EWMA=0, THRESH_SINGLE=128` | Baseline design to exceed |
| 0 | XY reference | `XY_ONLY=1` | Pure deterministic routing |

---

## 5. Traffic, packets and the measurement model

### 5.1 Offered load

Offered load per node equals `4 × rate / 65536` flits per cycle. A load of 1.0 indicates one flit every cycle.

Available patterns:
* **uniform**: Random destination node.
* **hotspot**: Percentage of traffic goes to one hot node.
* **transpose**: Destination is `(y, x)`.
* **complement**: Destination is `(3−x, 3−y)`.
* **neighbour**: Destination is `(x+1 mod 4, y)`.

### 5.2 Latency definitions

* **Total latency:** Cycles from packet creation to tail flit acceptance. Includes source queue delay.
* **Network latency:** Cycles from header injection to tail flit acceptance.
* All latency values use 16-bit counters. Simulations must finish before 65536 cycles to avoid rollover.

### 5.3 Switching metrics (`performance_monitor`)

* **Completed switch:** Cycle in which `active_mode` changes value.
* **Ping-pong event:** A completed switch that occurs within `T_PP` cycles of the previous switch (`T_PP = 50, 100, 200, 400`).
* **Dwell time:** Cycles between consecutive mode switches.
* **Blocked period:** Cycles while `inject_block_req` is asserted.
* **Blocked fraction:** Blocked cycles divided by total measurement cycles.

---

## 6. Verification

Refer to [docs/verification.md](docs/verification.md) for full details.

### 6.1 Structure

| Component | Location | Function |
|---|---|---|
| Agents | `tb/agents/` | Drive and monitor injection, ejection, and inter-router links. |
| Sequences | `tb/seq/` | Generate packet traffic (uniform, burst, sweep, oscillate). |
| Scoreboard | `tb/env/hy_scoreboard.svh` | Verifies data integrity, packet order, and packet delivery. |
| Hop monitor | `tb/agents/hy_hop_monitor.svh` | Checks that each hop follows legal XY or Odd–Even rules. |
| Reference model | `tb/env/hy_model.svh` | Cycle-exact SystemVerilog model of the complete control path. |
| Protocol checker | `tb/env/hy_protocol_checker.svh` | Checks mode switch rules, drain requirements, and error states. |
| SVA | `tb/env/hy_sva.sv` | Concurrent assertions for interface properties and invariants. |
| Tests | `tb/tests/hy_tests_pkg.sv` | Test suite containing 19 directed and random tests. |

### 6.2 Running tests

```bash
./scripts/run_uvm.sh --sim xrun --test hy_oscillate_test --load 400 --cycles 300
./scripts/run_uvm.sh --sim vcs  --test hy_nodrain_test  --policy 1 --det 1
./scripts/run_uvm.sh --sim xrun --test hy_watchdog_test
./scripts/run_uvm.sh --sim xrun --test hy_regress_test
```

Tests pass when `UVM_ERROR` and `UVM_FATAL` counts equal zero.

### 6.3 Measured verification & simulation summary

* **UVM regression (`SWITCH_POLICY = 1`)**: 12 of 12 applicable tests pass in Cadence Xcelium 25.03 (UVM 1.2) with `0 UVM_ERROR`, `0 UVM_FATAL`, `0` scoreboard errors, and `0` SVA failures (`hy_watchdog_test` is skipped under no-drain). See [docs/verification.md](docs/verification.md) §8.
* **Block & deadlock checks**: All block-level unit tests pass with seeded mutants; RTL `route_select` produces `0` Odd–Even violations across 13.6M checked combinations, the RTL-derived dependency graph is acyclic (86 dependencies), and 18 forced-toggle stress runs complete with `0` errors.
* **Ping-pong reduction**: Hysteresis (`160/96`) reduces mode changes by **1.8–3.4×** vs. single-threshold EWMA (`hy_compare_test`) and **2.2–5×** vs. raw single-threshold (v6 Verilator) at equal throughput and latency. See [docs/experiments.md](docs/experiments.md) §7.

---

## 7. Repository layout

```
HYSTERoC/
├── README.md                  Project overview, quick start, architecture summary
├── DECISIONS.md               Design decisions and rationales
├── CHANGELOG.md               Version history
├── LICENSE                    MIT License
├── Makefile                   Convenience targets for lint and checks
│
├── rtl/                       Synthesisable Verilog-2001 (excluding bench/)
│   ├── common/hysteroc.vh     Constants and spec values
│   ├── router/                Router submodules (FIFO, arbiters, route compute, crossbar)
│   ├── control/               Congestion estimator, EWMA, hysteresis, drain controllers
│   ├── top/noc_top.v          4×4 mesh top-level integration
│   ├── bench/                 Simulation-only testbench sources, sinks, and monitors
│   └── design.sv              RTL file include list
│
├── tb/                        SystemVerilog UVM 1.2 testbench
│   ├── iface/hy_if.sv         DUT interface definition
│   ├── pkg/                   Package definition and data structures
│   ├── agents/                UVM agents, drivers, and monitors
│   ├── seq/                   UVM sequences and virtual sequences
│   ├── env/                   Environment, scoreboard, reference model, SVA
│   └── tests/hy_tests_pkg.sv  UVM test catalogue
│
├── sim/                       Simulator file lists (.f)
├── scripts/run_uvm.sh         Test runner script for VCS, Xcelium, and Questa
├── docs/                      Architecture, verification, experiments, and FPGA documentation
├── fpga/                      FPGA integration notes and constraints stub
└── .github/workflows/ci.yml   Continuous integration workflow
```

---

## 8. Documentation map

| Document | Description |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Module interfaces, invariants, turn model, and control logic |
| [docs/verification.md](docs/verification.md) | UVM testbench architecture, assertions, tests, and coverage |
| [docs/experiments.md](docs/experiments.md) | Evaluation methodology, workloads, metrics, and comparisons |
| [docs/fpga.md](docs/fpga.md) | Synthesis guidelines, resource usage, and clock constraints |
| [docs/faq.md](docs/faq.md) | Frequently asked questions and troubleshooting |
| [docs/glossary.md](docs/glossary.md) | Definitions of domain terms and abbreviations |
| [DECISIONS.md](DECISIONS.md) | Log of architectural decisions and design choices |
| [CHANGELOG.md](CHANGELOG.md) | Record of repository updates and release versions |

---

## 9. Limitations and open issues

1. **Deadlock freedom is argued, not proven:** Deadlock safety relies on Chiu's Odd–Even turn rules and round-robin arbitration. This repository does not contain a formal mathematical proof.
2. **Fixed packet length is a source contract:** Routers route flits based on flit type bits (header to tail). Routers do not count flits. Packet sinks detect malformed packets.
3. **Congestion signal uses neighbour FIFO occupancy only:** The controller does not measure link utilisation or packet wait times.
4. **No hardware protection against X propagation:** SVA assertions check for unknown (X) values in simulation, but RTL does not contain hardware recovery logic.
5. **FPGA top is omitted:** The repository includes integration guidelines and constraints stubs, but excludes board-specific bitstream projects.
6. **Modulo 16-bit latency counters:** Latency measurements roll over at 65536 cycles. Simulation runs must finish before this limit.

---

## 10. Citation and licence

This project is released under the **MIT License**. See [LICENSE](LICENSE) for terms.

If you use this design in research publications, cite this repository and state the evaluated parameter configurations.

---

## 11. Agent notes

AI agents and contributors must follow the repository instructions in [AGENTS.md](AGENTS.md).

Important rules:
* Do not commit to `main` directly. Use topic branches.
* Run `make lint` and `make docs` before you create commits.
* Do not renumber entries in [DECISIONS.md](DECISIONS.md).
