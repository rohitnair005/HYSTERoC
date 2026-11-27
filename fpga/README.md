# FPGA Integration Overview

The synthesizable design consists of `rtl/top/noc_top.v` and its underlying router and control modules. All synthesizable modules use standard Verilog-2001.

Modules in `rtl/bench/` (`traffic_generator`, `packet_sink`, and `performance_monitor`) are simulation models. Replace these modules with real hardware source and sink interfaces during FPGA implementation.

Refer to [../docs/fpga.md](../docs/fpga.md) for detailed integration instructions, resource estimation, clock constraints, and bring-up steps.
