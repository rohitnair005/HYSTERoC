// =============================================================================
// hy_pkg.sv : the HYSTERoC UVM environment package (everything except the tests).
// Compile order: tb/iface/hy_if.sv, tb/pkg/hy_pkg.sv, tb/tests/hy_tests_pkg.sv,
// tb/env/testbench.sv  (+ tb/env/test.sv for the top). Include dirs required
// (-I): rtl/common, tb/pkg, tb/agents, tb/seq, tb/env, tb/tests.
// Order matters: types -> config -> route/traffic -> model -> agents -> env.
// =============================================================================
`include "uvm_macros.svh"

package hy_pkg;
    import uvm_pkg::*;

    `include "hy_types.svh"
    `include "hy_item.svh"
    `include "hy_cfg.svh"
    `include "hy_route.svh"
    `include "hy_sb_core.svh"       // from tb/env (in include path)
    `include "hy_traffic.svh"
    `include "hy_model.svh"         // from tb/env
    `include "hy_sequencer.svh"
    `include "hy_inject_driver.svh" // from tb/agents
    `include "hy_monitors.svh"      // from tb/agents
    `include "hy_sink_driver.svh"   // from tb/agents
    `include "hy_hop_monitor.svh"   // from tb/agents
    `include "hy_scoreboard.svh"    // from tb/env
    `include "hy_protocol_checker.svh" // from tb/env
    `include "hy_coverage.svh"      // from tb/env
    `include "hy_agents.svh"        // from tb/agents
    `include "hy_env.svh"            // from tb/env
    `include "hy_base_seq.svh"      // from tb/seq
    `include "hy_vseq_lib.svh"      // from tb/seq
endpackage
