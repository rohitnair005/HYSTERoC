// =============================================================================
// hy_vseq_lib.svh : the virtual sequence library (run on env.vseqr).
//
// Workloads (spec 12.4), all built on hy_load_ctl + hy_traffic_seq
//   hy_vseq_workload     base: a list of phases {load, pattern, hot spot, cycles}
//   hy_vseq_pattern      one phase of any pattern        hy_vseq_uniform / _hotspot / _transpose
//   hy_vseq_phased       low -> high -> low congestion (bursty, ramped)
//   hy_vseq_oscillate    square-wave load across the thresholds (exercises mode switching)
//   hy_vseq_patterns_all every pattern for a while (heavy)
// Directed
//   hy_vseq_single       one packet from src to dst
//   hy_vseq_zero_load    packets into an EMPTY network: latency must be exactly distance + 4
//   hy_vseq_all_pairs    every source sends to every other node (240 flows), in parallel
//   hy_vseq_flow         many packets of one flow (order check in XY-only networks)
//   hy_vseq_lengths      random packet lengths 2..16 flits  (BEYOND the 4-flit contract)
//   hy_vseq_loopback     every node sends to itself          (BEYOND the contract)
// Stress / robustness
//   hy_vseq_backpressure changing sink behaviour while traffic runs
//   hy_vseq_watchdog     one source never acknowledges: the controller must reach ERROR
//                        (the test sets cfg.expect_drain_timeout = 1)
//   hy_vseq_reset        reset the whole network in the middle of traffic
// Units: load_pm = flits per node per cycle x 1000 (100 = 0.10).
// Every sequence ends with "wait until the scoreboard is empty" (wait_idle) unless noted.
// =============================================================================
typedef struct {
    int unsigned load_pm;
    hy_pattern_e pattern;
    int          hot_node;
    int unsigned hot_pct;
    int unsigned cycles;
} hy_phase_t;

class hy_vseq_base extends uvm_sequence;

    `uvm_object_utils(hy_vseq_base)
    `uvm_declare_p_sequencer(hy_vseqr)

    hy_traffic_seq tseq[HY_NODES];
    hy_load_ctl    ctl;
    int unsigned   drain_timeout = 0;          // 0: use cfg.drain_timeout_cycles

    function new(string name = "hy_vseq_base");
        super.new(name);
    endfunction

    task wait_cycles(int unsigned n);
        repeat (n) @(posedge p_sequencer.cfg.vif.clk);
    endtask

    task wait_idle();
        bit ok;
        int unsigned t = (drain_timeout != 0) ? drain_timeout : p_sequencer.cfg.drain_timeout_cycles;
        p_sequencer.sb.wait_idle(t, ok);
        if (!ok)
            `uvm_error("DRAIN", $sformatf("%0d packets were not delivered within %0d cycles after the traffic stopped",
                                          p_sequencer.sb.n_pending(), t))
    endtask

    // start one hy_traffic_seq per active node, running in parallel
    task start_traffic(hy_load_ctl c, int unsigned n_pkts = 0);
        ctl = c;
        for (int i = 0; i < HY_NODES; i++) begin
            int n = i;
            if (p_sequencer.sqr[n] == null) continue;
            tseq[n] = hy_traffic_seq::type_id::create($sformatf("tseq_%0d", n));
            tseq[n].ctl = ctl; tseq[n].my_node = n; tseq[n].n_pkts = n_pkts;
            fork
                tseq[n].start(p_sequencer.sqr[n]);
            join_none
        end
    endtask

    // halt the traffic and wait until every node sequence has finished
    task stop_traffic(int unsigned timeout = 100000);
        ctl.halt = 1;
        fork
            begin
                for (int n = 0; n < HY_NODES; n++)
                    if (tseq[n] != null) tseq[n].wait_for_sequence_state(UVM_FINISHED);
            end
            begin
                wait_cycles(timeout);
                `uvm_error("STOP", "traffic sequences did not finish after halt")
            end
        join_any
        disable fork;
    endtask

    // halt and kill (used when the network is expected to stay blocked)
    function void kill_traffic();
        if (ctl != null) ctl.halt = 1;
        for (int n = 0; n < HY_NODES; n++) if (tseq[n] != null) tseq[n].kill();
    endfunction

    // send `count` packets from one node (uses the basic hy_item_seq)
    task send_from(int src, int dst, int unsigned count, int unsigned gap_max = 8);
        hy_item_seq s = hy_item_seq::type_id::create("s");
        s.my_node = src; s.dst_fixed = dst; s.n_pkts = count; s.gap_max = gap_max;
        s.start(p_sequencer.sqr[src]);
    endtask

endclass

// ------------------------------------------------------------------ workloads
class hy_vseq_workload extends hy_vseq_base;
    hy_phase_t   phases[$];
    int unsigned repeats = 1;
    int unsigned len_min = 4, len_max = 4;
    `uvm_object_utils(hy_vseq_workload)

    function new(string name = "hy_vseq_workload");
        super.new(name);
    endfunction

    function void add_phase(int unsigned load_pm, hy_pattern_e pat, int unsigned cycles, int hot = 5, int unsigned hot_pct = 40);
        hy_phase_t ph;
        ph.load_pm = load_pm; ph.pattern = pat; ph.cycles = cycles; ph.hot_node = hot; ph.hot_pct = hot_pct;
        phases.push_back(ph);
    endfunction

    virtual function void build_phases();
    endfunction

    virtual task body();
        hy_load_ctl c = hy_load_ctl::type_id::create("ctl");
        build_phases();
        c.len_min = len_min; c.len_max = len_max;
        c.load_pm = (phases.size() > 0) ? phases[0].load_pm : 0;
        start_traffic(c);
        repeat (repeats) begin
            foreach (phases[i]) begin
                c.pattern = phases[i].pattern; c.load_pm = phases[i].load_pm;
                c.hot_node = phases[i].hot_node; c.hot_pct = phases[i].hot_pct;
                `uvm_info("WORKLOAD", $sformatf("phase %0d: pattern %s load %0d.%03d flits/node/cycle for %0d cycles",
                          i, phases[i].pattern.name(), phases[i].load_pm / 1000, phases[i].load_pm % 1000, phases[i].cycles), UVM_MEDIUM)
                wait_cycles(phases[i].cycles);
            end
        end
        stop_traffic();
        wait_idle();
    endtask
endclass

class hy_vseq_pattern extends hy_vseq_workload;
    hy_pattern_e pattern = HY_PAT_UNIFORM;
    int unsigned load_pm = 100;
    int unsigned cycles  = 5000;
    int          hot_node = 5;
    int unsigned hot_pct  = 40;
    `uvm_object_utils(hy_vseq_pattern)
    function new(string name = "hy_vseq_pattern");
        super.new(name);
    endfunction
    virtual function void build_phases();
        add_phase(load_pm, pattern, cycles, hot_node, hot_pct);
    endfunction
endclass

class hy_vseq_uniform extends hy_vseq_pattern;
    `uvm_object_utils(hy_vseq_uniform)
    function new(string name = "hy_vseq_uniform");
        super.new(name);
        pattern = HY_PAT_UNIFORM;
    endfunction
endclass

class hy_vseq_hotspot extends hy_vseq_pattern;
    `uvm_object_utils(hy_vseq_hotspot)
    function new(string name = "hy_vseq_hotspot");
        super.new(name);
        pattern = HY_PAT_HOTSPOT;
    endfunction
endclass

class hy_vseq_transpose extends hy_vseq_pattern;
    `uvm_object_utils(hy_vseq_transpose)
    function new(string name = "hy_vseq_transpose");
        super.new(name);
        pattern = HY_PAT_TRANSPOSE;
    endfunction
endclass

// low -> ramp up -> high -> ramp down -> low (uniform traffic)
class hy_vseq_phased extends hy_vseq_workload;
    int unsigned low_pm = 40, high_pm = 350, step_cycles = 1500;
    `uvm_object_utils(hy_vseq_phased)
    function new(string name = "hy_vseq_phased");
        super.new(name);
    endfunction
    virtual function void build_phases();
        add_phase(low_pm, HY_PAT_UNIFORM, step_cycles);
        add_phase((low_pm + high_pm) / 2, HY_PAT_UNIFORM, step_cycles);
        add_phase(high_pm, HY_PAT_UNIFORM, 2 * step_cycles);
        add_phase((low_pm + high_pm) / 2, HY_PAT_UNIFORM, step_cycles);
        add_phase(low_pm, HY_PAT_UNIFORM, step_cycles);
    endfunction
endclass

// square wave between a low and a high load: crosses the thresholds again and again
class hy_vseq_oscillate extends hy_vseq_workload;
    int unsigned lo_pm = 40, hi_pm = 400, half_period = 300, periods = 12;
    hy_pattern_e pattern = HY_PAT_UNIFORM;
    `uvm_object_utils(hy_vseq_oscillate)
    function new(string name = "hy_vseq_oscillate");
        super.new(name);
    endfunction
    virtual function void build_phases();
        repeat (periods) begin
            add_phase(hi_pm, pattern, half_period);
            add_phase(lo_pm, pattern, half_period);
        end
    endfunction
endclass

// every pattern at a heavy load
class hy_vseq_patterns_all extends hy_vseq_workload;
    int unsigned load_pm = 250, cycles = 1500;
    `uvm_object_utils(hy_vseq_patterns_all)
    function new(string name = "hy_vseq_patterns_all");
        super.new(name);
    endfunction
    virtual function void build_phases();
        add_phase(load_pm, HY_PAT_UNIFORM,    cycles);
        add_phase(load_pm, HY_PAT_HOTSPOT,    cycles, 10, 50);
        add_phase(load_pm, HY_PAT_TRANSPOSE,  cycles);
        add_phase(load_pm, HY_PAT_COMPLEMENT, cycles);
        add_phase(load_pm, HY_PAT_NEIGHBOUR,  cycles);
        add_phase(load_pm, HY_PAT_BITREV,     cycles);
    endfunction
endclass

// ------------------------------------------------------------------ directed
class hy_vseq_single extends hy_vseq_base;
    int src = 0, dst = 15;
    `uvm_object_utils(hy_vseq_single)
    function new(string name = "hy_vseq_single");
        super.new(name);
    endfunction
    virtual task body();
        send_from(src, dst, 1, 0);
        wait_idle();
    endtask
endclass

// Zero-load latency: with an empty network and mode XY a packet takes exactly
// distance + 4 cycles (DECISIONS 58). `all_pairs` = 1 runs all 240 flows one by one.
class hy_vseq_zero_load extends hy_vseq_base;
    int          srcs[$] = '{0, 5, 1, 14};
    int          dsts[$] = '{15, 6, 4, 1};
    bit          all_pairs = 0;
    int unsigned n_checked;
    `uvm_object_utils(hy_vseq_zero_load)
    function new(string name = "hy_vseq_zero_load");
        super.new(name);
    endfunction
    protected task one(int s, int d);
        int unsigned n_before = p_sequencer.sb.core.n_ej;
        int unsigned guard = 0;
        send_from(s, d, 1, 0);
        while (p_sequencer.sb.core.n_ej == n_before && guard < 2000) begin wait_cycles(1); guard++; end
        if (p_sequencer.sb.core.n_ej == n_before)
            `uvm_error("ZERO", $sformatf("packet %0d -> %0d was not delivered", s, d))
        else if (p_sequencer.sb.core.last_lat_excess != 0)
            `uvm_error("ZERO", $sformatf("zero-load latency %0d -> %0d is distance + 4 + %0d (expected exactly distance + 4 = %0d)",
                       s, d, p_sequencer.sb.core.last_lat_excess, hy_dist(s, d) + 4))
        n_checked++;
        wait_cycles(6);
    endtask
    virtual task body();
        if (all_pairs) begin
            for (int s = 0; s < HY_NODES; s++)
                for (int d = 0; d < HY_NODES; d++)
                    if (s != d && p_sequencer.sqr[s] != null) one(s, d);
        end else begin
            foreach (srcs[i]) one(srcs[i], dsts[i]);
        end
        wait_idle();
    endtask
endclass

// every source sends `reps` packets to every other node (all sources in parallel)
class hy_vseq_all_pairs extends hy_vseq_base;
    int unsigned reps = 1;
    `uvm_object_utils(hy_vseq_all_pairs)
    function new(string name = "hy_vseq_all_pairs");
        super.new(name);
    endfunction
    virtual task body();
        for (int i = 0; i < HY_NODES; i++) begin
            int s = i;
            if (p_sequencer.sqr[s] == null) continue;
            fork
                begin
                    for (int r = 0; r < reps; r++)
                        for (int k = 1; k < HY_NODES; k++)
                            send_from(s, (s + k) % HY_NODES, 1, 6);
                end
            join_none
        end
        wait fork;
        wait_idle();
    endtask
endclass

// many packets of one flow back to back
class hy_vseq_flow extends hy_vseq_base;
    int src = 3, dst = 12;
    int unsigned count = 200;
    `uvm_object_utils(hy_vseq_flow)
    function new(string name = "hy_vseq_flow");
        super.new(name);
    endfunction
    virtual task body();
        send_from(src, dst, count, 0);
        wait_idle();
    endtask
endclass

// random packet lengths 2..16 flits (outside the 4-flit contract: the router is type-driven)
class hy_vseq_lengths extends hy_vseq_workload;
    `uvm_object_utils(hy_vseq_lengths)
    function new(string name = "hy_vseq_lengths");
        super.new(name);
        len_min = 2; len_max = 16;
    endfunction
    virtual function void build_phases();
        add_phase(100, HY_PAT_UNIFORM, 6000);
    endfunction
endclass

// every node sends to itself (outside the contract: header routed straight to Local)
class hy_vseq_loopback extends hy_vseq_base;
    int unsigned count = 4;
    `uvm_object_utils(hy_vseq_loopback)
    function new(string name = "hy_vseq_loopback");
        super.new(name);
    endfunction
    virtual task body();
        for (int i = 0; i < HY_NODES; i++) begin
            int n = i;
            if (p_sequencer.sqr[n] == null) continue;
            fork
                send_from(n, n, count, 4);
            join_none
        end
        wait fork;
        wait_idle();
    endtask
endclass

// ------------------------------------------------------------------ stress / robustness
class hy_vseq_backpressure extends hy_vseq_base;
    int unsigned load_pm = 120, step_cycles = 1500;
    int          slow_node = 9;
    `uvm_object_utils(hy_vseq_backpressure)
    function new(string name = "hy_vseq_backpressure");
        super.new(name);
    endfunction
    virtual task body();
        hy_cfg cfg = p_sequencer.cfg;
        hy_load_ctl c = hy_load_ctl::type_id::create("ctl");
        c.load_pm = load_pm;
        start_traffic(c);
        cfg.set_all_sinks(HY_RDY_ALWAYS);                  wait_cycles(step_cycles);
        cfg.set_all_sinks(HY_RDY_RANDOM, 50);              wait_cycles(step_cycles);
        cfg.sink_burst_on = 4; cfg.sink_burst_off = 20;
        cfg.set_all_sinks(HY_RDY_BURSTY);                  wait_cycles(step_cycles);
        cfg.set_all_sinks(HY_RDY_RANDOM, 10);              wait_cycles(step_cycles);
        cfg.set_all_sinks(HY_RDY_ALWAYS);
        cfg.sink_mode[slow_node] = HY_RDY_NEVER;           wait_cycles(600);       // one receiver blocked
        cfg.sink_mode[slow_node] = HY_RDY_ALWAYS;          wait_cycles(step_cycles);
        stop_traffic();
        cfg.set_all_sinks(HY_RDY_ALWAYS);
        wait_idle();
    endtask
endclass

// One source never acknowledges the inject_block request: with traffic that makes the
// controller request a mode change, the watchdog must reach ERROR. The test must set
// cfg.expect_drain_timeout = 1. The network stays blocked afterwards, so the traffic
// sequences are killed instead of drained.
class hy_vseq_watchdog extends hy_vseq_base;
    int          stuck_node = 3;
    int unsigned load_pm = 350;
    int unsigned max_cycles = 0;               // 0: watchdog limit + 6000
    `uvm_object_utils(hy_vseq_watchdog)
    function new(string name = "hy_vseq_watchdog");
        super.new(name);
    endfunction
    virtual task body();
        hy_cfg cfg = p_sequencer.cfg;
        hy_load_ctl c = hy_load_ctl::type_id::create("ctl");
        int unsigned limit = (max_cycles != 0) ? max_cycles : cfg.dut_watchdog_limit + 6000;
        int unsigned t = 0;
        c.load_pm = load_pm;
        cfg.vif.src_force_busy[stuck_node] = 1'b1;
        start_traffic(c);
        while (cfg.vif.drain_timeout !== 1'b1 && t < limit) begin wait_cycles(1); t++; end
        if (cfg.vif.drain_timeout !== 1'b1)
            `uvm_error("WATCHDOG", $sformatf("no watchdog ERROR within %0d cycles although node %0d never acknowledges", limit, stuck_node))
        wait_cycles(50);
        kill_traffic();
    endtask
endclass

// reset in the middle of traffic
class hy_vseq_reset extends hy_vseq_base;
    int unsigned load_pm = 150, before_cycles = 2000, reset_cycles = 6, after_cycles = 3000;
    int unsigned resets = 1;
    `uvm_object_utils(hy_vseq_reset)
    function new(string name = "hy_vseq_reset");
        super.new(name);
    endfunction
    virtual task body();
        hy_cfg cfg = p_sequencer.cfg;
        hy_load_ctl c = hy_load_ctl::type_id::create("ctl");
        c.load_pm = load_pm;
        start_traffic(c);
        repeat (resets) begin
            wait_cycles(before_cycles);
            cfg.vif.test_rst_n <= 1'b0;
            wait_cycles(reset_cycles);
            cfg.vif.test_rst_n <= 1'b1;
        end
        wait_cycles(after_cycles);
        stop_traffic();
        wait_idle();
    endtask
endclass

// -----------------------------------------------------------------------------
// Baseline comparison (hy_compare_test). A slow load ramp up and back down through the
// region where the congestion estimate crosses the thresholds, one dwell per load level.
// Per level it prints  [CMP] load=...  mean latency, accepted throughput, mode changes.
// The final [CMP_SUM] line is the one to paste into a table: run the same test for
//   HYSTERoC (DUAL=1)  /  single threshold (DUAL=0, THRESH_SINGLE=128)  /  XY only (XY_ONLY=1)
// by editing the parameters in test.sv, with the SAME seed and plusargs.
// Mode changes are counted from vif.active_mode, independently of the model.
// -----------------------------------------------------------------------------
class hy_vseq_compare extends hy_vseq_base;
    int unsigned lo_pm = 100, hi_pm = 350, step_pm = 25, dwell = 2000;
    hy_pattern_e pattern = HY_PAT_UNIFORM;
    `uvm_object_utils(hy_vseq_compare)
    function new(string name = "hy_vseq_compare");
        super.new(name);
    endfunction

    virtual task body();
        hy_cfg        cfg = p_sequencer.cfg;
        hy_load_ctl   c = hy_load_ctl::type_id::create("ctl");
        int unsigned  levels[$];
        int unsigned  n_chg = 0, chg_prev = 0, total_cycles = 0;
        bit           counting = 1;
        int unsigned  n_ej0, fl0, n_ej_t0, fl_t0;
        longint       lat0, lat_t0;
        int unsigned  n_chg_first_half = 0;

        for (int l = lo_pm; l <= hi_pm; l += step_pm) levels.push_back(l);
        for (int l = hi_pm - step_pm; l >= lo_pm; l -= step_pm) levels.push_back(l);

        c.pattern = pattern;
        c.load_pm = levels[0];
        start_traffic(c);
        wait_cycles(500);                                  // warm-up, not measured

        fork
            begin : count_changes
                bit prev = cfg.vif.active_mode;
                while (counting) begin
                    @(posedge cfg.vif.clk);
                    if (cfg.vif.active_mode !== prev) begin n_chg++; prev = cfg.vif.active_mode; end
                end
            end
        join_none

        n_ej_t0 = p_sequencer.sb.core.n_ej; fl_t0 = p_sequencer.sb.core.n_ej_flits; lat_t0 = p_sequencer.sb.core.lat_sum;
        n_chg = 0;
        foreach (levels[i]) begin
            c.load_pm = levels[i];
            n_ej0 = p_sequencer.sb.core.n_ej; fl0 = p_sequencer.sb.core.n_ej_flits; lat0 = p_sequencer.sb.core.lat_sum;
            chg_prev = n_chg;
            wait_cycles(dwell);
            total_cycles += dwell;
            begin
                int unsigned dn = p_sequencer.sb.core.n_ej - n_ej0;
                int unsigned df = p_sequencer.sb.core.n_ej_flits - fl0;
                longint      dl = p_sequencer.sb.core.lat_sum - lat0;
                `uvm_info("CMP", $sformatf("level %0d load=0.%03d  packets=%0d  mean_latency=%0d.%02d  accepted=%0d.%03d flits/node/cycle  mode_changes=%0d",
                          i, levels[i], dn, (dn == 0) ? 0 : int'(dl / dn), (dn == 0) ? 0 : int'((dl * 100 / dn) % 100),
                          int'((df * 1000 / dwell / HY_NODES) / 1000), int'((df * 1000 / dwell / HY_NODES) % 1000),
                          n_chg - chg_prev), UVM_LOW)
            end
        end
        begin
            int unsigned dn = p_sequencer.sb.core.n_ej - n_ej_t0;
            int unsigned df = p_sequencer.sb.core.n_ej_flits - fl_t0;
            longint      dl = p_sequencer.sb.core.lat_sum - lat_t0;
            `uvm_info("CMP_SUM", $sformatf("dual=%0d xy_only=%0d ewma=%0d thigh=%0d tlow=%0d thresh_single=%0d | pattern=%s ramp %0d..%0d step %0d dwell %0d | packets=%0d mean_latency=%0d.%02d accepted=%0d.%03d | MODE_CHANGES=%0d in %0d cycles (%0d per 1000 cycles)",
                      cfg.dut_dual, cfg.dut_xy_only, cfg.dut_use_ewma, cfg.dut_thigh, cfg.dut_tlow, cfg.dut_thresh_single,
                      pattern.name(), lo_pm, hi_pm, step_pm, dwell,
                      dn, (dn == 0) ? 0 : int'(dl / dn), (dn == 0) ? 0 : int'((dl * 100 / dn) % 100),
                      int'((df * 1000 / total_cycles / HY_NODES) / 1000), int'((df * 1000 / total_cycles / HY_NODES) % 1000),
                      n_chg, total_cycles, n_chg * 1000 / total_cycles), UVM_LOW)
        end
        counting = 0;
        stop_traffic();
        wait_idle();
    endtask
endclass
