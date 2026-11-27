# =============================================================================
# sim/hysteroc_tb.f : HYSTERoC UVM testbench file list
# Tool-provided uvm_pkg must be compiled before (VCS: -v / xrun: -uvm).
# Compile order: tb/iface/hy_if.sv, tb/pkg/hy_pkg.sv, tb/tests/hy_tests_pkg.sv,
# tb/env/testbench.sv  (+ enables by include dirs below).
# =============================================================================
+incdir+rtl/common
+incdir+tb/pkg
+incdir+tb/agents
+incdir+tb/seq
+incdir+tb/env
+incdir+tb/tests

tb/iface/hy_if.sv
tb/pkg/hy_pkg.sv
tb/tests/hy_tests_pkg.sv
tb/env/testbench.sv
