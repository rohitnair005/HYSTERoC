# HYSTERoC — DECISIONS.md

Contract: `HYSTERoC_AI_Implementation_Specification_v5.md`. Language: Verilog-2001
(`iverilog -g2001`), `.v` + `.vh` only, no SystemVerilog, no vendor primitives.

## Status

| Batch | Contents | Status |
|---|---|---|
| 1 | `rtl/hysteroc_defs.vh`, `rtl/input_fifo.v`, `tb/tb_input_fifo.v` | **Done: simulation passes (Icarus Verilog 12.0).** |
| 2 | `rtl/ewma_filter.v`, `rtl/congestion_estimator.v`, `tb/tb_ewma_filter.v`, `tb/tb_congestion_estimator.v` | **Done: simulation passes, lint clean.** |
| 3 | `rtl/hysteresis_controller.v`, `tb/tb_hysteresis_controller.v` | **Done: simulation passes, lint clean.** |
| 4 | `rtl/round_robin_arbiter.v`, `tb/tb_round_robin_arbiter.v` | **Done: simulation passes, lint clean.** |
| 5 | `rtl/route_compute.v`, `tb/tb_route_compute.v`, `tb/tb_route_dump.v` (optional), `scripts/route_model.py`, `scripts/cdg_check.py`, `results/batch5_route_report.txt` | **Done: simulation passes, RTL = Python model on all 1024 inputs, Python checks pass.** |
| 6-15 | See batch plan in chat (route select, packet tracker, switch allocator, ...) | Not started |

Python checks (optional, needs Python 3, no extra packages): `python scripts/cdg_check.py --report results/batch5_route_report.txt`.
The delivered report was produced by this command.

Run in Vivado: add `rtl/*.v` and `rtl/hysteroc_defs.vh` as design sources (tick Global Include on the
`.vh` if an include is not found), add the `tb/*.v` files as simulation sources, set the simulation top
to the testbench you want, Run Behavioral Simulation, `run all`, look for `TB_RESULT: PASS` in the console.
Every testbench ends itself with `$finish`. (Tested here with Icarus Verilog, not xsim.)
Icarus command, if wanted: `iverilog -g2001 -Wall -I rtl -s tb_<name> -o x.vvp rtl/<name>.v tb/tb_<name>.v && vvp x.vvp`.

## Decisions made while implementing (spec rule 4: not explicitly frozen)

| # | Decision | Reason |
|---|---|---|
| 1 | Port IDs: N=0, S=1, E=2, W=3, Local=4 (3 bits). Tie-break order E,S,W,N is a separate rule in route selection. | Spec fixes tie-break only; any encoding works. |
| 2 | Macro names: width macro is `HY_PORT_ID_W`; West is `HY_PORT_W`. | Avoids clash between "port width" and "West". |
| 3 | `input_fifo` is first-word-fall-through: `data_out/type_out` always show the head. | Keeps data stable while `valid_out && !pop` (spec 3.2). |
| 4 | `push` while full and `pop` while empty are ignored (never corrupt state). | Defensive; the router never does this legally. Tested. |
| 5 | FIFO storage is not reset; `valid_out` gates its use. | Smaller logic, allows memory inference. Output data is undefined while empty. |
| 6 | `ready_in = (count != 4)` depends only on registered state, never on `pop`. | Spec 5.2 ACCEPTED. Full + pop + push in one cycle refuses the push. Tested. |
| 7 | FIFO is parameterised by `PTR_W` (default 2 = depth 4); occupancy width = `PTR_W+1`. | Spec asks for a parameterised FIFO; defaults match the frozen depth 4. |
| 8 | `ewma_filter`: `enable=0` freezes S and the period counter. With `SAMPLE_PERIOD>1` the sample is read only on the tick cycle (no averaging between ticks). The counter is generated only when `SAMPLE_PERIOD>1`. | Spec 6.5 freeze rule; avoids 16 unused flip-flops per router (27 -> 11 FFs measured by Yosys). |
| 9 | `ewma_filter` arithmetic is 11 bits end to end. | `S - (S>>3)` is never negative and the result is at most 2047 for any S, so no guard bit is needed. |
| 10 | `congestion_estimator` is combinational. Unavailable directions are masked to 0 before the max; `any_avail` distinguishes "no direction available" from "available, occupancy 0". All unavailable gives `cong = 0`. | Spec 6.1 / 9.4; its register stage is the sideband in the router. |
| 11 | Illegal occupancy 5..7 is clamped to 4 (-> 255) in the estimator. | Defensive only; the FIFO never produces it. |
| 12 | `congestion_estimator` also outputs `max_occ` (0..4). | The raw-occupancy baselines need the un-filtered value. |
| 13 | One `hysteresis_controller` covers all four comparison configurations through `DUAL` and `USE_EWMA` parameters. | Spec 12.1; keeps one tested module instead of four. |
| 14 | Thresholds `THIGH`, `TLOW`, `THRESH_SINGLE` are **parameters**, not ports. | Constant comparators synthesize smaller (helps the overhead criteria). A threshold sweep means changing parameters per run. |
| 15 | `mode_change_request = (req_mode != active_mode)`. `enable=0` holds `req_mode`. Reset `req_mode = XY`. | Spec 6.4: a request is not permission to switch. The transition controller will drive `enable`. |
| 16 | Single-threshold configurations use `value >= THRESH_SINGLE` (128), i.e. mapped occupancy 2 or more requests adaptive. | Spec 12.1 wording. |
| 17 | **To confirm:** Ablation A (single threshold on the EWMA value) uses the same 128. | Spec 12.1 gives 128 only for the raw baseline. Using 128 for both changes only the input source. |
| 18 | `round_robin_arbiter`: grant is combinational, pointer registered, pointer moves only when `advance && any_grant`, to granted index + 1 (mod N). Structure is a thermometer mask + lowest-set-bit select. | Spec 5.6. The first version (loop with `ptr + k` and dynamic indexing) synthesized to about 190 LUTs + 58 CARRY4 in Yosys; the rewrite is 30 LUTs with no carry chains. 80 arbiters exist in the mesh. |
| 19 | The arbiter does NOT hold a grant across a packet. The switch allocator (batch 8) holds the reservation from accepted header to accepted tail and only offers a free output to arbitration. | Keeps the arbiter simple and independently testable. |
| 20 | `route_compute` has no incoming-direction input. Inputs: `x, y, dst_x, dst_y, src_x`. `src_y` is not needed. Outputs `xy_port` (one-hot) and `oe_cand` (1 or 2 bits) are 5-bit masks, bit i = port id i. | Spec 5.4 v5. |
| 21 | Added `HY_PM_N/S/E/W/L` one-hot mask macros to `hysteroc_defs.vh`. | Avoids hard-coded bit patterns in later modules. |
| 22 | `route_compute` has no separate out-of-mesh mask. | Every candidate is a progress direction toward an in-range destination, so a mask is provably redundant for a 4x4 mesh; `tb_route_compute` checks "in bounds" for all 1024 inputs. |
| 23 | `route_compute` always produces both the XY port and the Odd-Even set; the mode choice is made in `route_select` (batch 6). | Keeps the module purely combinational and testable for both algorithms. |

## Defaults to apply in later batches (decided, not yet implemented)

- `active_mode` resets to XY (spec 6.4 resets the requested mode to XY).
- A transition starts when the requested target mode differs from `active_mode`.
- `WATCHDOG_LIMIT_CYCLES = 1000`, sticky ERROR until reset, injection stays blocked (spec 7.4).

## Port table

### `input_fifo` (spec 9.1)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Synchronous active-low reset |
| `push` | in | 1 | Accepted upstream transfer (`valid && ready_in`) |
| `data_in` | in | 16 | Flit data |
| `type_in` | in | 2 | Flit type |
| `ready_in` | out | 1 | `count != 4` |
| `pop` | in | 1 | Accepted downstream transfer |
| `data_out` | out | 16 | Head data |
| `type_out` | out | 2 | Head type |
| `valid_out` | out | 1 | `count != 0` |
| `occupancy` | out | 3 | Entries stored, 0..4 |

### `ewma_filter`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock, synchronous active-low reset |
| `enable` | in | 1 | 0 = freeze state (transition controller outside RUN) |
| `sample` | in | 8 | Mapped congestion sample C |
| `s_out` | out | 11 | S = 8*E |
| `e_out` | out | 8 | E = S >> 3 |

Parameter: `SAMPLE_PERIOD` (default 1, range 1..65535).

### `congestion_estimator`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `occ_n/s/e/w` | in | 3 each | Registered neighbour occupancy sideband, 0..4 |
| `avail_n/s/e/w` | in | 1 each | Direction exists (0 on a mesh boundary) |
| `max_occ` | out | 3 | Max over available directions, 0 if none |
| `cong` | out | 8 | Mapped 0/64/128/192/255 |
| `any_avail` | out | 1 | At least one direction available |

### `hysteresis_controller`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock, synchronous active-low reset |
| `enable` | in | 1 | 0 = hold `req_mode` |
| `value_ewma` | in | 8 | Global max of the 16 EWMA estimates |
| `value_raw` | in | 8 | Global max of the 16 mapped raw occupancies |
| `active_mode` | in | 1 | Current network mode (from transition controller) |
| `req_mode` | out | 1 | Requested mode, XY = 0, ADAPT = 1 |
| `mode_change_request` | out | 1 | `req_mode != active_mode` |

Parameters: `DUAL` (1), `USE_EWMA` (1), `THIGH` (160), `TLOW` (96), `THRESH_SINGLE` (128).

| Configuration (spec 12.1) | `DUAL` | `USE_EWMA` |
|---|---|---|
| HYSTERoC | 1 | 1 |
| Ablation B (dual, raw) | 1 | 0 |
| Ablation A (single, EWMA) | 0 | 1 |
| Conventional hybrid (single, raw) | 0 | 0 |

### `round_robin_arbiter`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock, synchronous active-low reset |
| `req` | in | N | Requests, one bit per input |
| `advance` | in | 1 | The granted transfer was accepted this cycle |
| `grant` | out | N | One-hot grant (subset of `req`), 0 if no request |
| `grant_idx` | out | IDX_W | Binary index of the grant, 0 if none |
| `any_grant` | out | 1 | At least one request |

Parameters: `N` (5), `IDX_W` (3, needs `N <= 2**IDX_W`).

### `route_compute`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `x`, `y` | in | 2 each | This router |
| `dst_x`, `dst_y` | in | 2 each | Header bits [15:14], [13:12] |
| `src_x` | in | 2 | Header bits [11:10] |
| `xy_port` | out | 5 | One-hot XY output, bit i = port id i (N0 S1 E2 W3 L4) |
| `oe_cand` | out | 5 | Odd-Even candidate set (1 or 2 bits) |

## Odd-Even verification status (spec 5.4 gate)

What was checked, and what was not:

- **Turn rules.** Two independent sources state the same two rules: the DyAD paper (no East->North/South turn in an
  even column, no North/South->West turn in an odd column) and a university report (its Theorems 1 and 2).
  `cdg_check.py` finds 0 violations in the implemented function.
- **Vertical-move condition.** The same report's pseudocode gives `(Cx odd) OR (Cx == Sx)` for an eastbound packet
  with a vertical offset. This matches the table.
- **Not found in any accessible source:** the East condition `(dst_x odd) OR (ex != 1)` and the westbound rule
  (West, plus vertical when the column is even). Both rely on my recollection of Chiu's paper and on the checks
  below, not on a quoted source. Chiu's original paper (IEEE TPDS 2000) has **not** been read.
- **Checks that do cover them (`cdg_check.py`, all 240 source/destination pairs):** candidate set never empty, Local
  only at the destination, every candidate in bounds and reducing the distance by exactly 1, every allowed path ends
  at the destination with the Manhattan length, no 180-degree turns, and the channel dependency graph (48 directed
  links) is acyclic. 108 of 240 pairs have more than one allowed path (up to 10).
- **Conclusion:** the implemented function is a minimal, turn-rule-compliant, CDG-acyclic adaptive Odd-Even
  function. It is labelled "Odd-Even candidate implementation" until the East and westbound conditions are compared
  with Chiu's original. The checklist item in the spec stays open.
- **Mixed modes.** The union of the XY and Odd-Even dependency graphs contains a cycle (example in
  `results/batch5_route_report.txt`: an 8-channel loop around columns 1-2, rows 0-3). XY uses East->South at an
  even column, which Odd-Even forbids. This supports the drain-and-switch decision: the two modes must never be
  active for packets in flight at the same time.
- An acyclic CDG is a sufficient condition for routing-function deadlock freedom under the usual assumptions
  (wormhole, finite buffers, sinks always accept). It is not a proof for the whole router.

## Verification evidence (batches 4 and 5)

- `tb_round_robin_arbiter`: two DUTs (N=5 and N=3) vs an independent model, about 200,000 random cycles plus an
  exhaustive pointer x request-mask sweep, strict order 0,1,2,3,4,0..., stalled-transfer pointer hold, pointer wrap,
  advance-without-grant, equal service for all 31 constant request sets, and a bounded-waiting check (no requester
  waits for more than N-1 other grants).
- `tb_route_compute`: all 1024 (x, y, src_x, dst_x, dst_y) inputs vs a literal Chiu-style model, plus properties
  (nonempty, Local only at destination, in bounds, progress, XY one-hot and X-first) and 14 directed cases from the
  table. 192 inputs have two Odd-Even candidates; 48 inputs have an XY output that is not an Odd-Even candidate.
- Three-way agreement: RTL output == testbench model == Python `route_model.py` on all 1024 inputs (text diff).
- Mutation checks: 11 arbiter variants and 12 `route_compute` variants all FAIL their testbench (a 12th arbiter
  variant did not compile and is not counted). 6 variants of the Python model all make `cdg_check.py` exit with
  status 1 (forbidden turns, cycles or empty candidate sets). Every reference passes.
- Verilator lint clean; Yosys finds no latches or structural problems.

## Verification evidence (batches 2 and 3)

- `tb_ewma_filter`: 313,160 cycles vs an integer model, two DUTs (`SAMPLE_PERIOD` 1 and 4). Hard-coded spec
  vector `S = 255, 479, 675, 846, 996`, `E = 31, 59, 84, 105, 124`. Constant inputs settle exactly at `S = 8C`
  (rising); falling input stops at `S = 8C+7` with `E = C`. `S` never exceeds 2040. Freeze, counter hold during
  freeze, reset, steps, 300,000 random cycles.
- `tb_congestion_estimator`: directed cases (frozen map written out explicitly, exclusion of unavailable
  directions, all unavailable, corner routers, clamp) plus an exhaustive 8^4 x 16 = 65,536-case comparison.
- `tb_hysteresis_controller`: five DUTs (all four configurations plus 200/50). Edge values 159/160/97/96,
  band hold in both states, source selection, `mode_change_request`, `enable` hold, an exhaustive
  start-state x 256-value sweep, and 300,000 random cycles against an independent model.
  Oscillation demo (value alternating 120/136, 200 cycles): HYSTERoC 0 request changes, dual-raw 0,
  single-EWMA 199, single-raw 199.
- Mutation checks: 25 deliberately broken variants (8 EWMA, 7 estimator, 10 hysteresis) all FAIL their
  testbench; 10 more EWMA variants against the final structure all FAIL; every reference passes.
- Verilator lint (`--language 1364-2001 -Wall`): clean on all four RTL modules.
- Yosys: no latches, `check -assert` passes on all four modules.

## Rough resource estimates (Yosys `synth_xilinx -family xc7`, NOT Vivado)

Indicative only, for early sanity. Vivado numbers on the chosen device are the ones to report.

| Module | Result |
|---|---|
| `input_fifo` (1 of 5 per router) | 9 FF, 12 LUT, 3 LUT-RAM (RAM32M), 0 BRAM |
| `ewma_filter`, `SAMPLE_PERIOD=1` | 11 FF, about 21 LUT, 3 CARRY4 |
| `congestion_estimator` | 0 FF, 16 LUT |
| `hysteresis_controller`, HYSTERoC / single-raw baseline | 1 FF, 3 LUT / 1 FF, 1 LUT |
| `round_robin_arbiter`, N=5 (5 per router) | 5 FF (Yosys recodes the pointer one-hot), 30 LUT, 0 CARRY4 |
| `route_compute` (5 per router) | 0 FF, 14 LUT, 1 CARRY4 |

## Verification evidence (batch 1)

- `tb_input_fifo`: 160,100 cycles compared against an independent shift-register model.
  Covers: reset state, fill to full, push-while-full, full+pop+push, head stability,
  ordered drain, pop-while-empty, wraparound, simultaneous push/pop at 1-3 entries,
  reset with push/pop asserted, 5 random phases (full-biased, empty-biased, balanced,
  always-push-and-pop) plus a mid-stream reset. Corner cases are counted and asserted as hit.
- Mutation check: 6 deliberately broken FIFO variants (ready depends on pop, no overflow
  guard, no underflow guard, wrong count on simultaneous push/pop, wrong head pointer,
  reset keeps count) all FAIL the testbench; the real FIFO passes.

## Not verified yet

- No Vivado run: not simulated in xsim, no real synthesis or timing numbers. FPGA board still unconfirmed.
- Everything beyond batches 1-3 is untested; nothing here makes any deadlock-freedom claim.

## Spec observations (non-blocking)

- Sections 3.3 and 8 still say "Proposed" (headings only).
- Schedule assumes a three-person team.
- Pilot synthesis is scheduled 8-9 Nov; run it earlier on batches 1-4.
