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
| 6 | `rtl/route_select.v`, `tb/tb_route_select.v` | **Done: 336,922 cases pass (320,000 exhaustive adaptive), 7 mutants killed, lint clean.** |
| 7 | `rtl/packet_tracker.v`, `tb/tb_packet_tracker.v` | **Done: 324,892 cycles vs model, 15,000 legal packets, 8 mutants killed, lint clean.** |
| 8 | `rtl/switch_allocator.v`, `rtl/crossbar.v`, `tb/tb_switch_allocator.v` | **Done: DUT = reference model on 80,001 raw + 60,000 system cycles, 25,021 packets, crossbar exhaustive (7,776 patterns), 10 mutants killed, lint clean.** |
| 9 | `rtl/noc_router.v`, `tb/tb_noc_router.v` | **Done: 16 router positions x 20,000 cycles, 86,666 packets, 0 errors, 10 mutants checked (9 killed, 1 equivalent), lint clean.** |
| 10 | `rtl/drain_detector.v`, `rtl/transition_controller.v`, `tb/tb_drain_detector.v`, `tb/tb_transition_controller.v` | **Done: controller = independent cycle model on 6 environments (3 directed, 3 random, about 240k cycles, thousands of transitions, ERROR and re-check paths hit), 18 mutants killed, lint clean.** |
| 11 | `rtl/noc_top.v`, `tb/tb_noc_top.v` | **Done: 4 complete meshes x 30,000 cycles (about 57,000 packets), 0 errors, end-to-end drain checks, 11 wiring/control mutants (9 killed, 2 equivalent under the ack protocol).** |
| 12 | `rtl/traffic_generator.v`, `rtl/packet_sink.v`, `tb/tb_traffic_generator.v`, `tb/tb_packet_sink.v`, `tb/tb_traffic_system.v` | **Done: unit tests (6 generator nodes, sink fuzz vs model 80,000 cycles), full system with real generators/sinks, zero-load latency law, 21 mutants killed, lint clean.** |
| 13 | `rtl/performance_monitor.v`, `tb/tb_performance_monitor.v`, `tb/pm_log.vh`, `scripts/metrics.py`, `tb/tb_traffic_system.v` (monitor + logs integrated) | **Done: monitor equals an independent trace model in 74 random scenarios (two parameter sets), 17 mutants killed + 1 equivalent, full system run with logs: script recomputation equals the RTL counters (26/26), lint clean.** |
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
| 24 | `route_select` XY mode returns `xy_port` masked by availability; adaptive mode picks the lowest-occupancy available Odd-Even candidate, ties E,S,W,N via a running strictly-lower minimum. Local wins if present. `sel_valid = |sel_port`. | Spec 5.5. Boundary directions are never selected in either mode. |
| 25 | `route_select` is purely combinational; occupancy values 5..7 are unspecified. | FIFO never produces them. |
| 26 | `packet_tracker` has no per-port flit counter. State is only `locked` + `locked_port` (6 FF). Release is type-driven (accepted tail). The fixed 4-flit length is checked by testbenches and the sink, not by hardware. | Saves FFs/logic on 80 ports; a malformed packet is a source bug, not a router case. |
| 27 | `packet_tracker` reports illegal sequences (body/tail while unlocked, header while locked, type 11) on a combinational `proto_err`, with no sticky state, and otherwise ignores them. Accepted transfers without a valid head are ignored. | Defensive; the router never does this legally. Assertions in batch 14 will use `proto_err`. |
| 28 | `packet_tracker` re-evaluates `route_port` every cycle while a header is stalled and latches it only on the accepted header. A header whose `route_port` is 0 makes no request. | Spec 5.6: a stalled header reserves nothing. |
| 29 | `input_fifo.v` and `tb_input_fifo.v` were recreated in this session from the earlier output (not re-attached) with identical behaviour. | Container reset. Regression passes; please compare with your copy. |
| 30 | Reservation state lives ONLY in `packet_tracker` (`locked`, `locked_port`). `switch_allocator` derives `out_busy[o]` from the five trackers and keeps no ownership registers of its own. | One source of truth; drain detector (batch 10) can read the same `locked` bits. |
| 31 | An output with any reservation is never offered to arbitration. Release happens on the accepted tail, so the output is busy in the tail cycle and free the next cycle: one idle arbitration cycle between packets on the same output. | Simple, safe; costs at most one bubble per packet per contended output. Could be removed later by letting a tail cycle also arbitrate; not needed for the claim. |
| 32 | Arbiter `advance = fire[o]` (selected AND `out_ready`). The pointer moves only on a real header transfer (the arbiter ignores `advance` without a grant, so continuation transfers never move it). Round robin is per packet, not per flit. | Spec 5.6. Fairness test: 5 inputs on one output get exactly equal shares (200 packets each). |
| 33 | Header grant requires `out_ready` in the same cycle (`fire`); `in_grant[i]` is the FIFO pop and tracker `xfer`. Boundary or unconnected outputs must have `out_ready = 0`. | ready/valid rule; no combinational path through other routers because `ready_in` depends only on registers. |
| 34 | `crossbar` is a combinational one-hot AND-OR mux (no registered stage); idle output carries data 0, type 00, valid 0. | Spec 5.6 allows a registered stage, but registering would add a flit of storage the drain detector must count and break the `ready_in = (count != 4)` timing. |
| 35 | `alloc_err` = two owners on one output or two inputs selected on one output. Combinational, no sticky state. | For batch 14 assertions; never set in a legal run (tested). |
| 36 | `noc_router` registers the neighbour occupancy sideband itself (`occ_q <= nbr_occ_in`). Its input is the neighbour's CURRENT FIFO occupancy; every consumer (congestion estimate, `route_select`) uses `occ_q`, so all see the same one-cycle-old value. | Spec 9.4. Top level just wires neighbour `fifo_occ` to `nbr_occ_in`. |
| 37 | `nbr_avail[3:0]` bit order is N,S,E,W (bit 0 = N). Boundary outputs are masked in the router (`out_ready & avail`), so a boundary link can never transfer even on an illegal route. Local is always available. | Spec 9.4. The mask cannot be seen by legal traffic (route_select never selects a boundary), so it is covered by the allocator tests and by inspection, not by a router mutant. |
| 38 | `out_valid[o]` is asserted only in a cycle where `out_ready[o]` is 1 (valid implies ready; the transfer happens in that cycle). The hold-while-stalled rule holds trivially. Downstream `out_ready` must never depend combinationally on `out_valid` (FIFO `ready_in` and the sink satisfy this). | Falls out of the allocator design; keeps the router free of output registers. Batches 11-12 must obey it. |
| 39 | `router_empty = no FIFO holds a flit AND no packet_tracker holds a reservation`. The router has no other storage. A reservation with an empty FIFO (tail not yet arrived) correctly gives `router_empty = 0`. | Spec 9.2/12.3. Tested cycle by cycle against a model. |
| 40 | Extra router outputs: `ewma_out` (E of this router), `cong_now` and `max_occ_now` (unfiltered, for raw baselines), `fifo_occ` (5x3 bits), `proto_err`, `alloc_err`. `ewma_enable` input freezes the EWMA. | Needed by the global max, baselines, drain detector and assertions. |
| 41 | `drain_detector` reduces three per-node bits sampled in one cycle: `router_empty`, `src_empty`, `link_active`. `link_active` = any valid on a link attached to the node this cycle (router `out_valid` or source `in_valid`): links are wires, so a flit in transit is exactly a valid. `network_drained = drained_now` held for `CONFIRM` (default 2) consecutive cycles AND true this cycle. | Spec 7.3. Falls immediately on any activity, rises only after quiet cycles. Batch 11 must build `link_active` and batch 12 `src_empty` (queue empty AND no injection in progress). |
| 42 | `transition_controller` owns the only `active_mode` register; it is written only in SWITCH and only when `network_drained` is true in that same cycle. SWITCH re-checks; if drained dropped it returns to DRAIN without switching (state `S_SWITCH` -> `S_DRAIN`). | Spec 7.2/7.5 safety obligation "no mode update unless drained". |
| 43 | Watchdog convention: cycle 1 = first cycle `inject_block_req = 1` (QUIESCE_REQUEST). `network_drained` seen in DRAIN by cycle `LIMIT` succeeds; later (or acks only in cycle `LIMIT`) goes to ERROR. Requires LIMIT >= 4. ERROR keeps block asserted, keeps `active_mode`, never resumes; reset only. | Spec 7.4: "count the exact cycle convention in the testbench". Tested at LIMIT-1, LIMIT, LIMIT+1. |
| 44 | The minimum transition (instant acks, already drained) takes QUIESCE 1, WAIT 1, DRAIN 1, SWITCH 1 = 4 blocked cycles, then RESUME 1 cycle (injection already released). | Hand-derived timeline, checked in D2. |
| 45 | RESUME lasts `1 + POST_RESUME_MASK_CYCLES` cycles; injection is released on entry; EWMA and hysteresis stay frozen (`ewma_enable = hys_enable = (state == RUN)`). A request arriving during RESUME is honoured only after RUN is reached. | Spec 7.2: EWMA frozen outside RUN including the optional mask. |
| 46 | A transition starts only when `req_mode != active_mode` in RUN. The target is latched and never changed; later `req_mode` changes are ignored until the next RUN cycle. | Spec 7.4. |
| 47 | Statistics (cycle counter, per-transition and cumulative blocked / ack-wait / drain cycles, transition count, five timestamps) are controlled by `ENABLE_STATS` (default 1). `t_switch == t_resume` by construction (new mode and release of injection are visible in the same cycle). The FSM never reads a statistic. | Spec 7.3/7.4 asks for these; the switch lets the resource comparison exclude measurement logic. Yosys: stats on 453 FF, off 37 FF. |
| 48 | Node id n = 4*y + x. Router output q feeds the neighbour's OPPOSITE input port (out N -> in S of the node above, etc.). Boundary inputs are valid = 0, boundary `out_ready` = 0. | Standard mesh wiring; verified by delivery of every packet and by the sideband wiring check. |
| 49 | Sideband wiring: router A's direction d input is the CURRENT occupancy of the neighbour FIFO that receives A's flits in direction d (neighbour input port opposite(d)), 0 at the boundary; the router registers it (decision 36). | Spec 9.4. Checked every cycle for all 16 nodes x 4 directions. |
| 50 | `noc_top` exposes the local ports flattened (node n at `[16n+:16]`, `[2n+:2]`, `[n]`), the transition protocol (`inject_block_req/ack`, `src_empty`), status (`active_mode`, `req_mode`, `global_congestion` = max of the 16 EWMA, `global_raw` = max of the 16 unfiltered values, `ctrl_state`, `network_drained`, `router_empty`, `fifo_occ_all`, `ewma_all`) and the controller statistics. | Needed by traffic generators/sinks (batch 12) and the performance monitor (batch 13). |
| 51 | Configurations (spec 12.1) are parameters of `noc_top`: HYSTERoC `DUAL=1 USE_EWMA=1`; Ablation A `DUAL=0 USE_EWMA=1`; Ablation B `DUAL=1 USE_EWMA=0`; conventional `DUAL=0 USE_EWMA=0`; XY-only reference `XY_ONLY=1` (request forced to XY, the controller never leaves RUN). All hybrids use the same transition controller. | Spec 7.6 comparison fairness. Ablation B (dual threshold on raw occupancy) is not simulated yet; same module, parameters only. |
| 52 | `link_active` is built from router `out_valid` and source `inj_valid`. In this architecture a flit on a link is always also stored in the sending FIFO or source, so `link_active` and `src_empty` are redundant under the ack protocol (two mesh-level mutants survive for that reason). They stay as defensive, spec-required terms and are killed at unit level by `tb_drain_detector`. | Spec 7.3 lists link and source state explicitly. |
| 53 | Verilator 5.020 hits an internal error (V3Gate) on the whole `noc_top` with default flags; `-fno-gate` lints it cleanly. The unused bits of boundary link outputs are waived (`-Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY`). | Tool bug, not a design issue; each module below `noc_top` lints clean with `-Wall`. |
| 54 | Packet format (all sources/sinks): flit 0 header `{dst_x,dst_y,src_x,src_y,pid}`; flit 1 body = creation time `now[15:0]`; flit 2 body = injection time `now[15:0]` (first cycle the header is offered); flit 3 tail = `header ^ body1 ^ body2 ^ 16'hC3A5` (integrity word). | Carries both latency timestamps inside the packet with no side channel; `now` is a shared free-running counter (batch 13 provides it). 16-bit modulo differences: latencies of 65,536 cycles or more would alias. |
| 55 | Source queue: `QDEPTH` 4 created packets, open-loop creation (probability `rate/65536` per cycle). A full queue DROPS the new packet and counts it (`dropped`); offered = created + dropped. Created packets keep their creation timestamp while queued, so the total latency includes the wait caused by a transition. | Spec 12: latency from packet creation is the primary metric. Report `dropped` next to throughput in every result. |
| 56 | A packet is STARTED when it leaves the queue (decision cycle with `inject_block_req = 0`); it always finishes. `inject_block_ack = block & idle`, `src_empty = idle`. Packets still in the queue are not admitted to the network and are not part of `src_empty`. | Spec 7.3. A packet start can coincide with the cycle `inject_block_req` rises; it is then a started packet and the ack stays 0 until it finishes. |
| 57 | Traffic patterns: 0 uniform (any other node, via `NODE ^ (1..15)`), 1 hot spot (`hot_pct/256` to `hot_node`, rest uniform), 2 transpose (diagonal nodes silent), 3 complement, 4 neighbour (x+1 mod 4); other codes behave like uniform. Offered load per node = 4*rate/65536 flits/cycle. | Standard NoC patterns. Hot-spot fraction measured within +-5%. |
| 58 | Zero-load latency law (measured, then used as a lower bound everywhere): `lat_net = distance + 4` cycles from the first cycle the header is offered to the cycle the tail is accepted at the sink (distance = Manhattan hops). | Each router costs one cycle (FIFO then combinational crossbar), tail follows 3 cycles behind the header. Any result below the bound is flagged as an error. |
| 59 | `packet_sink.ej_ready` is a registered random bit (`ready_thresh/256`, 255 = always, 0 = never); sink errors are counted per class: wrong destination, bad order/length/type, bad integrity word. | Decision 38 (ready must not depend on valid). |
| 60 | Generators and sinks carry 32-bit statistics counters (about 190 and 240 flip-flops each). They are test/demo hardware, not part of the router, and must be excluded from the HYSTERoC overhead comparison. | Resource criteria concern the router, controller and sideband. |
| 61 | `performance_monitor` only OBSERVES (active_mode, req_mode, inject_block_req, flit accept strobes, sink pulses). It does not use the controller's own statistics, so the measurement is independent of the thing measured. It also provides the shared `now` counter (0 in the first cycle after reset) for every generator and sink. | Spec 12/13. A statistic computed inside the controller could hide a controller bug. |
| 62 | Window: cycles `warmup .. warmup+measure-1` by `now`. Events use the cycle in which they are observed at the clock edge. A packet belongs to the window if the sink pulse (cycle after the tail is accepted) is inside it. Completed switch = the cycle the new `active_mode` is first visible. | One rule for every configuration (spec 12.3: identical timestamp conventions). |
| 63 | Ping-pong event: a completed switch whose previous completed switch was at most `T_PP` cycles earlier, both in the window; each switch is paired only with the one immediately before it (a run of n quick switches gives n-1 events). Consecutive switches always alternate direction, so each pair is an opposite pair. Four values (50,100,200,400) are counted at once. Dwell = the same gaps (sum, count, min, max). | Spec 12.2 asks for a consistently documented counting rule. `T_PP` is evaluation only, never an RTL filter. |
| 64 | Blocked period = first to last cycle of `inject_block_req = 1`; drain duration = its length in cycles (the last cycle is the one in which the new mode is visible and injection is released). Counted when the period starts in the window and has ended. Injection-blocked fraction = blocked cycles in the window / measure; this is also used as the transition-related lost-cycle measure for spec 12.5 (thresholds 5 % and 10 % reported by `metrics.py compare`). Requests: `blk_starts` (transitions started), `req_toggles` (raw changes of `req_mode`) and completed switches are reported separately. | Spec 12.3 asks for exact endpoints; a started transition always completes unless the watchdog fires, so starts = completions in a healthy run. |
| 65 | Latency in the RTL: count, sum, sum of squares and maximum of total and network latency (16 sink pulses per cycle, combinational loop). p99 is computed EXACTLY by `scripts/metrics.py` from the per-packet log (nearest rank, element ceil(0.99 n)); the RTL has no histogram. Standard deviation is the population standard deviation. | A histogram with 16 writes per cycle is not worth its cost; exact percentiles from the log are better evidence. |
| 66 | Progress watchdog in the monitor: `stall_cnt` counts consecutive cycles with flits inside the network (accepted minus delivered != 0) and no flit delivered; `stall_flag` is sticky at `STALL_LIMIT` (default 2000), `stall_max` = longest stall. A sink that is held not-ready for longer than the limit also raises it. Empirical stall evidence, not a deadlock proof. | Spec 12.3. |
| 67 | The monitor is MEASUREMENT hardware (Yosys rough: about 6,400 LUT, 1,300 FF, 32 DSP48, from 16 parallel squarers). It is for simulation; never add it to the synthesis sources of an overhead comparison or to the board design (batch 15 will use none or a reduced counter set). `tb/pm_log.vh` is simulation-only ($fopen/$fwrite) and writes `*_packets.csv`, `*_switches.csv`, `*_blocks.csv`, `*_summary.txt`; `scripts/metrics.py` (Python 3, standard library only) recomputes every metric from the CSV files and checks them against the RTL counters. | Keeps the router comparison clean. |
| 68 | Removed from `tb/`: `tb_crossbar.v` (written for the pre-batch-8 interface, no longer compiled; the crossbar is covered exhaustively in `tb_switch_allocator`) and `tb_route_dump.v` (helper). | Delete them from your copy too. |

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

### `route_select`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| active_mode | in | 1 | 0 XY, 1 adaptive |
| xy_port, oe_cand | in | 5 | from route_compute (one-hot / 1-2 bits) |
| occ_n/s/e/w | in | 3 | registered neighbour occupancy 0..4 |
| avail_n/s/e/w | in | 1 | 0 on mesh boundary |
| sel_port | out | 5 | one-hot or 0 |
| sel_valid | out | 1 | `|sel_port` |

### `packet_tracker` (one per input port)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | sync active-low reset |
| head_valid, head_type, head_data | in | 1/2/16 | FIFO head |
| route_port | in | 5 | from route_select (one-hot or 0) |
| xfer | in | 1 | head flit accepted this cycle (grant & ready & valid) |
| hdr_dst_x/y, hdr_src_x/y | out | 2 each | header fields |
| req_valid | out | 1 | head wants to move |
| req_port | out | 5 | requested output (one-hot, 0 if none) |
| req_new | out | 1 | request starts a packet (needs arbitration) |
| locked, locked_port | out | 1/5 | reservation state |
| proto_err | out | 1 | combinational protocol-violation flag |

### `switch_allocator` (one per router)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | arbiter pointers |
| req_valid, req_new | in | 5 | per input, from `packet_tracker` |
| req_port | in | 25 | input i at [5i+:5], one-hot |
| locked | in | 5 | per input |
| locked_port | in | 25 | input i at [5i+:5] |
| out_ready | in | 5 | downstream ready per output |
| in_grant | out | 5 | input i transfers this cycle (FIFO pop, tracker `xfer`) |
| xbar_sel | out | 25 | output o at [5o+:5], bit i = input i, zero if no transfer |
| out_busy | out | 5 | output has a reservation |
| alloc_err | out | 1 | illegal multiple owner/select |

### `crossbar`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| in_data / in_type | in | 80 / 10 | input i at [16i+:16] / [2i+:2] |
| sel | in | 25 | from allocator `xbar_sel` |
| out_data / out_type | out | 80 / 10 | output o likewise |
| out_valid | out | 5 | `|sel[o]` |

### `noc_router` (one per mesh node)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | |
| x_coord, y_coord | in | 2 each | position (x East, y South) |
| active_mode | in | 1 | global, 0 XY / 1 adaptive |
| ewma_enable | in | 1 | 0 freezes EWMA |
| in_data, in_type, in_valid | in | 80, 10, 5 | input link p at [16p+:16], [2p+:2], [p] |
| in_ready | out | 5 | FIFO ready_in |
| out_data, out_type, out_valid | out | 80, 10, 5 | |
| out_ready | in | 5 | |
| nbr_occ_in | in | 12 | neighbour occupancy N,S,E,W 3 bits each (registered inside) |
| nbr_avail | in | 4 | N,S,E,W, 0 on boundary |
| fifo_occ | out | 15 | five FIFO occupancies |
| router_empty | out | 1 | |
| ewma_out, cong_now | out | 8 | |
| max_occ_now | out | 3 | |
| proto_err, alloc_err | out | 1 | |

Port id order everywhere: N0 S1 E2 W3 L4.

### `drain_detector`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | |
| router_empty, src_empty, link_active | in | N=16 each | per node, same cycle |
| drained_now | out | 1 | combinational AND |
| network_drained | out | 1 | held CONFIRM cycles |

### `transition_controller` (one per network)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | |
| req_mode | in | 1 | from `hysteresis_controller` |
| inject_block_ack | in | 16 | one per source (level) |
| network_drained | in | 1 | from `drain_detector` |
| active_mode | out | 1 | THE shared mode register |
| inject_block_req | out | 1 | to all sources |
| ewma_enable, hys_enable | out | 1 | 1 only in RUN |
| transition_busy, drain_timeout | out | 1 | state != RUN, state == ERROR |
| state_o, target_mode_o | out | 3, 1 | status |
| cycle_cnt, tr_blocked, tr_ackwait, tr_drain, tot_blocked, tot_ackwait, tot_drain, transitions, t_block, t_ack, t_drained, t_switch, t_resume | out | 32 each | statistics (ENABLE_STATS) |

Parameters: `N_SRC` 16, `WATCHDOG_LIMIT_CYCLES` 1000, `POST_RESUME_MASK_CYCLES` 0, `ENABLE_STATS` 1. State codes: RUN 0, QUIESCE 1, WAIT 2, DRAIN 3, SWITCH 4, RESUME 5, ERROR 6.

### `noc_top`

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | |
| inj_data / inj_type / inj_valid | in | 256 / 32 / 16 | node n at [16n+:16] / [2n+:2] / [n] |
| inj_ready | out | 16 | |
| ej_data / ej_type / ej_valid | out | 256 / 32 / 16 | |
| ej_ready | in | 16 | must not depend on ej_valid combinationally |
| inject_block_req | out | 1 | to all sources |
| inject_block_ack, src_empty | in | 16 each | from the sources |
| active_mode, req_mode | out | 1 | |
| global_congestion, global_raw | out | 8 | max of 16 EWMA / of 16 unfiltered |
| transition_busy, drain_timeout, network_drained | out | 1 | |
| ctrl_state | out | 3 | |
| router_empty | out | 16 | |
| fifo_occ_all | out | 240 | router n at [15n+:15] |
| ewma_all | out | 128 | router n at [8n+:8] |
| proto_err_any, alloc_err_any | out | 1 | |
| cycle_cnt ... t_resume | out | 32 each | controller statistics (0 if ENABLE_STATS=0) |

Parameters: `XY_ONLY`, `DUAL`, `USE_EWMA`, `THIGH`, `TLOW`, `THRESH_SINGLE`, `SAMPLE_PERIOD`, `WATCHDOG_LIMIT_CYCLES`, `POST_RESUME_MASK_CYCLES`, `ENABLE_STATS`, `DRAIN_CONFIRM`.

### `traffic_generator` (one per node)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n, now | in | 1,1,32 | `now` shared counter |
| gen_enable, rate, pattern, hot_node, hot_pct, max_packets | in | 1,16,3,4,8,32 | run-time configuration |
| inj_data, inj_type, inj_valid | out | 16,2,1 | to router Local input |
| inj_ready | in | 1 | |
| inject_block_req | in | 1 | |
| inject_block_ack, src_empty | out | 1 | |
| create_pulse, create_dst, create_seq, flit_accept | out | 1,4,8,1 | observation |
| created, dropped, injected | out | 32 each | counters |
| q_count | out | 3 | queue occupancy |

Parameters: `NODE` (4*y+x), `SEED`, `QPTR_W` (2).

### `packet_sink` (one per node)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n, now | in | 1,1,32 | |
| ready_thresh | in | 8 | 255 always ready |
| ej_data, ej_type, ej_valid | in | 16,2,1 | |
| ej_ready | out | 1 | registered |
| pkt_done, pkt_src, pkt_pid, pkt_lat_total, pkt_lat_net | out | 1,4,8,16,16 | one-cycle pulse per good packet |
| pkts_ok, flits | out | 32 each | |
| err_dest_cnt, err_order_cnt, err_integ_cnt | out | 16 each | |
| err_any | out | 1 | |

Parameters: `NODE`, `SEED`.

### `performance_monitor` (one per system, simulation only)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1,1 | |
| warmup, measure | in | 32,32 | window start (cycle) and length |
| active_mode, req_mode, inject_block_req | in | 1 each | observed from `noc_top` |
| inj_xfer, ej_xfer | in | 16,16 | `valid & ready` of the 16 local ports |
| pkt_done, lat_total, lat_net | in | 16, 256, 256 | sink pulses and latencies (16 bit per node) |
| now, meas_en, meas_done, meas_cycles | out | 32,1,1,32 | time base and window |
| sw_total, w_switches, w_to_adapt, w_to_xy, w_req_toggles, w_blk_starts | out | 32 each | switching |
| w_pp0..w_pp3, w_dwell_cnt, w_dwell_sum(48), w_dwell_min, w_dwell_max, w_adapt_cycles | out | 32 | ping-pong and dwell |
| w_blocked, drain_cnt, drain_sum(48), drain_min, drain_max, blk_len_now | out | 32 | transition cost |
| w_pkts, w_lat_total_sum(48), w_lat_total_sq(64), w_lat_total_max(16), same for net | out | | packets and latency |
| w_inj_flits, w_ej_flits, pkts_total, inj_flits_total, ej_flits_total, inflight | out | 32 each | throughput and totals |
| stall_cnt, stall_max, stall_flag | out | 32,32,1 | progress watchdog |

Parameters: `PP0..PP3` (50, 100, 200, 400), `STALL_LIMIT` (2000).

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

## Verification evidence (batches 6 and 7)

- `tb_route_select`: 336,922 cases vs an independent model (35 directed incl. every tie pair; 320,000 exhaustive adaptive = 32 masks x 625 occupancies x 16 availabilities; 4,608 XY; 12,288 through real route_compute for every position). Mutants killed: tie `<=` on S and on N, availability ignored (adaptive and XY), highest instead of lowest, mode swapped, Local priority removed.
- `tb_packet_tracker`: 324,892 cycles compared with a model every cycle; directed T1-T10; 15,000 legal 4-flit packets at 5 load points (every packet exactly 4 flits, all on the port chosen at the accepted header); 120,000 random illegal cycles. Mutants killed: lock on stall, no release, release on body, continuation follows route_port, zero route accepted, xfer without valid counted, header-while-locked not flagged, swapped header field.
- Lint (Verilator -Wall) clean on route_select, packet_tracker, input_fifo. Regression of batches 1-7 passes.

## Verification evidence (batch 8)

- `tb_switch_allocator` Part A: 80,001 cycles of random raw vectors (legal-ish and fully random) vs an independent behavioural reference with its own round-robin pointers; directed cases (grant, no grant without ready, two owners raise `alloc_err`, busy output not offered).
- Part B: 5 FIFO-head emulators + 5 real `packet_tracker` + allocator + crossbar, 60,000 cycles, 25,021 legal packets, 5 load profiles (ready 15-100%). Checked: DUT = reference every cycle; one input per output; no transfer without ready; crossbar data/type = selected input; packets never interleave on an output; H,B,B,T leave on one output; per-input order, no loss, no duplication; every packet exactly 4 flits; reservation survives backpressure (68,900 stalled-reserved cycles). Fairness: 200/200/200/200/200 packets.
- Part C: crossbar exhaustive over all 6^5 select patterns.
- Mutants killed (10): busy ignored, advance always 1, ready ignored, owner ignores `req_valid`, busy forced 0, `alloc_err` forced 0, unmasked `xbar_sel`, crossbar data rotated, crossbar type dropped, crossbar valid forced 1, arbiter pointer frozen.
- Yosys (rough): `switch_allocator` incl. 5 arbiters about 320 LUT, 25 FF, 0 CARRY4 (first version used 20 CARRY4 for the sanity counters; replaced by adder-free `gt1`). `crossbar` about 185 LUT.

## Verification evidence (batch 9)

- `tb_noc_router`: 16 environments, one per mesh position, 20,000 cycles + drain each (86,666 packets total). Random legal 4-flit packets on all five inputs at five load profiles, random output ready (12-100%), random neighbour occupancy 0..4, EWMA freeze windows, mode flipped at random times with packets in flight (about 600 flips).
- Checked: per-input flit log (no loss, duplication, reorder, content intact); packets atomic on outputs, one output per packet, length 4; header output = XY port (independent), or in adaptive mode the lowest-occupancy available Odd-Even candidate from the TB's own copy of the one-cycle-old sideband with E,S,W,N ties; no valid without ready; no flit on a boundary link; `in_ready`/`fifo_occ` vs model; `router_empty` exact (including reservation with empty FIFO); `ewma_out` vs independent model incl. freeze; `cong_now`/`max_occ_now`; no `proto_err`/`alloc_err`; all delivered and `router_empty = 1` at the end.
- Mutants killed: sideband frozen, sideband not registered, EWMA enable ignored, `router_empty` ignoring reservations, mode inverted, FIFO never popped, neighbour occupancy swapped, x/y coordinates swapped, availability ignored in congestion estimate. Equivalent (not killable): removing `in_ready` from the FIFO push, because the FIFO already guards push-while-full.
- Yosys flattened (rough, NOT Vivado): about 810 LUT, 123 FF, 15 RAM32M, 9 CARRY4 per router; x16 is about 13k LUT, 2k FF for the mesh before the controller, sources and sinks.

## Verification evidence (batch 10)

- `tb_drain_detector`: all 48 single-bit blockers, CONFIRM = 1, 2, 3 side by side, confirm windows, blips, 60,000 random vectors, reset.
- `tb_transition_controller`: six environments, each with its own DUT, an independent cycle model written in terms of the blocked-cycle index k, and property checks every cycle. Directed: exact timeline (QUIESCE, WAIT, DRAIN, SWITCH, RESUME, RUN; durations 4/2/1), slow ack, slow drain, retarget ignored, SWITCH re-check, mask length; watchdog at LIMIT-1/LIMIT/LIMIT+1, ack too late, no ack, never drained, sticky ERROR, reset recovery. Random: 3 x 80,000 cycles with random requests, per-source ack delays, random drained levels, random resets (including out of ERROR). Every cycle: state, mode, outputs, 8 counters and 5 timestamps vs model; `active_mode` changes only after SWITCH with drained and is followed by RESUME; WAIT left only with all acks; DRAIN left only with drained; ERROR never left without reset.
- Mutants killed (18): switch without re-check, watchdog off by one, timeout forces switch, EWMA enabled in RESUME, retarget mid-drain, any-ack instead of all-ack, DRAIN skipped, ERROR not sticky, mask off by one, block dropped in SWITCH, block held in RESUME, hysteresis always enabled, switch before drained, no `wd_over` check; drain detector: link / confirm / source / router bits.
- Yosys (rough): `drain_detector` 19 LUT, 8 FF. `transition_controller` 37 FF, about 46 LUT with `ENABLE_STATS = 0`; 453 FF, about 170 LUT, 84 CARRY4 with statistics.
- NOT yet verified: behaviour with real sources and the real mesh (batches 11-14).

## Verification evidence (batch 11)

- `tb_noc_top`: four complete 4x4 meshes, 30,000 cycles of traffic + drain each: HYSTERoC (160/96, EWMA), XY-only, conventional single-threshold raw hybrid, Ablation A with mask 4 and CONFIRM 1. Behavioural sources obey the block/ack protocol; sinks have random ready. Five traffic phases (low uniform, hot spot with a slow sink, medium uniform, complement, near idle).
- Checked: every delivered packet reaches the node in its header, is H,B,B,T, tags match, exists once in the scoreboard (no loss, duplication, phantom, interleave); END-TO-END DRAIN CHECKS independent of the DUT (flits accepted from sources minus flits ejected): `network_drained` implies 0 in flight in every cycle, `active_mode` changes only when 0 in flight and all sources idle, no source drives valid in DRAIN/SWITCH; `global_congestion` = max of the 16 EWMA; EWMA frozen outside RUN; sideband wiring for all 16 x 4 directions every cycle; every router sees the shared `active_mode` and `ewma_enable`; no `proto_err`, `alloc_err`, `drain_timeout`; XY-only never changes mode; at the end all packets delivered, 4 flits in and out per packet, all routers empty, controller in RUN.
- Results (one run, seeds 101-104): HYSTERoC 15,740 packets, 106 mode changes; conventional raw hybrid 7,765 packets, 920 mode changes; Ablation A 14,076 packets, 250 mode changes; XY-only 19,689 packets, 0. These runs use different random streams and sources are blocked during transitions, so they are NOT a controlled comparison; the controlled comparison is batches 13-14.
- Mutants killed (9): E/W link data swapped, sideband from wrong FIFO, global max replaced by router 0, XY_ONLY ignored, ready wired to wrong port, `router_empty` forced 1, EWMA enable forced 1, controller sees drained = 1, one router with a private mode. Equivalent under the protocol (2): `link_active` ignoring router outputs, `src_empty` forced 1 (decision 52).
- Yosys, whole mesh flattened, `ENABLE_STATS=0` (rough, NOT Vivado): about 8,740 LUT, 192 RAM32M (LUT-RAM), 1,590 FF, 154 CARRY4.
- NOT yet verified: real traffic generator and sink (batch 12), performance monitor (13), Ablation B run, all workloads and baselines (14), Vivado synthesis/timing (15).

## Verification evidence (batch 12)

- `tb_traffic_generator`: six nodes (0,1,6,9,14,15). Every emitted flit parsed against the creation records (dst, src, pid, creation time, injection time, integrity); patterns (uniform flat and never self, hot-spot fraction, transpose / complement / neighbour exact, diagonal silent); backpressure stability, queue never above 4, `created = injected + queued + in progress` every cycle, drops; block protocol under random block pulses (no start while blocked, started packets finish, ack and src_empty exact); `max_packets`; disable; twin instance reproducible and a different seed differs; reset in the middle of a packet.
- `tb_packet_sink`: ready behaviour (always, never, about 50%, registered); exact latencies and one-cycle pulse; seven error classes counted exactly and resynchronisation; 80,000-cycle fuzz of legal and illegal flits against an independent model (counters, pulses and outputs every cycle).
- `tb_traffic_system`: noc_top + 16 real generators + 16 real sinks, HYSTERoC and XY-only, 20,000 cycles each + drain. Zero-load latency of four single packets (distances 6, 1, 2, 4) equals distance + 4 exactly; scoreboard from creation and delivery pulses (exactly once, right node); independent flit accounting with the same drain / mode-change checks as batch 11; all sink error counters 0; latency lower bounds; end state clean.
- Mutants killed (21): generator: block ignored, ack ignoring busy, tail constant, overwrite when full, transpose, complement, hot spot ignored, header src swapped, injection timestamp, `src_empty` constant, drops not counted, `max_packets` off by one, broken mod 15, data unstable while stalled; sink: destination, integrity, latency, truncation, pulse, ready threshold, early tail.
- Yosys (rough): generator about 205 LUT, 190 FF, 45 CARRY4 (mostly 32-bit counters); sink about 155 LUT, 240 FF, 37 CARRY4.
- NOT yet verified: performance monitor (batch 13), the controlled comparison (batch 14), Vivado.

## Verification evidence (batch 13)

- `tb_performance_monitor`: two monitor instances (default and small `PP`/`STALL_LIMIT`) with the same random stimulus; every cycle is recorded and an independent model scans the trace (not a copy of the RTL structure); about 45 outputs per instance compared. Scenarios: window at the start, middle, longer than the run, zero length, beyond the run, one cycle; 60-scenario sweep of the window start (a switch just before the window must not pair with one inside); switch gaps exactly at, one below and one above every `T_PP`; blocked periods with and without a mode change and one still open at the end; latencies up to 65,535; 16 simultaneous packets; long stalls and stalls of exactly 29/30/31 cycles. 74 scenarios, 0 errors.
- Mutants (18): 17 killed (ping-pong boundary, window start/end, dwell minimum, blocked-period window, drain sum, squared latency, latency max, stall reset, stall limit, direction, request toggle, total switches, in-flight, ejected flits, open block length, adaptive cycles); 1 equivalent (clearing the partner flag on a switch outside the window cannot matter because the window is contiguous).
- System run (`tb_traffic_system`, monitor wired in, window 1,000..18,999): the TB's own accumulators equal the monitor (packets, latency sums, flits, switches, blocked cycles, whole-run totals, in-flight); `drain_cnt` = block starts; `sw_total` = controller `transitions`. `metrics.py report` recomputes 26 values from the logs and all equal the RTL counters; a tampered summary makes it fail (exit 1). `metrics.py compare` and `csv` run.
- Yosys (rough): about 6,400 LUT, 1,300 FF, 616 CARRY4, 32 DSP48 (measurement only, decision 67).
- Full-mesh `tb_noc_top` re-run after the end-wait patch: PASS (4 meshes, 30,000 cycles).
- Observation, not a result: in the stress workload of `tb_traffic_system` (offered load far above saturation, thresholds `THIGH=160`, `TLOW=96`) HYSTERoC still made 47 completed switches in the window with minimum dwell 16 cycles and 35 ping-pong events at `T_PP=200`; mean total latency was 82 versus 69 for XY-only. This workload is not designed for the comparison and the numbers are not evidence either way, but it shows that the pilot step of spec 12.4 (workloads and parameter tuning before freezing) will matter in batch 14.

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
| `route_select` (5 per router) | 0 FF, about 37 LUT |
| `packet_tracker` (5 per router) | 6 FF, 17 LUT |
| `traffic_generator` / `packet_sink` (test hardware) | about 205 LUT, 190 FF / 155 LUT, 240 FF |
| `performance_monitor` (measurement only) | about 6,400 LUT, 1,300 FF, 32 DSP48 |

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
