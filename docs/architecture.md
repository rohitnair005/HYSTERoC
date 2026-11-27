# Architecture — HYSTERoC

This document is the technical architecture reference for the HYSTERoC network-on-chip design.

Conventions:
* **FROZEN**: Set by specification. Do not modify these values. Modifications invalidate calibration and test vectors.
* **DEFAULT**: Configurable parameter with a standard preset.

---

## 1. Network model

| Property | Value | Source |
|---|---|---|
| Mesh | 4×4 mesh (16 routers) | `hysteroc.vh` (`HY_MESH_DIM`, `HY_NUM_ROUTERS`) (FROZEN) |
| Coordinates | 2 bits each (0..3); x increases East, y increases South | Spec 3.1 (FROZEN) |
| Node identifier | `n = 4·y + x` | Used across all flattened vector ports |
| Ports per router | 5 ports: North=0, South=1, East=2, West=3, Local=4 | `HY_PORT_*` (FROZEN) |
| Flit size | 18 bits: `{flit_type[1:0], data[15:0]}` | Spec 4.1 (FROZEN) |
| Flit types | 00: Header, 01: Body, 10: Tail, 11: Reserved | Spec 4.1 (FROZEN) |
| Packet format | Header + 2 Body + Tail (4 flits total) | Spec 4.2 (FROZEN source contract) |
| Header fields | `{dst_x[15:14], dst_y[13:12], src_x[11:10], src_y[9:8], pid[7:0]}` | Spec 4.3 (FROZEN) |
| Input FIFO | Depth 4, first-word fall-through, `ready_in = (count != DEPTH)` | `input_fifo.v`, Spec 5.2 (FROZEN) |
| Link handshake | Hold `valid` and `data` stable while stalled. `ready` must not depend on `valid`. | Spec 3.2 |
| Router output rule | Assert `out_valid` only when `out_ready` is 1. | `noc_router.v` |

The router is **type-driven**. The `packet_tracker` module extracts the output port from the header flit. It maintains output port reservation until the tail flit arrives. Routers do not count flits.

---

## 2. Module catalogue

### 2.1 Router datapath (`rtl/router/`)

#### `input_fifo` (`input_fifo.v`)
Synchronous FIFO storing `{flit_type, data}`. The output `ready_in` depends only on the registered `count` register (`count != DEPTH`). It never depends on `pop`. A full FIFO does not accept a push during a pop cycle. This rule eliminates combinational feedback paths between routers. Illegal operations (push when full, pop when empty) cause no state corruption. When simultaneous push and pop occur, `count` remains unchanged while internal pointers advance.

#### `packet_tracker` (`packet_tracker.v`)
Instantiated once per input port. Parses destination coordinates (`dst_x`, `dst_y`) and source coordinates (`src_x`, `src_y`) from the header flit. Holds `locked` and `locked_port` active until the tail flit transfers. Sends `req_valid`, `req_new`, and `req_port` to `switch_allocator`. Asserts `proto_err` on invalid flit sequences.

#### `route_compute` (`route_compute.v`)
Pure combinational logic. Inputs: current router coordinates `(x, y)` and header coordinates `(dst_x, dst_y, src_x, src_y)`. Note that incoming direction is not used. Outputs are 5-bit one-hot port masks:

* `xy_port`: Deterministic XY routing. Routes along X first, then Y. Selects Local at destination.
* `oe_cand`: Candidate port mask under Odd–Even turn rules (1 or 2 ports).
* `oe_fixed`: Deterministic port from `oe_cand` using fixed priority: Local > East > West > vertical (`DET_VARIANT = 0`).
* `oe_par`: Source-parity selection. Sources with even parity (`src_x ⊕ src_y == 0`) choose vertical routing first when permitted (`DET_VARIANT = 1`).
* `oe_x21`: Balances column-1 and column-2 links. Packets from column 2 to column 1 route vertical first (`DET_VARIANT = 2`).

Candidate selection rules (`ex = dst_x − x`, `ey = dst_y − y`):

```
ex == 0, ey == 0 : Local port
ex == 0, ey != 0 : Vertical port toward destination
ex >  0, ey == 0 : East port
ex >  0, ey != 0 : Vertical if (x is odd) OR (x == src_x); East if (dst_x is odd) OR (ex != 1)
ex <  0          : West port; also vertical (if ey != 0) when x is even
```

Every candidate moves closer to the destination. Candidate sets are never empty.

#### `route_select` (`route_select.v`)
Selects an output port for each header flit:

| Mode (`active_mode`) | Port Selection |
|---|---|
| XY (0) | Selects `xy_port` after boundary checks. Ignores FIFO occupancy. |
| ADAPT (1) | Selects port from `oe_cand` with lowest neighbour FIFO occupancy. Breaks ties: East → South → West → North. |

Ports outside mesh boundaries are masked to unavailable. Selection may update while a header flit waits for arbitration.

Optional margin (`ADAPT_MARGIN = m`): In adaptive mode, retains the deterministic port unless another candidate has at least `m` fewer flits. Default `m = 0` (disabled).

#### `round_robin_arbiter` (`round_robin_arbiter.v`)
Arbiter for a single output port. Priority starts at pointer `ptr`. Requests evaluate in cyclic order starting from `ptr`. The pointer updates only when `advance` indicates an accepted transfer. The winner receives lowest priority in the subsequent cycle.

#### `switch_allocator` (`switch_allocator.v`)
Performs packet-level arbitration across five output ports using five round-robin arbiters. Active packets maintain port reservations until tail flits pass. Unreserved ports grant new requests. Emits FIFO pop signals (`in_grant`) and crossbar select lines (`xbar_sel`).

#### `crossbar` (`crossbar.v`)
Five-by-five multiplexer matrix. Connects input flits to destination output ports. Idle output ports transmit zeros. Flits cannot duplicate because the allocator assigns at most one input to each output.

#### `noc_router` (`noc_router.v`)
Combines the router datapath modules. Registers incoming neighbour FIFO occupancy (`occ_q`) once. Both the congestion estimator and route selector consume this registered value. Disables requests to non-existent boundary ports.

---

### 2.2 Global control path (`rtl/control/`)

All modules use Verilog-2001 with synchronous active-low reset (`rst_n`).

#### `congestion_estimator` (`congestion_estimator.v`)
Calculates `max_occ` across all available cardinal neighbours. Ignores boundary directions. Maps occupancy to standard congestion levels:

| FIFO occupancy | Mapped congestion level |
|---|---|
| 0 flits | 0 |
| 1 flit | 64 |
| 2 flits | 128 |
| 3 flits | 192 |
| 4 flits (full) | 255 |

#### `ewma_filter` (`ewma_filter.v`)
Fixed-point EWMA filter with weight α = 1/8:

$$\begin{aligned}
S_{\text{next}} &= S - (S \gg 3) + C \\
E &= S \gg 3
\end{aligned}$$

State variable `S` uses 11 unsigned bits. `S` cannot overflow when input `C ≤ 255`. Setting `enable = 0` freezes filter state.

#### `hysteresis_controller` (`hysteresis_controller.v`)
Generates mode requests (`req_mode`):

* `DUAL=1, USE_EWMA=1` (HYSTERoC): Switches to adaptive mode when `EWMA ≥ THIGH` (160). Switches to XY mode when `EWMA ≤ TLOW` (96). Retains current mode within the band.
* `DUAL=1, USE_EWMA=0` (Ablation B): Applies thresholds directly to raw congestion.
* `DUAL=0, USE_EWMA=1` (Ablation A): Switches based on single threshold (128) using EWMA values.
* `DUAL=0, USE_EWMA=0` (Conventional): Switches based on single threshold (128) using raw values.

#### `drain_detector` (`drain_detector.v`)
Monitors router emptiness, source emptiness, and link activity. Asserts `network_drained` when all routers, sources, and links remain empty for `CONFIRM` (default 2) consecutive cycles. Deasserts immediately when activity occurs.

#### `transition_controller` (`transition_controller.v`)
Implements the drain-and-switch state machine:

```
RUN ── req != active ──► QUIESCE_REQUEST ──► WAIT_ACK ── all acks ──► DRAIN
 ▲                                                                     │
 └─────────────────────── RESUME ◄── SWITCH ◄── network_drained ───────┘
                              (re-checked; returns to DRAIN if activity resumes)
```

1. Asserts `inject_block_req` to stop injection during transition.
2. Waits for all source nodes to acknowledge injection block (`WAIT_ACK`).
3. Waits for `network_drained` in `DRAIN`.
4. Updates `active_mode` in `SWITCH` only if `network_drained` remains true.
5. Unblocks packet injection in `RESUME`.
6. Transitions to sticky `ERROR` if `drain_timer` exceeds `WATCHDOG_LIMIT_CYCLES`.

#### `mode_switch_direct` (`mode_switch_direct.v`)
Implements no-drain switching (`SWITCH_POLICY = 1`). Updates `active_mode` one cycle after `req_mode` changes. Packets continue in-flight because deterministic and adaptive modes share Odd–Even turn rules.

---

### 2.3 Top-level mesh (`rtl/top/noc_top.v`)

Instantiates sixteen routers in a 4×4 grid. Node index calculation: `n = 4·y + x`.

Link interconnections:
* North output connects to South input of node `(x, y−1)`.
* South output connects to North input of node `(x, y+1)`.
* East output connects to West input of node `(x+1, y)`.
* West output connects to East input of node `(x−1, y)`.

Top-level logic computes global maximums across all sixteen routers for filtered and raw congestion.

---

### 2.4 Simulation testbench modules (`rtl/bench/`)

* `traffic_generator.v`: Packet generator for each node. Supports uniform, hotspot, transpose, complement, and neighbour traffic.
* `packet_sink.v`: Ejection endpoint. Verifies flit ordering, destination node, and packet checksums.
* `performance_monitor.v`: Passive monitor. Measures latency, throughput, completed switches, ping-pong events, and drain cycles.

---

## 3. Deadlock-safety argument

The design ensures freedom from routing deadlocks through the following properties:

1. **Odd–Even turn constraints:** Restricts turns to prevent cyclic channel dependencies. Packets moving East turn vertically only in odd columns or at the source column. Packets moving West turn vertically only in even columns.
2. **Drain-and-switch policy (`SWITCH_POLICY = 0`):** Mode changes execute only after all packets clear the mesh. No packet experiences two different routing policies.
3. **No-drain policy (`SWITCH_POLICY = 1`):** Both deterministic modes (`oe_fixed`, `oe_par`, `oe_x21`) and adaptive modes select from `oe_cand`. Turn restrictions apply continuously across mode changes.
4. **Wormhole packet reservation:** Output arbiters lock ports from header to tail flit. Packets cannot be preempted or interleaved on links.

---

## 4. Parameter reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `XY_ONLY` | bit | 0 | 1 = Forces XY mode; disables switching. |
| `DUAL` | bit | 1 | 1 = Dual-threshold hysteresis; 0 = Single threshold. |
| `USE_EWMA` | bit | 1 | 1 = Uses EWMA filtered signal; 0 = Uses raw signal. |
| `THIGH` | 8-bit | 160 | Upper threshold to trigger adaptive mode. |
| `TLOW` | 8-bit | 96 | Lower threshold to trigger deterministic mode. |
| `THRESH_SINGLE` | 8-bit | 128 | Single threshold for baseline hybrid mode. |
| `SAMPLE_PERIOD` | integer | 1 | Clock cycles between EWMA filter updates. |
| `WATCHDOG_LIMIT_CYCLES` | integer | 1000 | Maximum cycles before drain watchdog timeout. |
| `POST_RESUME_MASK_CYCLES` | integer | 0 | Cycles to freeze hysteresis after a switch. |
| `ENABLE_STATS` | bit | 1 | 0 = Removes transition performance counters. |
| `DRAIN_CONFIRM` | integer | 2 | Required consecutive idle cycles to confirm drain. |
| `SWITCH_POLICY` | bit | 0 | 0 = Drain-and-switch; 1 = No-drain direct switch. |
| `DET_VARIANT` | integer | 0 | Deterministic mode: 0 = `oe_fixed`, 1 = `oe_par`, 2 = `oe_x21`. |
| `ADAPT_MARGIN` | integer | 0 | Flit threshold margin to switch to alternative candidate. |

---

## 5. Verification summary

The UVM testbench in `tb/` verifies the complete system. The reference model (`hy_model.svh`) runs cycle-by-cycle alongside the RTL. It compares all control registers and flags. The scoreboard verifies packet delivery, packet order, and packet contents. Refer to [docs/verification.md](verification.md).

---

## 6. FPGA synthesis guidelines

`noc_top.v` synthesises without vendor macros. Do not synthesise modules in `rtl/bench/`.

Key synthesis recommendations:
* Map router FIFOs to distributed LUT RAM. Avoid dedicated block RAM (BRAM) for shallow 4-entry FIFOs.
* Set `ENABLE_STATS = 0` to reduce flip-flop usage during resource evaluations.
* Keep neighbour occupancy registered locally (`occ_q`) to maintain short critical paths. Refer to [docs/fpga.md](fpga.md).
