// =============================================================================
// hy_tests_pkg.sv : all UVM tests of the HYSTERoC environment.
// Included by test.sv (which also holds the testbench top). Run one test with
//     +UVM_TESTNAME=<name>
// Optional plusargs read by the tests:
//     +HY_LOAD=<n>     offered load, flits/node/cycle x 1000   (pattern/oscillate tests)
//     +HY_CYCLES=<n>   cycles per phase
//     +HY_PAT=<n>      0 uniform 1 hotspot 2 transpose 3 complement 4 neighbour 5 bitrev
//     +HY_ALLPAIRS=1   zero-load test over all 240 flows
//     +HY_TIMEOUT=<n>  hard stop in cycles (default 3000000)
// Tests:
//   hy_smoke_test         one packet corner to corner
//   hy_zero_load_test     latency is exactly distance + 4 into an empty network
//   hy_all_pairs_test     every node to every other node
//   hy_flow_test          200 packets of one flow
//   hy_uniform_test  hy_hotspot_test  hy_transpose_test  hy_pattern_test (+HY_PAT)
//   hy_phased_test        low -> high -> low load
//   hy_oscillate_test     square-wave load: many threshold crossings
//   hy_nodrain_test       oscillate + requires mode changes with flits in flight (SWITCH_POLICY=1)
//   hy_patterns_all_test  every pattern at a heavy load
//   hy_lengths_test       packet lengths 2..16 (beyond the 4-flit contract)
//   hy_loopback_test      src == dst (beyond the contract)
//   hy_bubble_test        gaps inside packets on the inject side + random sinks
//   hy_backpressure_test  sink behaviour changes while traffic runs
//   hy_watchdog_test      a source never acknowledges: ERROR state required
//   hy_reset_test         reset in the middle of traffic (twice)
//   hy_regress_test       several of the above back to back in one simulation
// =============================================================================
package hy_tests_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import hy_pkg::*;

    // ------------------------------------------------------------------ base test
    class hy_base_test extends uvm_test;

        hy_env       env;
        hy_cfg       cfg;
        virtual hy_if vif;
        int unsigned timeout_cycles = 3000000;

        `uvm_component_utils(hy_base_test)

        function new(string name = "hy_base_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        // tests override this to change the configuration BEFORE the environment is built
        virtual function void configure(hy_cfg c);
        endfunction

        // the sequence(s) of the test
        virtual task run_body();
        endtask

        protected function int get_param(string key, int dflt);
            int v;
            if (uvm_config_db #(int)::get(this, "", key, v)) return v;
            return dflt;
        endfunction

        protected function int plus(string name, int dflt);
            int v;
            string f = {name, "=%d"};
            if ($value$plusargs(f, v)) return v;
            return dflt;
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual hy_if)::get(this, "", "vif", vif)) `uvm_fatal("VIF", "virtual interface not found in config_db")
            cfg = hy_cfg::type_id::create("cfg");
            cfg.vif = vif;
            // echo the DUT parameters (published by the tb top)
            cfg.dut_xy_only           = get_param("XY_ONLY", 0);
            cfg.dut_dual              = get_param("DUAL", 1);
            cfg.dut_use_ewma          = get_param("USE_EWMA", 1);
            cfg.dut_thigh             = get_param("THIGH", 160);
            cfg.dut_tlow              = get_param("TLOW", 96);
            cfg.dut_thresh_single     = get_param("THRESH_SINGLE", 128);
            cfg.dut_sample_period     = get_param("SAMPLE_PERIOD", 1);
            cfg.dut_watchdog_limit    = get_param("WATCHDOG_LIMIT_CYCLES", 1000);
            cfg.dut_post_resume_mask  = get_param("POST_RESUME_MASK_CYCLES", 0);
            cfg.dut_enable_stats      = get_param("ENABLE_STATS", 1);
            cfg.dut_drain_confirm     = get_param("DRAIN_CONFIRM", 2);
            cfg.dut_switch_policy     = get_param("SWITCH_POLICY", 0);
            hy_nodrain_policy         = cfg.dut_switch_policy;
            cfg.dut_det_variant       = get_param("DET_VARIANT", 0);
            hy_det_variant            = cfg.dut_det_variant;
            timeout_cycles            = plus("HY_TIMEOUT", timeout_cycles);
            configure(cfg);
            uvm_config_db #(hy_cfg)::set(this, "env*", "cfg", cfg);
            env = hy_env::type_id::create("env", this);
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            super.end_of_elaboration_phase(phase);
            `uvm_info("TEST", cfg.convert2string(), UVM_LOW)
        endfunction

        task run_phase(uvm_phase phase);
            phase.raise_objection(this, "test body");
            fork
                begin
                    repeat (timeout_cycles) @(posedge vif.clk);
                    `uvm_fatal("TIMEOUT", $sformatf("test did not finish within %0d cycles", timeout_cycles))
                end
            join_none
            wait (vif.rst_n === 1'b1);
            repeat (10) @(posedge vif.clk);
            run_body();
            repeat (20) @(posedge vif.clk);
            phase.drop_objection(this, "test body");
        endtask

        protected task run_vseq(hy_vseq_base s);
            s.start(env.vseqr);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            int unsigned bad = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
            if (bad == 0) `uvm_info("RESULT", "*** HYSTERoC TEST PASSED ***", UVM_NONE)
            else          `uvm_info("RESULT", $sformatf("*** HYSTERoC TEST FAILED: %0d error(s) ***", bad), UVM_NONE)
        endfunction

    endclass

    // ------------------------------------------------------------------ directed tests
    class hy_smoke_test extends hy_base_test;
        `uvm_component_utils(hy_smoke_test)
        function new(string name = "hy_smoke_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_single s = hy_vseq_single::type_id::create("s");
            s.src = 0; s.dst = 15;
            run_vseq(s);
        endtask
    endclass

    class hy_zero_load_test extends hy_base_test;
        `uvm_component_utils(hy_zero_load_test)
        function new(string name = "hy_zero_load_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_zero_load s = hy_vseq_zero_load::type_id::create("s");
            s.all_pairs = plus("HY_ALLPAIRS", 0);
            run_vseq(s);
            `uvm_info("TEST", $sformatf("%0d zero-load flows checked", s.n_checked), UVM_LOW)
        endtask
    endclass

    class hy_all_pairs_test extends hy_base_test;
        `uvm_component_utils(hy_all_pairs_test)
        function new(string name = "hy_all_pairs_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_all_pairs s = hy_vseq_all_pairs::type_id::create("s");
            s.reps = 2;
            run_vseq(s);
        endtask
    endclass

    class hy_flow_test extends hy_base_test;
        `uvm_component_utils(hy_flow_test)
        function new(string name = "hy_flow_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_flow s = hy_vseq_flow::type_id::create("s");
            run_vseq(s);
        endtask
    endclass

    // ------------------------------------------------------------------ workload tests
    class hy_pattern_test extends hy_base_test;
        hy_pattern_e pat = HY_PAT_UNIFORM;
        `uvm_component_utils(hy_pattern_test)
        function new(string name = "hy_pattern_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_pattern s = hy_vseq_pattern::type_id::create("s");
            s.pattern = hy_pattern_e'(plus("HY_PAT", int'(pat)));
            s.load_pm = plus("HY_LOAD", 100);
            s.cycles  = plus("HY_CYCLES", 5000);
            run_vseq(s);
        endtask
    endclass

    class hy_uniform_test extends hy_pattern_test;
        `uvm_component_utils(hy_uniform_test)
        function new(string name = "hy_uniform_test", uvm_component parent = null); super.new(name, parent); pat = HY_PAT_UNIFORM; endfunction
    endclass
    class hy_hotspot_test extends hy_pattern_test;
        `uvm_component_utils(hy_hotspot_test)
        function new(string name = "hy_hotspot_test", uvm_component parent = null); super.new(name, parent); pat = HY_PAT_HOTSPOT; endfunction
    endclass
    class hy_transpose_test extends hy_pattern_test;
        `uvm_component_utils(hy_transpose_test)
        function new(string name = "hy_transpose_test", uvm_component parent = null); super.new(name, parent); pat = HY_PAT_TRANSPOSE; endfunction
    endclass

    class hy_phased_test extends hy_base_test;
        `uvm_component_utils(hy_phased_test)
        function new(string name = "hy_phased_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_phased s = hy_vseq_phased::type_id::create("s");
            s.step_cycles = plus("HY_CYCLES", 1500);
            s.high_pm = plus("HY_LOAD", 350);
            run_vseq(s);
        endtask
    endclass

    class hy_oscillate_test extends hy_base_test;
        `uvm_component_utils(hy_oscillate_test)
        function new(string name = "hy_oscillate_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_oscillate s = hy_vseq_oscillate::type_id::create("s");
            s.hi_pm = plus("HY_LOAD", 400);
            s.half_period = plus("HY_CYCLES", 300);
            run_vseq(s);
        endtask
    endclass

    // no-drain policy: square-wave load, the mode MUST change with flits in flight (checked by the protocol checker)
    class hy_nodrain_test extends hy_oscillate_test;
        `uvm_component_utils(hy_nodrain_test)
        function new(string name = "hy_nodrain_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual function void configure(hy_cfg c);
            c.require_inflight_switch = 1;
        endfunction
    endclass

    class hy_compare_test extends hy_base_test;
        `uvm_component_utils(hy_compare_test)
        function new(string name = "hy_compare_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_compare s = hy_vseq_compare::type_id::create("s");
            s.lo_pm    = plus("HY_LO", 100);
            s.hi_pm    = plus("HY_HI", 350);
            s.step_pm  = plus("HY_STEP", 25);
            s.dwell    = plus("HY_DWELL", 2000);
            s.pattern  = hy_pattern_e'(plus("HY_PAT", 0));
            run_vseq(s);
        endtask
    endclass

    class hy_patterns_all_test extends hy_base_test;
        `uvm_component_utils(hy_patterns_all_test)
        function new(string name = "hy_patterns_all_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_patterns_all s = hy_vseq_patterns_all::type_id::create("s");
            s.load_pm = plus("HY_LOAD", 250);
            s.cycles  = plus("HY_CYCLES", 1500);
            run_vseq(s);
        endtask
    endclass

    // ------------------------------------------------------------------ beyond-the-contract and stress
    class hy_lengths_test extends hy_base_test;
        `uvm_component_utils(hy_lengths_test)
        function new(string name = "hy_lengths_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_lengths s = hy_vseq_lengths::type_id::create("s");
            run_vseq(s);
        endtask
    endclass

    class hy_loopback_test extends hy_base_test;
        `uvm_component_utils(hy_loopback_test)
        function new(string name = "hy_loopback_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_loopback s = hy_vseq_loopback::type_id::create("s");
            run_vseq(s);
        endtask
    endclass

    class hy_bubble_test extends hy_base_test;
        `uvm_component_utils(hy_bubble_test)
        function new(string name = "hy_bubble_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual function void configure(hy_cfg c);
            c.flit_bubble_pct = 30;
            c.src_bubble_pct  = 30;
            c.set_all_sinks(HY_RDY_RANDOM, 60);
        endfunction
        virtual task run_body();
            hy_vseq_pattern s = hy_vseq_pattern::type_id::create("s");
            s.load_pm = plus("HY_LOAD", 120);
            s.cycles  = plus("HY_CYCLES", 5000);
            run_vseq(s);
        endtask
    endclass

    class hy_backpressure_test extends hy_base_test;
        `uvm_component_utils(hy_backpressure_test)
        function new(string name = "hy_backpressure_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_backpressure s = hy_vseq_backpressure::type_id::create("s");
            run_vseq(s);
        endtask
    endclass

    class hy_watchdog_test extends hy_base_test;
        `uvm_component_utils(hy_watchdog_test)
        function new(string name = "hy_watchdog_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual function void configure(hy_cfg c);
            if (!c.dut_switch_policy) c.expect_drain_timeout = 1;      // no watchdog exists in the no-drain policy
        endfunction
        virtual task run_body();
            hy_vseq_watchdog s = hy_vseq_watchdog::type_id::create("s");
            if (cfg.dut_switch_policy) begin
                `uvm_info("TEST", "watchdog test is not applicable to SWITCH_POLICY=1 (no drain, no watchdog): skipped", UVM_LOW)
                return;
            end
            run_vseq(s);
        endtask
    endclass

    class hy_reset_test extends hy_base_test;
        `uvm_component_utils(hy_reset_test)
        function new(string name = "hy_reset_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_reset s = hy_vseq_reset::type_id::create("s");
            s.resets = 2;
            run_vseq(s);
        endtask
    endclass

    // ------------------------------------------------------------------ everything in one simulation
    // (not the watchdog / reset tests: they leave the network in a special state)
    class hy_regress_test extends hy_base_test;
        `uvm_component_utils(hy_regress_test)
        function new(string name = "hy_regress_test", uvm_component parent = null); super.new(name, parent); endfunction
        virtual task run_body();
            hy_vseq_single       s1 = hy_vseq_single::type_id::create("s1");
            hy_vseq_zero_load    s2 = hy_vseq_zero_load::type_id::create("s2");
            hy_vseq_all_pairs    s3 = hy_vseq_all_pairs::type_id::create("s3");
            hy_vseq_uniform      s4 = hy_vseq_uniform::type_id::create("s4");
            hy_vseq_oscillate    s5 = hy_vseq_oscillate::type_id::create("s5");
            hy_vseq_backpressure s6 = hy_vseq_backpressure::type_id::create("s6");
            hy_vseq_patterns_all s7 = hy_vseq_patterns_all::type_id::create("s7");
            hy_vseq_lengths      s8 = hy_vseq_lengths::type_id::create("s8");
            hy_vseq_loopback     s9 = hy_vseq_loopback::type_id::create("s9");
            run_vseq(s1);
            run_vseq(s2);
            run_vseq(s3);
            run_vseq(s4);
            run_vseq(s5);
            run_vseq(s6);
            run_vseq(s7);
            run_vseq(s8);
            run_vseq(s9);
            // source and flit bubbles with a randomly stalling sink
            cfg.flit_bubble_pct = 30;
            cfg.src_bubble_pct  = 30;
            cfg.set_all_sinks(HY_RDY_RANDOM, 60);
            begin
                hy_vseq_pattern s10 = hy_vseq_pattern::type_id::create("s10");
                s10.load_pm = 120;
                s10.cycles  = 3000;
                run_vseq(s10);
            end
            cfg.flit_bubble_pct = 0;
            cfg.src_bubble_pct  = 0;
            cfg.set_all_sinks(HY_RDY_ALWAYS);
        endtask
    endclass

endpackage
