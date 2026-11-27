# FPGA Integration Guidelines

The modules in `rtl/router/`, `rtl/control/`, and `rtl/top/` use synthesizable Verilog-2001. They contain no vendor-specific primitives, no latches, and no SystemVerilog extensions.

This document describes how to integrate the design into an FPGA target.

---

## 1. Synthesizable modules and simulation replacements

| Include in Synthesis | Exclude from Synthesis |
|---|---|
| `rtl/router/*` | `rtl/bench/traffic_generator.v` (replace with hardware sources) |
| `rtl/control/*` | `rtl/bench/packet_sink.v` (replace with hardware sinks) |
| `rtl/top/noc_top.v` | `rtl/bench/performance_monitor.v` (optional bring-up observer) |
| `rtl/common/hysteroc.vh` | |

---

## 2. Resource usage guidelines

* **Input FIFOs**: The 16 routers contain 80 FIFOs total. Each FIFO has a depth of 4 and a width of 18 bits. Map these FIFOs to distributed LUT RAM or shift registers. Do not allocate block RAM (BRAM) for these shallow FIFOs.
* **Transition Statistics**: Setting parameter `ENABLE_STATS = 0` removes thirteen 32-bit registers. Disable stats to evaluate core hardware resource overhead.
* **Filter Logic**: With default parameter `SAMPLE_PERIOD = 1`, the EWMA filter updates every clock cycle without requiring a period counter. This eliminates 16 flip-flops per router.
* **Comparators**: Threshold values (`THIGH`, `TLOW`) are parameters. Synthesis tools optimize comparators into simple logic gates.

---

## 3. Timing and critical paths

The design registers neighbour FIFO occupancies (`occ_q`) in each router. This isolates the neighbour comparison fan-in from input arrival paths.

The global maximum calculation (`global_congestion`) connects 16 values through a combinational comparator tree to the hysteresis controller. This logic meets timing at typical FPGA NoC clock frequencies.

The transition FSM uses registered state transitions. If high clock frequencies require extra pipelining on global signals, register the outputs of `max16` after updating the cycle-exact model in `tb/env/hy_model.svh`.

---

## 4. Constraints template

Sample constraints file for a Xilinx design flow:

```tcl
# System clock constraint (100 MHz target)
create_clock -period 10.000 -name sysclk [get_ports clk]

# Pin assignments (adjust to match board schematic)
set_property PACKAGE_PIN <CLK_PIN> [get_ports clk]
set_property PACKAGE_PIN <RSTN_PIN> [get_ports rst_n]

# False paths for asynchronous reset
set_false_path -from [get_ports rst_n]
```

For large meshes, connect the 16 local injection and ejection interfaces to internal processing elements or AXI-Stream converters instead of external FPGA pins.

---

## 5. Bring-up procedure

1. Synthesise `noc_top.v` with testbench wrappers. Validate identical parameters in simulation first using `./scripts/run_uvm.sh`.
2. Verify all mesh link connections. Output North connects to input South of the adjacent router.
3. Validate mode switching using `SWITCH_POLICY = 0`. Confirm that the network drains completely before mode updates occur.
4. Test the direct switching variant using `SWITCH_POLICY = 1` for lower latency.
