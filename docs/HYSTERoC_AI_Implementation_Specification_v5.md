# HYSTERoC — AI Implementation Specification

**Version 5.0 | 21 October 2026**  
**HDL target: Verilog `.v` files (not SystemVerilog `.sv`)**  
**Status: Version 5.0 implementation contract. Global quiescence-based drain-and-switch is selected; implementation and safety still require verification.**

## Instructions for the coding AI

Treat this document as the project contract. Use **Verilog HDL with `.v` files**, not SystemVerilog. Do not use SystemVerilog-only constructs such as `logic`, `always_ff`, `always_comb`, `typedef enum`, interfaces, packages, `int` declarations, or unpacked array ports unless the user explicitly approves a SystemVerilog change. Use Verilog-compatible `wire`, `reg`, `parameter`/`localparam`, `always @(*)`, `always @(posedge clk)`, `function`/`task` syntax and portable module ports. Choose a Verilog language standard supported by the target Vivado version and state the standard used.

Implement the **ACCEPTED / FROZEN** decisions in this document as fixed requirements. The implementation choices listed below are settled for the first complete implementation; do not stop to ask the user to reconfirm them. Where a point explicitly says “verification required,” implement the stated rule first and report verification evidence or failures; do not silently substitute a different algorithm. Produce synthesizable RTL, testbenches, compile/run commands, and a clear list of assumptions. Never claim deadlock freedom merely because simulation passes.

## 1. Project overview

### 1.1 Goal
HYSTERoC is a lightweight Network-on-Chip (NoC) implemented in FPGA programmable logic. Its research contribution is a hysteresis-based controller that requests transitions between deterministic XY routing and adaptive Odd-Even routing based on filtered congestion. The goal is to reduce routing-mode “ping-pong” under fluctuating congestion while maintaining a defensible deadlock-safety argument and acceptable FPGA resource/timing overhead.

### 1.2 Problem statement
Can a lightweight hysteresis-based controller, using an EWMA-filtered congestion estimate and dual thresholds, reduce routing-mode instability (the ping-pong effect) in a hybrid XY/Odd-Even NoC? Routing-mode transitions will use a global quiescence-based drain-and-switch protocol intended to preserve deadlock safety. The design will be evaluated against a conventional single-threshold hybrid router using switching-stability, packet-latency, throughput, drain-cost, and FPGA resource/timing metrics.

### 1.3 Scope
**In scope**
- 4×4 mesh NoC with 16 soft routers.
- Router input buffering, routing computation, arbitration, switching fabric, and ready/valid flow control.
- XY and Odd-Even route computation.
- Congestion estimation from FIFO occupancy, EWMA filtering and dual-threshold hysteresis.
- Simulation traffic generators, packet sinks/checkers, performance counters and testbenches.
- Vivado synthesis/implementation and FPGA demonstration, subject to final board selection.

**Out of scope initially**
- CPU/GPU cores or a full SoC. Traffic generators and receivers are test infrastructure, not processors.
- QoS classes, error correction/retransmission, power-management features and optional extras unless approved.
- Virtual channels initially unless the selected and justified safety policy requires them. A no-VC hybrid must not be assumed deadlock-free without proof.

## 2. Status labels
- **ACCEPTED / BASELINE:** Agreed project-level choice.
- **ACCEPTED:** Frozen implementation requirement.
- **VERIFICATION REQUIRED:** Implement the specified behavior and test it; do not pause to ask the user to decide it.
- **MEASURE LATER:** Tune or assess experimentally after a correct baseline works.

### V5 change summary
- Replaced the contradictory incoming-direction turn table in Section 5.4 with the explicit `ex`/`ey` candidate-output contract supplied for V5.
- Removed all requirements for an incoming-direction input from `route_compute.v`; defined inputs around current coordinates and source/destination columns.
- Added explicit candidate-generation conditions for `ex == 0`, `ex > 0`, and `ex < 0`, including parity/source/destination-column conditions.
- Added the mandatory nonempty-candidate property for every non-destination router, plus in-bounds/progress checks.
- Retained the Chiu-paper cross-check and channel-dependency-cycle check as mandatory verification gates; the table is not labelled proven canonical until they pass.
- Accepted packet-level output reservation and release-on-accepted-tail semantics.
- Froze the 16-bit header layout and occupancy normalization table.
- Froze the 11-bit unsigned EWMA recurrence, reset, default cadence, and directed test vector.
- Defined per-router local EWMA with a global maximum aggregator; freeze EWMA during transitions.
- Added all-16-source injection-block acknowledgement before draining; packets already being injected may finish.
- Added optional post-resume request masking (default 0), and confirmed watchdog timeout never forces a mode switch.
- Accepted conservative FIFO `ready = (count != 4)`.
- Added registered, one-cycle-old neighbor occupancy sideband with per-direction validity.
- Set raw occupancy threshold 128 for the conventional hybrid baseline.
- Added end-to-end latency from packet creation and secondary network latency.
- Added explicit logical module interface contracts and clarified injection-rate units.


## 3. Overall network architecture

### 3.1 Topology
- **ACCEPTED:** 4×4 2D mesh, 16 routers.
- **ACCEPTED:** Five logical ports per router: North, South, East, West, Local.
- Local connects to a simple test source/sink interface, not a CPU/GPU.
- Boundary ports pointing outside the mesh are unavailable and must never be selected.
- Coordinates are x=0..3 and y=0..3. **ACCEPTED:** x increases East; y increases South. This coordinate convention is frozen.
- Router coordinates should be parameters or explicit inputs.

### 3.2 Links
Each neighboring pair has two independent directed channels, A→B and B→A. Each direction carries `data[15:0]`, `flit_type[1:0]`, `valid`, `ready`. A transfer occurs on the rising edge when `valid && ready`. While `valid && !ready`, the sender holds `valid`, `data`, and `flit_type` stable.
- **ACCEPTED:** Wire links directly in `noc_top.v`. Do not add a separate link buffer/module unless needed to keep the RTL clear; if a purely combinational link helper is used, it must not add buffering or latency.

### 3.3 Proposed hierarchy
- `noc_top.v`: instantiates 16 routers and connects mesh links/local test endpoints.
- `noc_router.v`: one router instance.
- Testbench/demo modules: traffic generator, packet sink/checker, performance monitor.
- Shared definitions should use Verilog-compatible `include` files and macros/localparams rather than SystemVerilog packages.

## 4. Flits and packets

### 4.1 Width and type
- **ACCEPTED:** 16-bit data plus separate 2-bit flit-type metadata; 18 bits per flit excluding valid/ready.
- **ACCEPTED / FROZEN encoding:** `2'b00=header`, `2'b01=body`, `2'b10=tail`, `2'b11=reserved/invalid`.

### 4.2 Packet length
- **ACCEPTED baseline:** Four flits per packet: header, two body flits, tail.
- Body payload totals 32 bits, excluding header.
- Receiver tracks packet order and checks that the tail arrives in the expected position.
- **ACCEPTED / FROZEN:** Every packet is exactly four flits: one header, two body flits, one tail. Do not implement variable-length packets in this project.

### 4.3 16-bit header layout — ACCEPTED / FROZEN
- `[15:14]`: destination X (`dst_x`)
- `[13:12]`: destination Y (`dst_y`)
- `[11:10]`: source X (`src_x`)
- `[9:8]`: source Y (`src_y`)
- `[7:0]`: packet ID
Two bits per coordinate represent values 0–3. Preserve the source fields because the Odd-Even route function uses the source column. This layout is the RTL contract and must not change without explicit approval.

## 5. Internal router architecture

### 5.1 Logical datapath
1. Five input interfaces (N/S/E/W/Local).
2. Five input FIFOs.
3. Header parsing and packet tracking.
4. Route computation: XY or Odd-Even legal candidates.
5. Route selection and switch allocation/arbitration.
6. 5×5 crossbar.
7. Five output interfaces with ready/valid.

The congestion estimator and hysteresis controller are parallel control logic; they do not sit in the serial path of every flit. Their outputs influence route selection and mode-control logic.

### 5.2 FIFOs
- **ACCEPTED:** One FIFO per input, depth 4 flits.
- Five FIFOs/router; 20 slots/router; 80 FIFOs and 320 slots across 16 routers.
- Occupancy is 0..4, so use 3 bits.
- Raw data storage = 320 bits/router; data plus 2-bit type = 360 bits/router, excluding control state.
- Correctly handle empty/full, wraparound, simultaneous enqueue/dequeue and backpressure.
- **ACCEPTED FIFO policy:** `ready = (count != 4)`. A full FIFO does not accept a new flit even if a pop occurs in the same cycle. This avoids a combinational ready path through the router. Verify simultaneous push/pop and corner cases in the FIFO testbench.

### 5.3 Header and packet tracking
Parse destination from the header. Track packet progress and, if packet-level output reservation is used, which output is owned by each input/packet. Body and tail must not be independently rerouted if a packet is expected to use one path. Stalls must not cause loss, duplication, reordering or premature reservation release.

### 5.4 Routing computation — frozen `ex`/`ey` candidate contract (V5)

Use the coordinate convention from Section 3.1: `x` increases East and `y` increases South. For a router at `(x,y)` and packet destination `(dst_x,dst_y)`, compute signed offsets:

- `ex = dst_x - x`: horizontal displacement; positive means East, negative means West, zero means same column.
- `ey = dst_y - y`: vertical displacement; positive means South, negative means North, zero means same row.
- `src_x` and `dst_x` come from the packet header. Column parity is determined by the least-significant bit: even if `column[0] == 0`, odd if `column[0] == 1`.

**Do not use an incoming-direction input.** The route-computation contract is based on `ex`, `ey`, the current column `x`, source column `src_x`, and destination column `dst_x`. The implementation must not try to infer or require which physical input port the packet arrived through. Do not describe turns using wording such as “the packet arrives from East”; use the candidate conditions below instead.

For **adaptive Odd-Even candidate generation**, implement this table as written. “Vertical toward destination” means South when `ey > 0` and North when `ey < 0`.

| Case | Legal candidate output(s) |
|---|---|
| `ex == 0 && ey == 0` | Local only |
| `ex == 0 && ey != 0` | Vertical toward destination |
| `ex > 0 && ey == 0` | East |
| `ex > 0 && ey != 0` | Include vertical toward destination if `(x is odd) OR (x == src_x)`. Include East if `(dst_x is odd) OR (ex != 1)`. Apply both tests independently; the legal candidate set may contain one or both outputs. |
| `ex < 0` | Include West. If `ey != 0`, also include vertical toward destination when `x is even`. |

This is the frozen **candidate-generation contract**, not permission to claim the algorithm has already been proven canonical. First remove any output that leaves the mesh. At the destination, the only output is Local. In XY mode, retain deterministic X-first, then Y routing; the table above applies to adaptive Odd-Even candidate generation.

Implement `route_compute.v` with inputs sufficient to derive `ex`, `ey`, current `x/y`, `src_x`, and `dst_x`, and with an explicit legal-output/candidate representation (for example, one bit per output). Use ordinary Verilog `.v` syntax. Do not add an incoming-direction input. For packet-level output reservation, compute and latch the selected route at the header transfer and keep that route for the packet through its accepted tail.

**Mandatory Chiu cross-check:** the `ex`/`ey` table above is supplied as the project's implementation contract, but the source/destination-column conditions must still be checked against Chiu's original Odd-Even paper before calling the implementation canonical Odd-Even. Do not silently replace the table with a remembered or improvised variant. If the reference paper contradicts this contract, implement the exact paper rule in a documented correction and report the discrepancy; do not stop to ask the user to decide. Until the cross-check and verification pass, label the implementation “Odd-Even candidate implementation under verification,” not proven deadlock-free.

**Required exhaustive property:** for every valid source/destination pair and every router coordinate in the 4×4 mesh, the candidate set must be nonempty whenever the packet is not at its destination. Also verify every candidate is in-bounds and makes progress toward the destination. Test all source/destination pairs, compare allowed/forbidden cases with Chiu's paper, and check the channel-dependency graph for cycles before making a deadlock-freedom claim. A nonempty candidate set alone does not prove deadlock freedom.

All modes must remove directions that leave the mesh or do not progress toward the destination. At destination, route to Local.
### 5.5 Route selection
- XY mode: select the XY output.
- Adaptive mode: select among legal Odd-Even candidates using downstream congestion.
- **ACCEPTED:** Use occupancy of the neighbor input FIFO that receives the transfer.
- **ACCEPTED / FROZEN tie-break order:** East, South, West, North. This is separate from round-robin arbitration.
- Mode requests are applied only by the global quiescence-based drain-and-switch controller in Section 7.

### 5.6 Arbitration and crossbar
- **ACCEPTED:** Round-robin arbitration per output.
- At most one input is granted to an output in a cycle.
- Advance the arbiter pointer only when the granted transfer actually occurs, unless allocator semantics are explicitly documented otherwise.
- Crossbar grants must not cause input/output conflicts.
- **ACCEPTED:** Packet-level output reservation. A packet owns its selected output from successful header transfer until successful tail transfer.
- A stalled header reserves nothing; reservation starts only when the header transfers (`valid && ready`).
- Body and tail flits carry no destination and must follow the header's path.
- Release reservation only when the tail transfer is accepted (`valid && ready`). Advance the arbiter pointer only when a transfer actually occurs.
- No competing input may use a reserved output; ownership remains stable under backpressure.
- **ACCEPTED:** 5×5 crossbar.

## 6. Congestion estimator, EWMA and hysteresis

### 6.1 Measurement
- **ACCEPTED:** Router-wide sample is the maximum occupancy among available cardinal downstream FIFOs (N/S/E/W).
- The relevant FIFO is the neighbor's input FIFO facing this router.
- Exclude nonexistent boundary directions and exclude Local.
- **ACCEPTED:** Neighbor occupancy is exposed through the registered one-cycle-old sideband interface specified in Section 9.4. Sample every cycle by default (`SAMPLE_PERIOD=1`); use explicit direction-valid/available signals and exclude unavailable boundary directions.

### 6.2 Occupancy mapping — ACCEPTED / FROZEN
Use this exact 8-bit mapping for FIFO depth 4; do not substitute `floor(occupancy*255/4)`:
- occupancy 0 → 0
- occupancy 1 → 64
- occupancy 2 → 128
- occupancy 3 → 192
- occupancy 4 → 255
Implement the mapping explicitly and test all five values.

### 6.3 EWMA — ACCEPTED RECURRENCE
Store `S = 8 × E` as an 11-bit unsigned value and update it using:
```verilog
S_next = S - (S >> 3) + C;
E      = S >> 3;
```
where `C` is the current 8-bit congestion sample and `E` is the 8-bit filtered estimate.
- Reset `S = 0`.
- Update every cycle by default, controlled by `SAMPLE_PERIOD`; default `SAMPLE_PERIOD = 1`.
- Use this recurrence exactly; do not implement a signed subtraction of `C-E`.
- Use explicit width-safe intermediate signals. `S` is 11 bits, with maximum representable value 2047.
- `E = S >> 3` truncates fractional bits. For constant input `C`, `E` settles exactly at `C`.
- Directed test vector: with constant `C = 255` from reset, `S` begins `255, 479, 675, ...` and `E` begins `31, 59, 84, ...`.
- Test constant inputs, steps up/down, reset, sample-period behavior, and arithmetic boundaries.

### 6.4 Hysteresis controller
- **ACCEPTED initial parameters:** `THIGH=160`, `TLOW=96`, configurable. These are provisional and require evaluation.
- XY → adaptive Odd-Even request when filtered estimate `>= THIGH`.
- Adaptive Odd-Even → XY request when estimate `<= TLOW`.
- Between thresholds, retain current requested mode.
- Reset requested mode to XY.
- Require `TLOW < THIGH`.
- Expose mode/state and a separate `mode_change_request`. A request is not permission to switch immediately; the safety policy determines when it can apply.

### 6.5 Local congestion sensing and global controller — ACCEPTED
- Each of the 16 routers maintains its own local congestion estimator and EWMA state.
- One global hysteresis controller receives the maximum of the 16 local 8-bit EWMA estimates: `global_congestion = max(EWMA_0, ..., EWMA_15)`.
- The global controller applies the dual thresholds and generates a latched target-mode request.
- All routers share one global `active_mode`; routers must not update it independently.
- Freeze local EWMA state updates while the global controller is outside `RUN`.
- Do not retarget a transition in progress. This aggregation policy is frozen for the initial implementation.

## 7. Deadlock safety — selected global quiescence-based drain-and-switch policy

### 7.1 Decision and rationale
- **SELECTED PROJECT POLICY:** Use a **global quiescence-based drain-and-switch protocol** for every active routing-mode transition.
- The protocol is separate from EWMA/hysteresis: the controller requests a mode change; the safety FSM decides when it may be applied.
- Hysteresis is intended to reduce unnecessary transitions. Global quiescence controls the transition itself. Neither mechanism alone proves deadlock freedom.
- Do not claim that arbitrary XY/Odd-Even mixing is deadlock-free. The mode must not change while packets or flits remain in flight.
- The implementation must preserve the ability of already-admitted traffic to progress while new packet injection is blocked.

### 7.2 Required global transition sequence
Implement one global FSM with the following logical states (state encoding is implementation-defined):
1. `RUN`: normal injection, forwarding, ejection and congestion monitoring.
2. `QUIESCE_REQUEST`: latch the requested target mode and assert the global injection-block request.
3. `WAIT_ACK`: wait until all 16 source interfaces acknowledge blocking. Each source stops starting new packets, but a packet whose injection has already started is allowed to finish.
4. `DRAIN`: continue forwarding/ejecting all already-admitted traffic. Wait for the complete network-drained condition.
5. `SWITCH`: atomically update the shared active mode only after drained is confirmed.
6. `RESUME`: release injection blocking; optionally mask new mode requests for `POST_RESUME_MASK_CYCLES` (default 0), then return to `RUN`.
7. `ERROR/WATCHDOG`: report that draining did not complete within the configured limit. **Never force a mode switch on timeout.**

Freeze every local EWMA state whenever the global controller is outside `RUN`, including quiesce, acknowledgement wait, drain, switch, and optional resume-mask states. Do not retarget an in-progress transition. The post-resume mask is configurable and must be evaluated; it is not assumed to solve false switch-back by itself.

The exact number of RTL states may vary, but the externally observable sequence and safety requirements must be preserved.

### 7.3 Definition of global quiescence / drained
The `network_drained` condition must include all state that can hold a flit or prevent a packet from completing, including:
- all five input FIFOs in every router;
- any registered crossbar/output stage, skid buffer or link pipeline;
- valid transfers currently pending at router links;
- packet-level output reservations/locks, if implemented;
- endpoint/source queues for packets already admitted into the NoC;
- any other buffering or in-flight state added by the implementation.

New packet admission must be blocked without blocking internal forwarding or destination ejection of already-admitted traffic. The injection-block request is not effective until all 16 sources acknowledge it. A source acknowledgement means it will not start another packet; any packet whose injection had already begun is allowed to finish injecting.

The drain detector must include all router FIFOs, registered crossbar/output stages, skid buffers, pending valid link transfers, active packet reservations, and source/endpoint queues containing already-admitted packets. Empty FIFOs alone are insufficient if a flit remains in a pipeline or a reservation remains active.

Generate `network_drained` from a race-free network-wide reduction. Define the drain timer start as the cycle the injection-block request is asserted. Separately record acknowledgement completion, network-drained assertion, mode-switch cycle, and resume cycle. Report total transition-blocked duration and pure drain duration.

### 7.4 Pending requests and watchdog
- **ACCEPTED default:** `WATCHDOG_LIMIT_CYCLES = 1000`, configurable as a parameter. Start the watchdog when `inject_block_req` is asserted; timeout if `network_drained` has not become true within the configured limit. Count the exact cycle convention in the testbench and use it consistently.
- **ACCEPTED ERROR behavior:** `ERROR/WATCHDOG` is sticky until reset. On timeout, assert `drain_timeout`/error status, keep `inject_block_req` asserted (injection remains blocked), preserve the pre-transition `active_mode`, and do not switch modes or automatically resume. Reset is the only recovery mechanism in the initial implementation. The testbench must confirm this behavior.
- Latch one target mode for the duration of a transition.
- If congestion changes while draining, do not retarget the active transition mid-drain. Finish the requested safe transition, resume traffic, then reevaluate the filtered congestion estimate after the configured post-resume mask.
- Freeze all local EWMA states while the global controller is outside `RUN`.
- The watchdog raises an error/status flag and preserves the current active mode if draining times out.
- Count total injection-blocked cycles, acknowledgement-wait cycles, pure drain duration, and completed mode transitions.
- Ensure all routers observe one consistent global active mode. Do not independently update router mode registers at different times.

### 7.5 Safety obligations and limitations
Global drain-and-switch is the selected policy, but it is not by itself a complete proof of deadlock freedom. The project must verify and document:
- the selected Odd-Even routing truth table and its deadlock-avoidance assumptions;
- that admitted traffic can continue progressing under the current mode during drain, subject to stated fairness and endpoint assumptions;
- that the drain detector covers every FIFO, pipeline, endpoint queue and reservation;
- that no mode update can occur while `network_drained` is false;
- that a watchdog timeout cannot force an unsafe transition;
- that packet order and packet integrity are preserved through quiescence and resume.

Add an assertion or equivalent procedural checker for:
```verilog
/* Pseudocode property; express in syntax supported by the chosen Verilog simulator:
   if active_mode changes, network_drained must be true. */
```
Also check that injection is blocked during quiescence and that the drained signal implies no flit is valid or stored anywhere included in the network model.

Report zero deadlocks in simulation as **observed for the tested workloads and seeds**, not as a universal proof. Include a written safety argument and state any assumptions.

### 7.6 Comparison fairness
Every hybrid configuration used for the primary comparison must use the same global drain-and-switch protocol. Otherwise, differences in performance may be caused by different safety mechanisms rather than the controller. XY-only does not need a transition drain if it never changes mode; mark transition-only metrics as not applicable for that reference.

## 8. Proposed RTL file inventory (whole project)

The following is the planned module inventory across implementation phases, not one phase only. Testbenches and constraints add further files.

1. `hysteroc_defs.vh` — shared macros, port IDs, flit types and constants (Verilog include file).
2. `input_fifo.v` — parameterized synchronous FIFO storing `{flit_type,data}`.
3. `congestion_estimator.v` — occupancy sampling and normalization.
4. `ewma_filter.v` — fixed-point EWMA, separate for independent tests.
5. `hysteresis_controller.v` — dual-threshold request/state machine.
6. `route_compute.v` — XY and Odd-Even candidate generation without unapproved transition policy.
7. `round_robin_arbiter.v` — parameterized arbiter.
8. `crossbar.v` — 5×5 switching fabric or equivalent explicit mux logic.
9. `noc_router.v` — integrates one router.
10. `noc_top.v` — connects the 4×4 mesh.
11. Testbench/demo files: traffic generator, packet sink/checker, performance monitor.
12. Unit and system testbenches for all major modules.
13. FPGA integration files as needed: board top wrapper, `.xdc` constraints, Vivado project/scripts, README and `DECISIONS.md`.

Do not put the entire design into one giant module. Keep interfaces explicit and blocks independently testable.

## 9. Module interface contract

Before integrated RTL is written, create a port table in `DECISIONS.md` and keep all modules consistent with it. Exact flattened signal names may vary, but semantics and widths below are required. Use ordinary Verilog ports, not SystemVerilog interfaces or unpacked array ports.

### 9.1 `input_fifo.v`
Logical ports: `clk`, `rst_n`, `push`, `pop`, `data_in[15:0]`, `type_in[1:0]`, `data_out[15:0]`, `type_out[1:0]`, `valid_out`, `ready_in`, and `occupancy[2:0]`. Define `pop` only for an accepted downstream transfer. Implement conservative full behavior `ready_in = (count != 4)`.

### 9.2 `noc_router.v`
Logical interface groups:
- Clock/reset and router coordinates (`x_coord`, `y_coord`).
- Five incoming and five outgoing links, each with `data[15:0]`, `flit_type[1:0]`, `valid`, and `ready`.
- Five local 3-bit FIFO occupancy values or equivalent signals for drain detection.
- One registered 3-bit downstream-neighbor occupancy value per cardinal direction, plus an availability/validity signal for each direction. Values are one cycle old and must be used consistently for congestion estimation and adaptive route choice.
- Shared global `active_mode` input.
- `router_empty`/drained contribution, true only when all local FIFOs, reservations, and internal pipeline state are empty.

### 9.3 `noc_top.v` and global transition controller
Required logical signals:
- `global_congestion[7:0] = max(EWMA_0, ..., EWMA_15)`.
- Latched `target_mode`/mode request.
- One shared `active_mode`, updated atomically only in `SWITCH` when `network_drained` is true.
- `inject_block_req` to all 16 sources and `inject_block_ack[15:0]` or equivalent explicit acknowledgement wiring.
- `network_drained`, `transition_busy`, `drain_timeout`, and counters for blocked cycles and drain duration.
- Source acknowledgement occurs only after the source stops starting packets and any already-started injection packet finishes.
- `network_drained` includes all FIFO, pipeline/link, reservation, and already-admitted endpoint/source queue state.

### 9.4 Registered neighbor occupancy sideband
Expose a registered 3-bit `occ` value for each cardinal neighbor direction, one cycle stale, with an explicit direction-available/valid signal. Boundary directions must be marked unavailable and excluded from the congestion maximum and route candidates. Do not treat an unavailable direction as occupancy zero without a validity bit.

## 10. Interface and reset conventions
- `clk`: rising-edge clock.
- `rst_n`: synchronous active-low reset.
- Link payload: `data[15:0]`, `flit_type[1:0]`, `valid`, `ready`.
- Transfer iff `valid && ready` at rising edge.
- While `valid && !ready`, hold `valid`, data and type stable.
- FIFO occupancy: 3 bits (0..4).
- Single clock domain initially.
- Use Verilog-compatible `wire`/`reg`, `always @(*)`, `always @(posedge clk)` and portable module ports.
- Do not use SystemVerilog packages, `logic`, `always_ff`, `always_comb`, interfaces, `typedef enum`, `int` declarations or unpacked array ports.
- Avoid vendor primitives initially; use portable Verilog compatible with the target Vivado version.

## 11. Verification plan

### 11.1 Unit tests
- FIFO: empty/full, wraparound, order, simultaneous push/pop, backpressure, reset.
- EWMA: constant input, step up/down, reset, arithmetic edge cases, expected fixed-point values.
- Congestion estimator: each mapping, max across available directions, boundary exclusion, all directions unavailable.
- Hysteresis: below/equal/above high threshold; between thresholds; below/equal/above low threshold; repeated fluctuations; reset; stable inside hysteresis band.
- Arbiter: single/multiple requests, fairness, pointer advances only on accepted transfer, no double grant.
- Routing: every source/destination pair, all router coordinates, boundaries, Local destination, and Odd-Even legality. The route-computation module must not expose an incoming-direction input; implement the V5 `ex`/`ey` candidate table and exhaustively assert that candidates are nonempty off-destination, in-bounds, and make progress.

### 11.2 Router/system tests
- Adjacent-router packet; horizontal, vertical and mixed multi-hop packets.
- All destinations in 4×4 mesh.
- Multiple simultaneous sources contending for one output.
- Backpressure and full downstream FIFO.
- No loss, duplication or reordering; correct destination; correct header/body/tail sequence.
- Congestion rise/fall and hysteresis response.
- Boundary routers and Local delivery.
- Uniform random, hotspot, transpose and phased low/high congestion traffic.
- Safety tests for each mode-transition policy.

### 11.3 Assertions/scoreboard expectations
Where supported, check: no multiple grants to one output; no FIFO underflow/overflow; stable output data while valid and not ready; packet type order; release reservation only on accepted tail; no invalid boundary route; no illegal Odd-Even turn. Eventual delivery requires explicit fairness and traffic assumptions. Simulation does not replace a deadlock-freedom argument.

## 12. Performance evaluation, ping-pong definitions and acceptance criteria

### 12.1 Primary comparison configurations
Use the same topology, flit/packet format, FIFO depth, arbitration, transition protocol, traffic patterns, random seeds, warm-up period and measurement window for each applicable design.

1. **XY-only reference:** deterministic XY routing; no mode transitions.
2. **Conventional threshold hybrid baseline:** one threshold on the raw maximum-occupancy value, `128`; occupancy 2 or greater requests adaptive mode. Use the same global drain-and-switch protocol. This is the initial frozen baseline; document any change after pilot testing and before final comparative runs.
3. **Ablation A:** single threshold on the EWMA value; same transition protocol.
4. **Ablation B:** dual thresholds on raw occupancy, without EWMA; same transition protocol.
5. **HYSTERoC:** EWMA plus dual thresholds; same transition protocol.

Do not compare against an unsafe or incomplete baseline. Record all configuration parameters in the results.

### 12.2 Network-wide switching metrics
Because the active routing mode is global, count completed mode changes at the network level.

- **Switch rate:** number of completed global mode switches per 1,000 simulation cycles:
  `switch_rate = completed_mode_switches * 1000 / measured_cycles`.
- **Ping-pong event:** a completed mode switch followed by the opposite completed switch within `T_PP` cycles. Count and document the event-counting rule consistently. A switch from XY to Odd-Even followed by a return to XY within the window is one reversal event.
- **Default `T_PP`:** 200 cycles for initial analysis.
- **Sensitivity sweep:** repeat the ping-pong analysis with `T_PP = 50, 100, 200, 400` cycles. These are project measurement settings, not industry standards.
- **Dwell time:** cycles between consecutive completed mode switches; report mean and minimum.
- **Switch request count vs completed switch count:** report separately so time spent waiting for quiescence is visible.

Do not use `T_PP` as an RTL dwell-time filter unless explicitly approved. It is primarily an evaluation window.

### 12.3 Drain and performance metrics
- **Drain duration:** cycles from the defined start of injection blocking to the defined successful switch/resume endpoint. State the exact endpoints in scripts and reports.
- **Injection-blocked fraction:** total cycles in which new packet injection is blocked divided by total measured cycles.
- **End-to-end packet latency (primary):** destination delivery/ejection cycle minus packet creation cycle, including source-queue waiting while injection is blocked.
- **Network latency (secondary):** destination delivery/ejection cycle minus packet injection-acceptance cycle; report separately because it excludes source-queue waiting.
- Use identical timestamp conventions across all configurations.
- **Latency stability:** mean, p99, and standard deviation of packet latency.
- **Throughput:** delivered packets or flits per cycle; state which unit is used and the measurement window.
- **Packet integrity:** counts of lost, duplicated, corrupted, and reordered packets.
- **Progress/deadlock watchdog:** cycles without forward progress while traffic remains outstanding. A watchdog timeout is a detected stall, not automatically a formal proof of deadlock.

### 12.4 Workloads and repeatability
Initial proposed workloads:
- uniform random;
- hotspot;
- transpose;
- bursty/phased low-to-high and high-to-low congestion;
- deliberately oscillating traffic designed to exercise threshold crossings.

Initial injection rates are `0.05`, `0.10`, and `0.20` **flits per router per cycle**, not packets per router per cycle; each packet has four flits. With depth-4 FIFOs, these rates may not cross the high threshold in every workload. Run a pilot; if occupancy rarely reaches 3 or higher, add higher rates and/or bursty traffic before freezing the final workloads. Initial run length is 20,000 cycles per workload. These are proposed settings, not results. Record deterministic seeds and use the same seeds for all applicable configurations.

Define and record warm-up cycles, measurement cycles, traffic distribution, destination selection, packet ID policy, and random seed.

### 12.5 Project success criteria
These are project-defined acceptance targets, not universal industry standards. Confirm feasibility after initial synthesis and pilot simulation, then freeze before final comparison.

**Behavioural targets**
- At least **50% reduction in switch rate** versus the conventional single-threshold hybrid baseline on designated oscillating workloads.
- At least **50% reduction in ping-pong event count** versus that baseline on the same workloads.
- Mean packet latency no more than **5% worse** than baseline.
- p99 packet latency **no worse** than baseline.
- Zero observed lost, duplicated, corrupted or reordered packets.
- Zero observed deadlocks/stall-watchdog failures across the agreed test seeds and workloads, with watchdog active. Report this as empirical evidence, not a universal mathematical guarantee.

**Transition-cost target**
- Report injection-blocked fraction and drain duration for every hybrid configuration.
- A tentative target of less than 5% transition-related lost cycles was discussed. A measured value of 5–10% should trigger investigation; more than 10% may be unsuitable. These are project goals, not standards. Define the exact calculation before final runs.

### 12.6 FPGA overhead criteria
Compare HYSTERoC with the conventional single-threshold hybrid baseline using the same target FPGA, constraints, Vivado version/settings, clock target and synthesis/implementation flow.

- LUT increase: **at most 10%**.
- Flip-flop (FF) increase: **at most 10%**.
- `Fmax` reduction: **at most 5%**.
- Additional BRAM: **zero**.
- Report LUT, FF, BRAM, timing slack, critical path and `Fmax`; report power only if a documented activity-based estimate is available.

These are project-defined criteria, not industry standards. Perform a pilot synthesis to check feasibility, then freeze limits before final comparisons. Do not revise limits after seeing final comparative results without clearly labelling the change.

Calculate:
```text
LUT overhead (%) = (LUT_HYSTEROC - LUT_BASELINE) / LUT_BASELINE * 100
FF overhead (%)  = (FF_HYSTEROC  - FF_BASELINE)  / FF_BASELINE  * 100
Fmax drop (%)     = (Fmax_BASELINE - Fmax_HYSTEROC) / Fmax_BASELINE * 100
```
If a baseline resource count is zero, report the absolute change instead of dividing by zero.

### 12.7 Results integrity
- Do not fabricate metrics or synthesis results.
- If tools are unavailable, provide scripts and mark results as not run.
- Keep raw logs and machine-readable results alongside summary tables.
- Report any failed tests, timeouts, excluded runs and parameter changes.
- Separate observed simulation results from claims supported by a safety proof.

## 13. FPGA/tool flow
- Verilog RTL → simulation → Vivado synthesis → implementation/timing → bitstream → board demo.
- Board not confirmed. Candidates discussed: Basys 3 (XC7A35T), Nexys A7-100T (XC7A100T), PYNQ-Z2 (XC7Z020). None is final.
- Fit of the full 4×4 mesh cannot be guaranteed until the actual device and design are synthesized.
- Implement the NoC in programmable logic; do not rely on hardened NoC IP.
- Keep traffic sources/sinks synthesizable if needed for the on-board demo; simulation-only components can remain testbench files.

## 14. Implementation order
1. Review this spec and identify blocking open decisions.
2. Define Verilog-compatible shared definitions and interfaces.
3. Implement FIFO and unit tests.
4. Implement EWMA, congestion estimator and hysteresis controller with tests.
5. Implement and independently verify XY.
6. Implement Odd-Even candidate generation/turn legality and exhaustive tests.
7. Implement the selected global quiescence-based drain-and-switch protocol, including full drain detection and watchdog; validate the safety conditions before enabling mode changes.
8. Implement arbitration, packet tracking/reservation and crossbar.
9. Integrate and test one router.
10. Instantiate/connect all 16 routers in the 4×4 mesh.
11. Add traffic generation, packet checkers and metrics.
12. Run directed and randomized simulations.
13. Synthesize/implement in Vivado and verify on selected FPGA.

The final target is 4×4 from the beginning; module unit tests are encouraged, but a staged 2×2 network followed by expansion is not the plan.

## 15. Rules for the coding AI
1. Read this document before coding.
2. First summarize the architecture and list any verification risks, but do not stop to ask the user to reconfirm frozen decisions.
3. Treat global quiescence-based drain-and-switch as the selected transition policy. Use the frozen header encoding, coordinate convention, congestion aggregation and interface contract in this document. Where Odd-Even canonical correctness needs checking, implement the explicit candidate contract, run the stated verification and report any discrepancy without pausing for user input.
4. If an implementation detail is not explicitly frozen, choose the smallest conservative Verilog-compatible implementation consistent with this specification, document it in `DECISIONS.md`, and continue. Ask the user only if the spec is internally contradictory or implementation is impossible without a genuinely new product-level decision.
5. Generate synthesizable Verilog `.v` files and testbenches, not pseudocode or SystemVerilog.
6. Keep modules small, documented and independently testable.
7. Provide compile/run commands and expected results.
8. Run a simulator if available. If not, state clearly that code is unverified.
9. Fix compile errors and failing tests before integration.
10. Never claim correctness/deadlock freedom based only on compilation or a few simulations.
11. Track decisions in `DECISIONS.md`.
12. Do not add optional hardware features without approval.
13. Implement switch-rate, ping-pong, dwell-time, drain-duration, injection-blocked fraction, latency and throughput instrumentation in the testbench/monitoring path.
14. Keep the global drain-and-switch protocol identical across all hybrid comparison configurations.

## 15A. Revised project statement and key claims

Use this statement consistently in the report, RTL comments and evaluation scripts:

> Can a lightweight hysteresis-based controller, using an EWMA-filtered congestion estimate and dual thresholds, reduce routing-mode instability (the ping-pong effect) in a hybrid XY/Odd-Even NoC? Routing-mode transitions will use a global quiescence-based drain-and-switch protocol intended to preserve deadlock safety. The design will be evaluated against a conventional single-threshold hybrid router using switching-stability, packet-latency, throughput, drain-cost, and FPGA resource/timing metrics.

Use **reduce**, not **eliminate**, as the general project claim. If zero ping-pong events occur for a tested workload, report that as a measured result for that workload and `T_PP` definition only.

### Distinguish the mechanisms
- **EWMA + dual-threshold hysteresis:** intended to reduce unnecessary mode requests and rapid reversals.
- **Global quiescence / drain-and-switch:** controls when a requested mode transition is allowed to take effect.
- **Odd-Even routing legality and the documented safety argument:** support the deadlock-avoidance claim.
- **Counters and testbenches:** establish measured behaviour and overhead; they do not by themselves constitute a formal proof.

## 16. Dated implementation schedule (21 October–10 November 2026)

This is a practical, overlapping plan for a three-person student team. The target submission/demo date is **10 November 2026**. Start with the full 4×4 architecture; unit-test modules independently but do not build a 2×2 network as an intermediate milestone. If a milestone slips, prioritize correctness, reproducible simulation and a synthesis report over optional polish.

| Dates | Milestone | Exit evidence |
|---|---|---|
| 21–22 Oct | Freeze interfaces, constants, header/flit contract, module stubs, and `DECISIONS.md` | All module ports compile; no unresolved spec labels that require user decisions |
| 23–24 Oct | FIFO and ready/valid link tests | FIFO unit test passes empty/full, wrap, order, reset, backpressure and simultaneous push/pop cases |
| 25–26 Oct | EWMA, occupancy mapping, sideband and hysteresis | Reference-vector tests pass; boundary directions excluded correctly |
| 27–28 Oct | XY routing and Odd-Even candidate implementation | Exhaustive source/destination route tests; Odd-Even rules compared against Chiu reference; discrepancies documented and fixed |
| 29–31 Oct | Arbiter, crossbar, packet tracking and output reservation | Packet-level reservation/backpressure tests pass; no loss, duplication or reordering in directed tests |
| 1–3 Nov | Global quiescence controller, all-source acknowledgements, drained detector, sticky watchdog | Mode changes only when drained; timeout after 1,000 cycles leaves mode unchanged and injection blocked until reset |
| 4–5 Nov | Integrate the full 4×4 mesh and source/sink traffic infrastructure | Full-mesh compile; all-destination and multihop directed tests pass |
| 6–7 Nov | Randomized traffic, baselines, switching/ping-pong/latency/throughput metrics | Reproducible logs for XY-only, conventional threshold hybrid, ablations and HYSTERoC |
| 8–9 Nov | Vivado synthesis/implementation, resource/timing report, fix critical bugs, prepare demo/report | Actual target-device resource/timing numbers or explicit board-unavailable limitation; reproducible scripts and known-limitations list |
| 10 Nov | Final validation, packaging and demonstration | RTL, testbenches, run instructions, result tables, architecture, report and demo checklist packaged |

**Team split suggestion:** Member A owns FIFO/link/packet datapath and crossbar; Member B owns routing/sideband/EWMA/hysteresis; Member C owns global transition controller, integration testbench and metrics. All three review route legality and drained-detection logic together. Merge daily; do not wait until integration week.

## 17. Decisions and verification checklist
- [x] Freeze the 16-bit header layout.
- [x] Freeze occupancy mapping `{0,64,128,192,255}`.
- [x] Freeze EWMA recurrence, 11-bit state, reset, and default update cadence.
- [x] Freeze packet-level output reservation semantics.
- [x] Freeze conservative FIFO full behavior (`ready = (count != 4)`).
- [x] Freeze per-router EWMA with global maximum aggregation.
- [x] Select global quiescence-based drain-and-switch policy.
- [x] Define source injection-block request/acknowledgement semantics.
- [x] Define registered one-cycle-old neighbor occupancy sideband.
- [x] Odd-Even candidate rules and ex/ey candidate table specified; verify against the selected reference paper and exhaustive tests before making a deadlock-freedom claim.
- [x] Interface signal semantics are specified; use consistent descriptive flattened port names in the module contract and record exact names in `DECISIONS.md` without asking the user.
- [ ] Implement and test race-free drained detection, sticky 1,000-cycle watchdog, injection-blocked ERROR state, and resume behavior.
- [x] Fixed four-flit packet behavior is frozen; implement and test it in RTL/testbench.
- [ ] Confirm FPGA board/device.
- [ ] Pilot-test workloads and freeze final measurement conventions and acceptance thresholds.

## 18. Current status summary
**Established baseline:** 4×4 mesh, 16 routers, five ports/router, depth-4 input FIFOs, 16-bit data plus 2-bit type, four-flit packets, XY and Odd-Even routing, EWMA and dual-threshold hysteresis, initial thresholds 160/96, round-robin arbitration, 5×5 crossbar, ready/valid, synchronous active-low reset, global quiescence-based drain-and-switch as the selected transition policy, network-wide switching metrics, overhead criteria, Vivado FPGA flow, and Verilog `.v` RTL target.

**Accepted/frozen for v5:** packet-level output reservation; 16-bit header layout; occupancy map `{0,64,128,192,255}`; 11-bit EWMA recurrence `S_next = S - (S >> 3) + C`, reset `S=0`, `E=S>>3`, default sample period 1; per-router EWMA with global maximum aggregation; EWMA freeze during transition; global quiescence-based drain-and-switch; injection-block acknowledgement from all 16 sources; conservative FIFO full behavior; registered one-cycle-old neighbor occupancy sideband; raw-occupancy baseline threshold 128; end-to-end latency from packet creation as the primary latency metric.

**Verification and implementation tasks remaining (do not block coding to ask the user):** compare the V5 `ex`/`ey` candidate contract against Chiu’s reference and exhaustive tests; implement consistent flattened port names; test race-free drained detection; test watchdog and post-resume mask behavior; account for source/endpoint queues; synthesize for the board once it is assigned; pilot workloads and report measured results. Use the defaults and acceptance criteria in this specification until measurements justify a documented change. The selected drain-and-switch policy is not itself a completed proof of deadlock freedom.

**Starter RTL warning:** Any earlier starter RTL using SystemVerilog `.sv` files is not authoritative for the requested Verilog `.v` implementation. Audit/rewrite it, compile it and test it before reuse.


**V5 coding rule:** This document is the implementation contract. Do not stop because a former V3 item was labelled OPEN/PROPOSED. Implement the frozen values above, run the verification tasks, and report failures or evidence. The only prohibited action is claiming a property (especially canonical Odd-Even deadlock freedom) before its stated verification passes.
