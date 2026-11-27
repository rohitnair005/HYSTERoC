// =============================================================================
// testbench.sv : HYSTERoC UVM testbench top.
// Compile order: tb/iface/hy_if.sv, tb/pkg/hy_pkg.sv, tb/tests/hy_tests_pkg.sv,
// tb/env/testbench.sv. Include dirs: rtl/common, tb/pkg, tb/agents, tb/seq,
// tb/env, tb/tests. See scripts/run_uvm.sh and sim/hysteroc_tb.f.
// =============================================================================
`include "hy_if.sv"
`include "hy_pkg.sv"
`include "hy_sva.sv"
`include "test.sv"
