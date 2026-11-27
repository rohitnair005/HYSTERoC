# Verification — HYSTERoC UVM Testbench

This document describes the UVM 1.2 verification environment for the HYSTERoC network-on-chip. The testbench verifies `noc_top` across the complete 4×4 mesh with active injection and ejection agents.

---

## 1. Interface timing contract (`hy_if`)

All testbench components must follow this timing rule:
* Drive signals using non-blocking assignments (`<=`) immediately after `@(posedge clk)`.
* Sample signals in the active region of `@(posedge clk)`.

This rule matches what registers capture on each clock edge. It prevents race conditions across different simulators.

The interface model defines node status signals:

```systemverilog
src_empty[n]        = !(src_busy[n] | src_force_busy[n]);
inject_block_ack[n] = inject_block_req & src_empty[n];
```

* `src_busy[n]`: Asserted by inject driver while a packet is transferring.
* `src_force_busy[n]`: Testbench control bit. Prevents acknowledgment to trigger the watchdog timer (`hy_watchdog_test`).
* `test_rst_n`: Testbench control bit for mid-test resets (`hy_reset_test`).

Ejection ready (`ej_ready`) must not depend combinationally on `ej_valid`. The sink driver uses registered random logic.

---

## 2. Running tests

Execute test scripts with VCS, Xcelium, or Questa:

```bash
./scripts/run_uvm.sh --sim vcs   --test hy_smoke_test
./scripts/run_uvm.sh --sim xrun  --test hy_oscillate_test --load 400 --cycles 300
./scripts/run_uvm.sh --sim questa --test hy_nodrain_test --policy 1 --det 1
```

Common command-line arguments:

| Argument | Description |
|---|---|
| `--test <name>` | Selects test name (`+UVM_TESTNAME=`). See §5. |
| `--policy 0\|1` | Selects `SWITCH_POLICY` (0 = drain-and-switch, 1 = no-drain). |
| `--det 0\|1\|2` | Selects `DET_VARIANT` (0 = `oe_fixed`, 1 = `oe_par`, 2 = `oe_x21`). |
| `--thigh <val>` | Sets high hysteresis threshold (default: 160). |
| `--tlow <val>` | Sets low hysteresis threshold (default: 96). |
| `--dual 0\|1` | Enables or disables dual-threshold mode. |
| `--ewma 0\|1` | Enables or disables EWMA filter. |
| `--load <val>` | Sets offered load in flits/node/cycle × 1000 (`+HY_LOAD=`). |
| `--cycles <val>`| Sets duration in clock cycles (`+HY_CYCLES=`). |
| `--timeout <val>`| Sets maximum cycles before test abort (default: 3,000,000). |
| `--campaign` | Executes all tests in sequence and reports status. |

Pass criteria: Test completes with `UVM_ERROR = 0` and `UVM_FATAL = 0`.

---

## 3. Testbench components

| File | Class / Scope | Function |
|---|---|---|
| `tb/iface/hy_if.sv` | `hy_if` | Physical interface to DUT. Exposes links and error signals. |
| `tb/pkg/hy_types.svh` | Functions | Constants, flit definitions, and header conversion functions. |
| `tb/pkg/hy_item.svh` | `hy_item` | Sequence item representing network packets. |
| `tb/pkg/hy_cfg.svh` | `hy_cfg` | Configuration object for sink modes, knobs, and checks. |
| `tb/pkg/hy_route.svh` | Functions | Golden routing calculation functions for testbench checks. |
| `tb/env/hy_sb_core.svh` | `hy_sb_core` | Core reassembly, ordering checks, and packet verification. |
| `tb/pkg/hy_traffic.svh` | Functions | Helper routines to generate traffic patterns. |
| `tb/env/hy_model.svh` | `hy_model` | Cycle-exact reference model for all control registers and logic. |
| `tb/pkg/hy_sequencer.svh` | `hy_vseqr` | Virtual sequencer executing virtual sequences. |
| `tb/agents/hy_inject_driver.svh` | `hy_inject_driver` | Injects flits into the 16 router input ports. |
| `tb/agents/hy_monitors.svh` | Monitors | Monitors packet transfers at injection and ejection ports. |
| `tb/agents/hy_sink_driver.svh` | `hy_sink_driver` | Controls `ej_ready` with random, burst, or continuous readiness. |
| `tb/agents/hy_hop_monitor.svh` | `hy_hop_monitor` | Monitors router links. Validates hop legality against turn rules. |
| `tb/env/hy_scoreboard.svh` | `hy_scoreboard` | Validates delivery count, destination, order, and checksum. |
| `tb/env/hy_protocol_checker.svh` | `hy_protocol_checker` | Validates transition rules, drain invariants, and timeouts. |
| `tb/env/hy_coverage.svh` | `hy_coverage` | Functional coverage for modes, thresholds, and patterns. |
| `tb/agents/hy_agents.svh` | Agents | UVM agent wrappers for drivers and monitors. |
| `tb/env/hy_sva.sv` | `hy_sva` | Concurrent SystemVerilog assertions for interface rules. |
| `tb/env/test.sv` | Module | Testbench top module: clock, reset, DUT, and configuration. |

---

## 4. Concurrent assertions (`hy_sva`)

Assertions verify protocol rules during simulation. Failures increment `vif.sva_errors`.

| Assertion | Policy | Verified Invariant |
|---|---|---|
| `a_blk_implies_busy` | Both | `inject_block_req` implies `transition_busy`. |
| `a_state_legal` | Both | FSM state does not equal invalid state 7. |
| `a_timeout_is_error` | Both | `drain_timeout` is asserted if and only if state is `ERROR`. |
| `a_mode_change_only_after_switch` | 0 | `active_mode` changes only in `SWITCH` state when drained. |
| `a_mode_change_sources_idle` | 0 | Mode changes only when all sources are idle. |
| `a_start_only_from_run` | 0 | Transitions begin only from `RUN` when request differs from active. |
| `a_block_rises_from_run` | 0 | Injection block asserts only from `RUN`. |
| `a_release_in_resume` | 0 | Injection block deasserts only in `RESUME`. |
| `a_error_sticky` | 0 | `ERROR` state persists until system reset. |
| `a_no_inject_in_drain_switch` | 0 | Injection `valid` remains zero during `DRAIN` and `SWITCH`. |
| `a_nd_run_only` | 1 | No-drain mode remains in `RUN`. Block and timeout stay low. |
| `a_nd_mode_follows_req` | 1 | No-drain mode updates `active_mode` one cycle after request. |
| `a_drained_means_empty` | Both | `network_drained` implies all FIFOs and sources are empty. |
| `a_no_internal_errors` | Both | Internal protocol and allocation errors stay zero. |
| `a_no_x_control` | Both | Control and handshake signals contain no X or Z values. |
| `a_ej_hold` | Both | Ejection outputs hold data until accepted by the receiver. |

---

## 5. Test suite catalogue

| Test Name | Description |
|---|---|
| `hy_smoke_test` | Sends one packet from node 0 to node 15. |
| `hy_zero_load_test` | Verifies latency equals `distance + 4` in an empty mesh. |
| `hy_all_pairs_test` | Sends packets across all 240 source-destination pairs. |
| `hy_flow_test` | Transmits 200 packets along a single flow to verify ordering. |
| `hy_uniform_test` | Evaluates uniform random traffic under specified load. |
| `hy_hotspot_test` | Evaluates traffic directed toward a single node. |
| `hy_transpose_test` | Evaluates matrix transpose traffic pattern. |
| `hy_phased_test` | Sweeps load low → high → low to cross hysteresis thresholds. |
| `hy_oscillate_test` | Alternates load in a square wave to test ping-pong suppression. |
| `hy_nodrain_test` | Verifies in-flight mode changes under `SWITCH_POLICY = 1`. |
| `hy_compare_test` | Sweeps load across multiple steps to measure latency and switches. |
| `hy_patterns_all_test` | Executes all traffic patterns under heavy load. |
| `hy_lengths_test` | Transmits packets with lengths between 2 and 16 flits. |
| `hy_loopback_test` | Sends packets where source equals destination. |
| `hy_bubble_test` | Injects packets with intra-packet delays and stalled sinks. |
| `hy_backpressure_test` | Dynamically changes sink ready behaviour during transmission. |
| `hy_watchdog_test` | Simulates an unacknowledged source to verify `ERROR` timeout. |
| `hy_reset_test` | Applies reset during active packet transmission. |
| `hy_regress_test` | Runs the complete sequence of tests in a single simulation. |

---

## 6. Verification procedure

1. Write sequences in `tb/seq/`.
2. Add new test classes in `tb/tests/hy_tests_pkg.sv` by extending `hy_base_test`.
3. Read configuration knobs through `plus("HY_LOAD", 100)` instead of fixed constants.
4. Set `cfg.expect_drain_timeout = 1` for tests that intentionally trigger watchdogs.
5. Set `cfg.require_inflight_switch = 1` for tests that require in-flight mode switches.
6. Execute the test using `./scripts/run_uvm.sh`.

---

## 7. Sign-off checklist

Before marking a configuration complete, confirm:
- [ ] `hy_smoke_test`, `hy_zero_load_test`, and `hy_all_pairs_test` pass without errors.
- [ ] `hy_oscillate_test` passes under both policies (`SWITCH_POLICY = 0` and `1`).
- [ ] `hy_nodrain_test` passes and observes an in-flight switch under `SWITCH_POLICY = 1`.
- [ ] `hy_watchdog_test` reaches the `ERROR` state safely without hanging under `SWITCH_POLICY = 0`.
- [ ] `hy_reset_test` and `hy_regress_test` complete successfully.
- [ ] Functional coverage bins for modes, threshold bands, and patterns are covered.
- [ ] Performance metrics match expected values in [docs/experiments.md](experiments.md).

---

## 8. Verification results

This section records observed simulation and static verification results. Hardware synthesis results are tracked separately.

### 8.1 UVM regression (`SWITCH_POLICY = 1`, EDA Playground)

* **Tool**: Cadence Xcelium 25.03, UVM 1.2, seed 1, run on 6 Nov 2026 (v2 RTL).
* **Configuration**: `SWITCH_POLICY = 1` (no-drain), `THIGH = 160`, `TLOW = 96`.
* **Summary**: 12 of 12 applicable tests passed (`0 UVM_ERROR`, `0 UVM_FATAL`, `0` scoreboard errors, `0` SVA failures). Minimum latency excess over the zero-load bound (`distance + 4`) was 0 across all runs.

| Test | Packets Injected | Packets Delivered | Mode Changes | Result | Notes |
|---|---:|---:|---:|---|---|
| `hy_nodrain_test` | 5,405 | 5,405 | 36 | PASS | Alternating heavy/light load; 0 packets lost |
| `hy_smoke_test` | 1 | 1 | 0 | PASS | Basic end-to-end path |
| `hy_zero_load_test` | 4 | 4 | 0 | PASS | Matches zero-load latency floor |
| `hy_all_pairs_test` | 480 | 480 | 2 | PASS | Covers all 240 source–destination flows |
| `hy_uniform_test` | 1,985 | 1,985 | 2 | PASS | Uniform traffic delivered intact |
| `hy_hotspot_test` | 2,009 | 2,009 | 88 | PASS | Intact delivery under 88 mode switches |
| `hy_transpose_test` | 1,550 | 1,550 | 0 | PASS | Deterministic mode at this load |
| `hy_bubble_test` | 2,319 | 2,319 | 146 | PASS | Sink stalls handled across 146 switches |
| `hy_backpressure_test` | 3,246 | 3,246 | 44 | PASS | Dynamic backpressure across 44 switches |
| `hy_reset_test` | 4,341 | 4,331 | 56 | PASS | 10 in-flight packets flushed by reset (by design) |
| `hy_regress_test` | 21,044 | 21,044 | 426 | PASS | Largest run; 426 switches, 0 errors |
| `hy_watchdog_test` | — | — | — | Skipped | Not applicable under `SWITCH_POLICY = 1` (no drain) |

* **Notes**: One testbench checker bug found during these runs (latency floor assumed 4-flit packets only) was fixed in the testbench without RTL changes. Functional coverage is implemented in `hy_coverage.svh` but was not collected in these runs.

### 8.2 Block-level tests (Icarus Verilog and Verilator)

Self-checking unit tests with seeded mutants pass across all RTL blocks:
* **Datapath & control**: `input_fifo`, `ewma_filter`, `congestion_estimator`, `hysteresis_controller`, `round_robin_arbiter`, `packet_tracker`, `switch_allocator`, `crossbar`, `drain_detector`, `transition_controller`.
* **Routing**: `route_compute` matches the Python reference model on all 1,024 input combinations; `route_select` passes 336,922 test cases with 7 of 7 seeded mutants killed.
* **Bench**: `traffic_generator` and `packet_sink` kill 21 mutants; `performance_monitor` kills 17 of 18 mutants (1 equivalent).

### 8.3 Minimum dwell and deadlock-freedom evidence (v6 baseline)

Results below use the v6 no-drain baseline (`SWITCH_POLICY = 1`, `DET_VARIANT = 2`, `ADAPT_MARGIN = 2`) in Verilator:

* **Minimum time between mode changes**: Exhaustive search over the EWMA and hysteresis state machine proves the mode cannot change twice within `4 × SAMPLE_PERIOD` cycles (4 cycles at `SAMPLE_PERIOD = 1`; tight bound). Single-threshold control has a 1-cycle minimum gap.
* **Observed switching gaps (100,000 cycles, offered load 0.45 flits/node/cycle)**:
  * *Uniform*: Hysteresis (`160/96`) = 7 switches, min gap **6 cycles**; EWMA single-threshold (`128`) = 171 switches, min gap **1 cycle**; raw single-threshold (`128`) = 33 switches, min gap **1 cycle**.
  * *Transpose*: Hysteresis (`160/96`) = 43 switches, min gap **8 cycles**; EWMA single-threshold (`128`) = 143 switches, min gap **1 cycle**; raw single-threshold (`128`) = 123 switches, min gap **1 cycle**.
* **Channel-dependency & RTL route checks**:
  * Python model (240 pairs): XY alone has 68 dependencies (acyclic); Odd–Even alone has 86 dependencies (acyclic, 0 forbidden turns); plain XY + Odd–Even mixed has 92 dependencies with a cycle (explaining why `SWITCH_POLICY = 0` drains and `SWITCH_POLICY = 1` uses Odd–Even-compatible deterministic modes).
  * RTL `route_select` check: 13,639,680 combinations of position, source, destination, mode, neighbour occupancy (sampled with stride 37), and availability produced **0 violations** outside Odd–Even candidates.
  * RTL-derived dependency graph (240 pairs): 86 dependencies, **acyclic**, 0 moves off-mesh.
* **Forced mode-toggle stress**: 18 runs (3 patterns × 2 loads × 60,000 cycles) forcing random mode toggles every `K = 1, 3, 16` cycles produced **0** protocol, allocation, destination, order, or integrity errors (max zero-ejection stretch: 5–8 cycles).
* **Scope limit**: This evidence covers the routing function under wormhole switching, finite buffers, and always-accepting sinks; it is not a formal whole-router proof.
