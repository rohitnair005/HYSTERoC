# Experiments — Evaluation Protocol

This document defines the evaluation methodology for HYSTERoC. Follow this protocol to produce comparable experimental results across different runs.

---

## 1. Configuration points

Evaluate the complete ablation matrix for all reported experimental data. Note the distinction between defaults: `noc_top.v` defaults to `SWITCH_POLICY=0, DET_VARIANT=0, ADAPT_MARGIN=0`, whereas `tb/env/test.sv` and the v6 evaluation baseline use `SWITCH_POLICY=1, DET_VARIANT=2, ADAPT_MARGIN=2` (Point 1′). Always label reported tables with the exact RTL version, parameters, simulator, and seed count.

| # | Name | `DUAL` | `USE_EWMA` | Thresholds | `SWITCH_POLICY` | Evaluation Purpose |
|---|---|---|---|---|---|---|
| 0 | XY reference | — | — | `XY_ONLY=1` | 0 | Baseline deterministic routing without adaptation. |
| 1 | **HYSTERoC** | 1 | 1 | THIGH=160, TLOW=96 | 0 | The proposed hysteresis architecture. |
| 2 | Ablation B | 1 | 0 | THIGH=160, TLOW=96 | 0 | Dual thresholds on raw signals (isolates filtering). |
| 3 | Ablation A | 0 | 1 | THRESH_SINGLE=128 | 0 | Single threshold on filtered signals (isolates hysteresis). |
| 4 | Conventional hybrid | 0 | 0 | THRESH_SINGLE=128 | 0 | Conventional hybrid baseline. |
| 1′ | HYSTERoC no-drain | 1 | 1 | THIGH=160, TLOW=96 | 1 | FPGA-friendly variant without drain delays (`DET_VARIANT` = 0, 1, 2). |

Comparison objectives:
* Compare **Point 1 against Point 4** to demonstrate the primary benefit of HYSTERoC.
* Compare **Point 1 against Point 2** to evaluate EWMA filter performance.
* Compare **Point 1 against Point 3** to evaluate the dual-threshold hysteresis band.
* Report **Point 1′** separately to show the throughput benefit of the no-drain variant.

---

## 2. Workloads

| Workload | Options and Flags | Purpose |
|---|---|---|
| Uniform | `--pat 0` with load sweep | Measures baseline sustained traffic. |
| Hotspot | `--pat 1` | Exercises maximum congestion detection across nodes. |
| Transpose | `--pat 2` | Measures structured permutation traffic. |
| Complement | `--pat 3` | Stresses longest-path routing in the mesh. |
| Neighbour | `--pat 4` | Evaluates single-hop nearest-neighbour traffic. |
| Oscillating (square wave) | `hy_oscillate_test --load 400 --cycles 300` | Tests ping-pong reduction under oscillating congestion. |
| Phased (low → high → low) | `hy_phased_test --load 350` | Tests transitions across hysteresis thresholds in both directions. |
| Load sweep | `hy_compare_test --lo 100 --hi 350 --step 25 --dwell 2000` | Measures latency and throughput across offered load levels. |
| All patterns | `hy_patterns_all_test --load 250` | Verifies stability across all traffic patterns. |
| Zero load | `hy_zero_load_test` | Confirms minimum latency equals `distance + 4`. |

Specify loads in units of per-mille flits per node per cycle (`--load 400` equals 0.4 flits/node/cycle).

---

## 3. Reported metrics (`performance_monitor`)

Record these metrics from the `performance_monitor` module:

| Metric | Signal Name | Description |
|---|---|---|
| Completed switches | `w_switches` (`w_to_adapt`, `w_to_xy`) | Total count of completed mode transitions. |
| Ping-pong events | `w_pp0` to `w_pp3` | Switches occurring within 50, 100, 200, or 400 cycles of previous switch. |
| Dwell time | `w_dwell_sum`, `min`, `max` | Duration the network remains in a mode before switching. |
| Blocked cycles | `w_blocked` | Cycles during which `inject_block_req` is asserted. |
| Blocked fraction | `w_blocked / measure` | Proportion of measurement window lost to drain blocks. |
| Drain duration | `drain_cnt`, `sum`, `min`, `max` | Cycles needed to drain all packets before switching. |
| Packet latency | `w_lat_*` | Mean, standard deviation, and maximum total and network latency. |
| Delivered throughput | `w_ej_flits` | Flits accepted at ejection sinks within measurement window. |
| Stall watchdog | `stall_max` | Maximum consecutive cycles with in-flight packets and zero deliveries. |

Always calculate rate-relative values:
* Switches per 1,000 delivered packets.
* Injection-blocked time fraction.
* Ping-pong events per 1,000 mode switches.

---

## 4. Statistical methodology

* Execute each configuration with **at least three distinct random seeds**. Report mean values and error ranges. Single-seed sweeps are preliminary and must be labelled as such.
* Exclude the warmup period from all reported statistics. Measure only during the configured measurement window.
* For oscillating workloads, log the congestion trajectories (`global_congestion` and `global_raw`) to show band crossings.

---

## 5. Reproducibility checklist

Include these details in all reported experiment summaries:
- [ ] Git commit SHA and status of working tree.
- [ ] Simulator version and synthesis/compilation flags.
- [ ] Top-level parameters (`policy`, `det`, `dual`, `ewma`, `thigh`, `tlow`).
- [ ] Test name and all plusarg parameters (`+HY_LOAD=`, `+HY_CYCLES=`, `+HY_PAT=`).
- [ ] Random seed values, warmup length, and measurement length.
- [ ] Raw performance counter values from `performance_monitor`.
- [ ] Status of watchdog alerts or error indicators.

---

## 6. Evaluation success criteria

A successful experimental evaluation must show:
1. **Fewer switches and fewer ping-pong events** for HYSTERoC compared to the conventional hybrid baseline at equal or better latency and throughput.
2. **Predictable ablation trends**: Point 2 and Point 3 must perform between Point 1 and Point 4.
3. **No-drain efficiency**: Point 1′ must eliminate drain delays while maintaining safe packet routing.
4. **Safe timeout recovery**: The watchdog test must transition cleanly to `ERROR` without deadlock when sources stall.

---

## 7. Experimental results (simulation)

This section summarizes simulation results collected under no-drain switching (`SWITCH_POLICY = 1`). Hardware synthesis results are not included here.

### 7.1 Hysteresis vs. single-threshold EWMA (`hy_compare_test`, EDA Playground)

* **Setup**: Cadence Xcelium 25.03, UVM 1.2, 7 Nov 2026 (v2 RTL). Both controllers use EWMA (`USE_EWMA = 1`): hysteresis (`160/96`) vs. single threshold (`128`). Load ramps `0.100 → 0.350 → 0.100` flits/node/cycle in `0.025` steps, 2,000 cycles per step (42,000 cycles).

| Pattern | Seeds | Mode Changes: Single | Mode Changes: Hysteresis (Mean, Range) | Reduction | Accepted Throughput (Single / Hyst) | Mean Latency, Cycles (Single / Hyst) |
|---|---:|---:|---|---:|---|---|
| Uniform | 5 | 2,046 (49 / 1k cyc) | 596 (538–630; 14 / 1k cyc) | **3.4×** | 0.224 / 0.224 | 8.09 / 8.09 |
| Transpose | 5 | 1,910 (45 / 1k cyc) | 690 (654–708; 16 / 1k cyc) | **2.8×** | 0.168 / 0.168 | 8.38 / 8.42 |
| Hotspot | 3 | 319 (8 / 1k cyc) | 182 (179–184; 4 / 1k cyc) | **1.8×** | 0.148 / 0.148 | 39.45 / 39.39 |

### 7.2 v6 fixed-load comparison (Verilator, 60,000 cycles)

* **Setup**: v6 baseline (`SWITCH_POLICY = 1`, `DET_VARIANT = 2`, `ADAPT_MARGIN = 2`), comparing hysteresis (`160/96`), EWMA single threshold (`128`), and raw single threshold (`128`). Cases where all three controllers switch once and stay adaptive (hotspot, and load ≥ 0.60) are omitted.

| Pattern | Load | Mode Changes (Raw / EWMA / Hyst) | Min Gap, Cycles (Raw / EWMA / Hyst) | Accepted Throughput | Mean Latency, Cycles (Raw / EWMA / Hyst) |
|---|---:|---|---|---|---|
| Uniform | 0.30 | 2,585 / 3,717 / 1,175 | 1 / 1 / 5 | 0.299 | 11.87 / 11.90 / 11.89 |
| Uniform | 0.45 | 15 / 103 / 3 | 1 / 1 / 12 | 0.443 | 18.27 / 18.27 / 18.27 |
| Transpose | 0.30 | 3,901 / 3,041 / 1,385 | 1 / 1 / 6 | 0.224 | 12.65 / 12.84 / 12.86 |
| Transpose | 0.45 | 75 / 99 / 25 | 1 / 1 / 9 | 0.333 | 18.43 / 18.44 / 18.44 |
| Complement | 0.30 | 515 / 1,086 / 206 | 1 / 1 / 7 | 0.299 | 15.44 / 15.44 / 15.44 |

Across all 48 runs (4 patterns × 4 loads × 3 controllers), hysteresis cuts mode changes by **2.2–5×** vs. raw single threshold and **2.2–34×** vs. EWMA single threshold, with throughput within `0.004` flits/node/cycle, mean latency within `2%`, and `0` errors.

### 7.3 Threshold sensitivity (preliminary, seed 1, `200–800` ramp)

| Pattern | `160/96` Switches | `192/128` Switches | `224/160` Switches | Accepted Throughput |
|---|---:|---:|---:|---|
| Transpose | 228 | 224 | 126 (−45%) | 0.316 |
| Complement | 134 | 87 | 60 (−55%) | 0.338–0.339 |
| Bit-reversal | 248 | 256 | 172 (−31%) | 0.322–0.329 |

Raising thresholds to `224/160` cuts mode changes by 31–55% with throughput within `0.01` flits/node/cycle and latency within `0.4` cycles; multi-seed tuning is still required.

### 7.4 Simulation comparison with DyAD (indicative)

Compared against published DyAD (Hu and Marculescu, DAC 2004: 6×6 mesh, 5-flit packets, C++ simulator), HYSTERoC v6 (4×4 mesh, 4-flit packets, Verilator, 60,000 cycles, saturation load `0.80` / low load `0.30`) is evaluated by each design's gain over its own XY baseline:
* **Transpose (saturation)**: v6 gains **+28.5%** throughput (`0.340 → 0.437` flits/node/cycle) and **−20%** latency (`47.98 → 38.33` cycles); DyAD reports **+61.7%** throughput.
* **Uniform (saturation)**: Both lose to XY (v6: **−8.0%** throughput, **+16%** latency).
* **Hotspot (saturation)**: v6 loses **−4.3%** throughput (`+13%` latency), whereas DyAD reports a gain (open item).
* **Complement (saturation)**: v6 matches XY throughput (`0.499`, `+9%` latency).
* **Low-load latency**: Both match deterministic routing closely (v6: Uniform `+1.6%`, Complement `+3.6%`, Transpose `−21%`).
