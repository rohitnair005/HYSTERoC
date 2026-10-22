# HYSTERoC

## Overview

HYSTERoC is an FPGA-oriented Network-on-Chip (NoC) router project investigating a lightweight, hysteresis-based control mechanism for dynamically switching between deterministic XY routing and adaptive Odd-Even routing.

The project aims to reduce routing instability—often called the *ping-pong effect*—under fluctuating network congestion, while evaluating deadlock safety and the additional FPGA resource and timing costs of the control mechanism.

## Key Features

- **Hybrid routing:** Combines deterministic XY routing and adaptive Odd-Even routing.
- **EWMA congestion estimation:** Filters congestion measurements to reduce sensitivity to short-term fluctuations.
- **Dual-threshold hysteresis:** Uses separate high and low thresholds to reduce frequent routing-mode changes.
- **Coordinated mode transitions:** Uses a global quiescence-based drain-and-switch procedure before applying a routing-mode change.
- **4×4 mesh target:** Designed around a mesh of 16 routers.
- **Hardware-oriented evaluation:** Focuses on routing stability, packet latency, throughput, FPGA resource utilization, and timing overhead.

## Architecture Summary

Each router has input buffering and routing logic, while congestion estimation and hysteresis control inform the network's active routing mode. The proposed transition controller coordinates mode changes across the mesh and waits for network traffic to drain before switching modes.

The design uses Verilog RTL for hardware implementation. SystemVerilog and UVM-based functional verification are planned for a later verification phase.

## Current Implementation Status

RTL development is in progress. Implemented components currently include:

- Input FIFO
- EWMA filter
- Congestion estimator
- Hysteresis controller
- Shared definitions and parameters header

The complete router, routing logic, network integration, and full functional verification remain part of the ongoing development and validation work.

## Evaluation Goals

HYSTERoC will be evaluated against baseline routing configurations using metrics such as:

- Routing-mode switch rate and ping-pong frequency
- End-to-end packet latency and throughput
- Packet integrity under congestion and backpressure
- FPGA resource utilization and timing
- Correctness of routing decisions and deadlock-safety analysis

Performance improvements and deadlock-safety claims will be reported only after the relevant tests, analysis, and measurements have been completed.
