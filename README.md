# HYSTERoC

**HYSTERoC** is an FPGA-oriented Network-on-Chip (NoC) project exploring a lightweight, hysteresis-based mechanism for switching between deterministic XY routing and adaptive Odd-Even routing.

The project investigates whether congestion-aware mode switching can reduce unnecessary routing-mode changes (the *ping-pong effect*) while maintaining safe packet delivery and acceptable FPGA resource and timing overhead.

> **Development status:** RTL modules and module-level testbenches are present in the repository. Treat full-system integration, end-to-end correctness, deadlock freedom, and performance claims as pending until supported by documented, reproducible test results.

## Objectives

- Implement a mesh NoC router in Verilog.
- Estimate congestion using an EWMA-based mechanism.
- Use dual-threshold hysteresis to control routing-mode changes.
- Coordinate mode transitions through a drain-and-switch mechanism.
- Generate traffic, track packets, and collect performance metrics.
- Evaluate correctness, routing stability, latency, and FPGA implementation cost.

## Architecture at a glance

The intended design combines the following elements:

- **XY routing:** deterministic routing that traverses the X dimension before the Y dimension.
- **Odd-Even routing:** an adaptive routing strategy subject to turn restrictions intended to support deadlock avoidance.
- **Congestion estimation:** occupancy-based congestion information smoothed using an Exponentially Weighted Moving Average (EWMA).
- **Hysteresis controller:** separate high and low thresholds to avoid switching modes whenever congestion fluctuates around a single threshold.
- **Transition controller and drain detection:** coordination for safely changing routing mode after traffic has quiesced and in-flight packets have drained.
- **Router datapath:** input buffering, route selection, switch allocation, and crossbar-based forwarding.
- **Traffic and measurement infrastructure:** traffic generation, packet sinks and tracking, performance monitoring, and Python-based metrics.

Refer to [`docs/HYSTERoC_AI_Implementation_Specification_v5.md`](docs/HYSTERoC_AI_Implementation_Specification_v5.md) for the detailed implementation contract and design requirements. Refer to [`DECISIONS.md`](DECISIONS.md) for recorded project decisions and their status.

## Repository structure

```text
HYSTERoC/
├── README.md
├── DECISIONS.md
├── docs/
│   ├── HYSTERoC_AI_Implementation_Specification_v5.md
│   └── batch5_route_report.txt
├── rtl/
│   ├── input_fifo.v
│   ├── ewma_filter.v
│   ├── congestion_estimator.v
│   ├── hysteresis_controller.v
│   ├── hysteroc_defs.vh
│   ├── round_robin_arbiter.v
│   ├── route_compute.v
│   ├── route_select.v
│   ├── switch_allocator.v
│   ├── crossbar.v
│   ├── noc_router.v
│   ├── drain_detector.v
│   ├── transition_controller.v
│   ├── noc_top.v
│   ├── traffic_generator.v
│   ├── packet_sink.v
│   ├── packet_tracker.v
│   ├── performance_monitor.v
│   ├── pm_log.vh
│   └── metrics.py
└── tb/
    ├── tb_input_fifo.v
    ├── tb_ewma_filter.v
    ├── tb_congestion_estimator.v
    ├── tb_hysteresis_controller.v
    ├── tb_round_robin_arbiter.v
    ├── tb_route_compute.v
    ├── tb_route_select.v
    ├── tb_switch_allocator.v
    ├── additional module-level testbenches
    └── integration testbenches
```

The tree is representative of the current source organization. Check the actual `rtl/` and `tb/` directories for the complete file list as the project evolves.

## RTL and verification

The `rtl/` directory contains the Verilog implementation modules and supporting measurement code. The `tb/` directory contains testbenches for individual blocks and higher-level components.

Testbench presence does not by itself mean that a test has been run or passed. Record the simulator, command or project settings, test name, and result when reporting verification status. Keep module-level verification separate from top-level integration verification.

Before considering a release or performance result complete, validate at least:

- Reset behavior and handshake correctness.
- FIFO full/empty conditions and simultaneous operations.
- Packet integrity and correct destination delivery.
- Route selection and boundary behavior.
- Arbitration and output-reservation behavior under backpressure.
- Mode-transition quiescence, draining, timeout, and recovery behavior.
- Integrated traffic tests across the intended mesh.
- Routing deadlock-safety claims against the implemented routing rules.
- Synthesis resource utilization and timing on the selected FPGA target.

Do not claim deadlock freedom, successful end-to-end operation, or measured performance improvements without evidence from the relevant analysis and tests.

## Tools

The project is designed around Verilog RTL and FPGA-oriented development. The repository may be used with:

- Xilinx Vivado for simulation and FPGA implementation.
- A Verilog simulator compatible with the RTL and testbenches.
- Python for metrics and analysis.

Exact simulator commands and FPGA constraints should be documented as the corresponding scripts, test configurations, and board target are finalized.

## Getting started

1. Clone the repository:

   ```bash
   git clone https://github.com/rohitnair005/HYSTERoC.git
   cd HYSTERoC
   ```

2. Read the design contract and recorded decisions:

   - [`docs/HYSTERoC_AI_Implementation_Specification_v5.md`](docs/HYSTERoC_AI_Implementation_Specification_v5.md)
   - [`DECISIONS.md`](DECISIONS.md)

3. Open the project in Vivado or your supported Verilog simulator.
4. Select a testbench, compile its required RTL dependencies, and run the simulation.
5. Record the exact test and outcome. Use the project’s actual source list and simulator settings; do not assume every testbench can be compiled together as one simulation.

## Contributing

This repository is intended to support collaborative development and teammate forks.

- Create a feature branch for your changes.
- Keep RTL changes and testbench updates together where practical.
- Run the relevant tests and report what was run.
- Update `DECISIONS.md` when an architectural decision changes.
- Update this README when the architecture, build flow, or project status materially changes.
- Submit changes through a pull request so they can be reviewed before merging.

## Current limitations

- The exact integration and regression status must be established from recorded simulation results.
- Canonical Odd-Even routing behavior and deadlock-safety claims require validation against the implemented turn restrictions and an appropriate analysis.
- FPGA resource and timing results depend on the selected board, constraints, and synthesis settings; do not assume targets have been met before measuring them.
- Keep the detailed specification and decision log aligned with the implementation as discrepancies are discovered and resolved.

## License

No license is specified in this repository yet. Unless a license is added, the source should not be assumed to be available for unrestricted reuse.
