# Frequently Asked Questions (FAQ) — HYSTERoC

This document answers common questions about the HYSTERoC architecture, simulation, verification, and FPGA implementation.

---

## 1. General architecture questions

### What problem does HYSTERoC solve?
Conventional hybrid routers switch between deterministic and adaptive routing using a single congestion threshold. Because FIFO occupancy bounces cycle-to-cycle, the router oscillates rapidly between modes. This oscillation (called the ping-pong effect) stalls packet injection and drains the network repeatedly. HYSTERoC solves this problem using an EWMA filter and a dual-threshold hysteresis controller.

### Why does the mesh use 4×4 routers instead of 8×8 or larger?
A 4×4 mesh (16 routers) provides multi-hop paths and realistic congestion while remaining small enough for exhaustive testbench verification, short simulation runtimes, and fast formal property evaluation.

### Is HYSTERoC proven to be deadlock-free?
Deadlock safety is argued and validated through tests, but not formally proven with mathematical tools. Deadlock safety relies on Chiu's Odd–Even turn model, round-robin output arbitration, and the global drain-and-switch protocol.

---

## 2. Configuration and control

### How do I configure the hysteresis thresholds?
Set the `THIGH` and `TLOW` parameters on `noc_top.v` or via simulator command-line arguments:
* `THIGH` (default: 160): Upper threshold to enter adaptive mode.
* `TLOW` (default: 96): Lower threshold to return to deterministic mode.
The condition `TLOW < THIGH` is mandatory.

### What is the difference between `SWITCH_POLICY = 0` and `SWITCH_POLICY = 1`?
* `SWITCH_POLICY = 0` (drain-and-switch): Baseline paper configuration. Stops packet injection, drains all in-flight packets, and changes modes safely.
* `SWITCH_POLICY = 1` (no-drain): Changes modes in a single clock cycle while packets are moving. Both modes use Odd–Even turn rules, preventing routing deadlocks.

### Why does the EWMA filter use bit shifts instead of floating-point arithmetic?
Bit shifts (`S >> 3`) require zero hardware multipliers and execute in a single clock cycle. This design consumes minimal FPGA resources and prevents numerical overflow.

---

## 3. Verification and simulation

### Which simulators can I use?
* **Syntax and Elaboration Checks**: Icarus Verilog (`iverilog`) and Verilator (no licence required). Run `make lint`.
* **Full UVM Verification**: Commercial simulators that support SystemVerilog and UVM 1.2 (Synopsys VCS, Cadence Xcelium, or Siemens Questa).

### How do I run a complete test regression?
Execute the regression command:
```bash
./scripts/run_uvm.sh --sim xrun --test hy_regress_test
```
Or execute the full campaign across all tests:
```bash
./scripts/run_uvm.sh --sim xrun --campaign
```

### What does it mean if `hy_watchdog_test` reports an `ERROR` state?
In `hy_watchdog_test`, an unacknowledged source intentionally provokes the drain watchdog timer. The FSM transitions to `ERROR` and stops injection safely. The test succeeds because reaching `ERROR` is the expected recovery behaviour.

---

## 4. FPGA implementation

### Can I synthesize `noc_top.v` directly?
Yes. The synthesizable RTL in `rtl/router/`, `rtl/control/`, and `rtl/top/` uses standard Verilog-2001. Do not synthesize files in `rtl/bench/`, which are testbench models.

### Should I use block RAM (BRAM) for the router FIFOs?
No. Each FIFO is shallow (depth of 4, width of 18 bits). Map these FIFOs to distributed LUT RAM or shift registers. Using BRAM for shallow FIFOs consumes excessive dedicated memory blocks.

### How do I minimize FPGA logic usage?
Set parameter `ENABLE_STATS = 0` on `noc_top.v`. This parameter removes 13 performance counters and reduces flip-flop utilization significantly.
