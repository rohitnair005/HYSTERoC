// =============================================================================
// hy_pkg.sv : the HYSTERoC UVM environment package (everything except the tests).
// Compile order: hy_if.sv, hy_pkg.sv, tests/hy_tests_pkg.sv, test.sv
// Include directory (-i / +incdir): this folder.
// =============================================================================
`include "uvm_macros.svh"

package hy_pkg;
    import uvm_pkg::*;

    `include "hy_types.svh"
    `include "hy_item.svh"
    `include "hy_cfg.svh"
    `include "hy_route.svh"
    `include "hy_sb_core.svh"
    `include "hy_traffic.svh"
    `include "hy_model.svh"
    `include "hy_sequencer.svh"
    `include "hy_inject_driver.svh"
    `include "hy_monitors.svh"
    `include "hy_sink_driver.svh"
    `include "hy_hop_monitor.svh"
    `include "hy_scoreboard.svh"
    `include "hy_protocol_checker.svh"
    `include "hy_coverage.svh"
    `include "hy_agents.svh"
    `include "hy_env.svh"
    `include "hy_base_seq.svh"
    `include "hy_vseq_lib.svh"
    // batch U5 appends: sequences
endpackage
