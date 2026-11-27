# Decisions Log — HYSTERoC

This document records architectural decisions for the HYSTERoC network-on-chip. **Decision numbers are permanent.** Never renumber existing entries. Code comments cite these numbers directly (for example, `"DECISIONS 38"`). Add new decisions using the next available number.

---

## 1. Network model and packet format

### D1. 4×4 mesh, 2-bit coordinates, node `n = 4·y + x` — FROZEN
A 4×4 mesh allows complete verification of routing tables and candidate sets while creating multi-hop congestion. Two-bit coordinates represent positions 0 to 3. The coordinate x increases East, and y increases South.

### D2. Flit = `{type[1:0], data[15:0]}`; packet = exactly 4 flits — FROZEN
The packet structure uses Header + 2 Body + Tail flits. The second body flit allows verification of flit ordering and packet integrity (`tail = hdr ^ body1 ^ body2 ^ 16'hC3A5`) without requiring a dedicated length field. Variable packet lengths were evaluated and rejected because length fields add storage to every router without aiding routing evaluation. See D8 and D31 for length contract rationale.

### D3. Header field order `{dst_x, dst_y, src_x, src_y, pid}` — FROZEN
Destination fields occupy the most significant bits for direct routing decode. Source fields follow, enabling Odd–Even source-column rules and parity calculations. Packet identifier (`pid`) occupies the lowest bits and serves as a tracking key for the scoreboard.

### D4. Port identifiers N=0, S=1, E=2, W=3, Local=4 — FROZEN
Port identifiers define hardware port index mappings. The adaptive tie-break priority (East, South, West, North) is an independent decision. Both mappings are frozen in specification and kept distinct in `route_select.v`.

---

## 2. Router datapath

### D5. Input FIFO: depth 4, first-word fall-through, `ready_in = (count != DEPTH)` — FROZEN
Output `ready_in` depends only on registered `count`. It never depends on `pop`. A full FIFO does not accept a push during a pop cycle. Accepting pushes while full would introduce a combinational feedback path from downstream backpressure into upstream readiness. Illegal push and pop commands do not corrupt internal state.

### D6. Router outputs: `out_valid` asserted only when `out_ready` is 1 — FROZEN
Asserting `out_valid` only when `out_ready` is 1 ensures `valid && !ready` never occurs on inter-router links. The router automatically satisfies output hold rules, leaving hold verification only at ejection interfaces.

### D7. Packet-level reservation, round-robin arbitration, pointer updates on transfer
The allocator reserves output ports from header flits until tail flits transfer. Arbiter priority pointers update only when transfers complete. Round-robin arbitration prevents starvation without requiring complex weighting logic.

### D8. Type-driven routing without per-port flit counters
The module `packet_tracker` locks ports between header and tail flits using flit type bits. Routers do not count flits. Packet length is a contract enforced by sources. Packets longer than 4 flits route correctly because port reservation holds until the tail flit.

### D9. Neighbour occupancy is registered once (one cycle old)
Module `noc_router` registers incoming neighbour occupancies (`occ_q`). The congestion estimator and route selector read this same registered value. This decision removes comparators from the critical arrival path and prevents split decisions.

### D10. Boundary ports masked to zero with `any_avail` flag
Non-existent boundary directions contribute zero to occupancy calculations. The `any_avail` flag distinguishes an empty available neighbour from an unavailable boundary direction. Occupancy values above 4 clamp to 4 to preserve monotonic mapping.

---

## 3. Congestion estimation and hysteresis

### D11. Congestion signal = max neighbour FIFO occupancy, mapped 0, 64, 128, 192, 255 — FROZEN
Each router measures the maximum occupancy among the FIFOs it feeds. The 5-level mapping normalizes inputs for the EWMA filter and thresholds. Occupancy of 2 flits maps to 128, aligning with the default single-threshold baseline.

### D12. EWMA filter with α = 1/8, `S = 8·E`, `S_next = S − (S >> 3) + C` — FROZEN
This filter uses bit shifts rather than multipliers. The 11-bit state variable `S` cannot overflow for `C ≤ 255`. It requires no signed arithmetic. Setting `enable = 0` freezes filter state.

### D13. Global signal = maximum across 16 router EWMA estimates
A single network-wide controller reads the maximum congestion estimate across all 16 routers. The maximum reflects the worst localized congestion in the mesh. Average congestion was evaluated and rejected because it dilutes localized hotspots.

### D14. Dual thresholds THIGH=160 / TLOW=96, single threshold 128 for baseline
The range between `TLOW` and `THIGH` creates a dead band. When congestion oscillates inside this band, the controller performs zero mode switches. The single threshold of 128 serves as the baseline comparison point.

### D15. `req_mode` is advisory; `active_mode` has one writer
Module `hysteresis_controller` requests mode changes via `req_mode`. The transition controller decides when to execute mode switches. Setting `enable = 0` freezes requests during transitions.

---

## 4. Mode-switch policies

### D16. Drain-and-switch baseline (`SWITCH_POLICY = 0`)
Mode switches occur only when the network is drained: packet injection is blocked, sources acknowledge, and the mesh clears. Emptiness is re-checked during the switch cycle. This policy guarantees that packets encounter only one routing mode.

### D17. Transition FSM: latched target, level acknowledgments, safe timeouts
The state sequence follows `RUN → QUIESCE_REQUEST → WAIT_ACK → DRAIN → SWITCH → RESUME → RUN`. If the drain timer exceeds `WATCHDOG_LIMIT_CYCLES`, the FSM enters `ERROR`. Timeouts never force mode switches.

### D18. No-drain direct switching (`SWITCH_POLICY = 1`) uses shared Odd–Even turn rules
Module `mode_switch_direct` updates `active_mode` one cycle after `req_mode` changes without stopping packet injection. This policy is deadlock-free because deterministic modes (`oe_fixed`, `oe_par`, `oe_x21`) and adaptive modes all select from the legal Odd–Even turn set (`oe_cand`).

### D19. Deterministic Odd–Even variants: `oe_fixed`, `oe_par`, `oe_x21`
* `oe_fixed`: Deterministic baseline selecting Local > East > West > vertical.
* `oe_par`: Source parity variant. Nodes with even parity route vertical first.
* `oe_x21`: Balances vertical links between columns 1 and 2 by routing column 2 to column 1 packets vertically first.

### D20. Adaptive margin `ADAPT_MARGIN` (default 0 = disabled)
When `ADAPT_MARGIN = m > 0`, adaptive mode retains the deterministic port unless an alternative candidate has at least `m` fewer flits.

---

## 5. Bench and measurement

### D21. Open-loop packet creation, closed-loop injection
Module `traffic_generator` creates packets at specified rates. A full queue drops created packets and increments drop counters. Started packets always complete injection.

### D22. Packet timestamps using shared cycle counter; modulo 2¹⁶ latency
Timestamps capture creation and injection times. Queued packets keep their creation timestamps to record queue delay during injection blocks. Latency calculations use 16-bit modulo arithmetic.

### D23. Registered random readiness in `packet_sink`
Output `ej_ready` uses a registered pseudorandom bit. It never depends combinationally on `ej_valid`. This eliminates ready-valid combinational loops.

### D24. Passive performance monitoring
Module `performance_monitor` observes transactions and never drives network links. Measurements execute within a configured observation window after warmup.

### D25. Centralized global control
The design implements a centralized global controller to directly evaluate hysteresis dynamics. Router interfaces support future drop-in regional controllers.

### D26. Configurable transition performance counters
Setting `ENABLE_STATS = 0` removes thirteen 32-bit performance counters to evaluate core hardware resource overhead.

---

## 6. Verification decisions

### D27. Reference model in lockstep with RTL
Module `hy_model` re-implements the control path in SystemVerilog. It compares control outputs against DUT signals on every clock cycle.

### D28. Interface timing without clocking blocks
Signals drive after `@(posedge clk)` using non-blocking assignments. Signals sample in the active region of `@(posedge clk)`.

### D29. Emulated sources inside interface `hy_if`
Sources model busy and acknowledgment bits directly within `hy_if`. Knob `src_force_busy` allows tests to induce watchdog timeouts.

### D30. Simulation assertion of X-propagation
Concurrent assertion `a_no_x_control` verifies that control signals contain no X or Z states during simulation.

---

## 7. Stable in-code citations

The following citations in the RTL code map to the decision entries above:

| Code Citation | Topic | Decision Reference |
|---|---|---|
| DECISIONS 36 | Neighbour sideband registered one cycle old | D9 |
| DECISIONS 38 | Ready does not depend on valid; registered `ej_ready` | D5, D6, D23 |
| DECISIONS 41 | Definition of `src_empty` during injection blocks | D29 |
| DECISIONS 56 | Packet start rules in traffic generator and drivers | D21 |
| DECISIONS 58 | Zero-load latency equals distance plus 4 | D2 |
