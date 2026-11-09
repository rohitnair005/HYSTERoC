// =============================================================================
// hy_cfg.svh : configuration object shared by the whole environment. Put it into
// the config_db (key "cfg") from the test; the tb top puts the virtual interface
// into the config_db (key "vif") before run_test, and the base test copies it
// into this object.
// =============================================================================
class hy_cfg extends uvm_object;

    virtual hy_if vif;

    // ---- which nodes have an active inject / eject agent
    bit inject_en[HY_NODES];
    bit eject_en[HY_NODES];

    // ---- sink backpressure per node (ej_ready is a registered random bit, never
    //      a function of ej_valid: DECISIONS 38)
    hy_ready_mode_e   sink_mode[HY_NODES];
    int unsigned      sink_pct[HY_NODES];        // RANDOM / BURSTY: percent of cycles ready (0..100)
    int unsigned      sink_burst_on;             // BURSTY: ready run length (cycles)
    int unsigned      sink_burst_off;            // BURSTY: stall run length (cycles)

    // ---- inject side
    int unsigned      flit_bubble_pct = 0;       // chance (0..90 %) to leave valid low for a cycle between flits of one packet

    // ---- source behaviour
    int unsigned      src_bubble_pct = 0;        // chance (percent) of an idle cycle inside a packet after each flit

    // ---- DUT configuration echo (the tb top sets it from its own parameters)
    bit               dut_xy_only    = 0;
    bit               dut_dual       = 1;
    bit               dut_use_ewma   = 1;
    int unsigned      dut_thigh      = 160;
    int unsigned      dut_tlow       = 96;
    int unsigned      dut_thresh_single = 128;
    int unsigned      dut_watchdog_limit = 1000;
    int unsigned      dut_post_resume_mask = 0;
    int unsigned      dut_sample_period = 1;
    int unsigned      dut_drain_confirm = 2;
    bit               dut_enable_stats  = 1;
    int               dut_det_variant   = 0;     // no-drain only: 0 oe_fixed (v2), 1 oe_par source-parity (v3)
    bit               dut_switch_policy = 0;     // 0 drain-and-switch, 1 no-drain (deterministic <-> adaptive Odd-Even)

    // ---- checking switches
    bit chk_scoreboard   = 1;     // delivery exactly once, right node, right content, per-source order
    bit chk_route        = 1;     // every flit hop is a legal output (needs a hop observer, batch U3/U4)
    bit chk_protocol     = 1;     // mode-change / drain / watchdog rules
    bit chk_latency      = 1;     // network latency >= distance + 4
    bit chk_models       = 1;     // control-path reference model (EWMA, hysteresis, FSM, drain detector, stats)
    bit cov_en           = 1;     // functional coverage collection
    bit expect_drain_timeout = 0; // a test that provokes the watchdog sets this; then ERROR is required, not forbidden
    bit allow_dest_mismatch  = 0; // set by negative tests only
    bit require_inflight_switch = 0; // no-drain policy: at least one mode change must happen with flits in flight

    // ---- end of test
    int unsigned      drain_timeout_cycles = 20000;   // max cycles to wait for the network to empty at the end

    `uvm_object_utils(hy_cfg)

    function new(string name = "hy_cfg");
        super.new(name);
        foreach (inject_en[i]) begin
            inject_en[i]  = 1;
            eject_en[i]   = 1;
            sink_mode[i]  = HY_RDY_ALWAYS;
            sink_pct[i]   = 100;
        end
        sink_burst_on  = 8;
        sink_burst_off = 8;
    endfunction

    function void set_all_sinks(hy_ready_mode_e m, int unsigned pct = 100);
        foreach (sink_mode[i]) begin sink_mode[i] = m; sink_pct[i] = pct; end
    endfunction

    function string convert2string();
        return $sformatf("cfg: policy=%0d det=%0d xy_only=%0d dual=%0d ewma=%0d thigh=%0d tlow=%0d wd=%0d | chk sb=%0d route=%0d prot=%0d lat=%0d | expect_timeout=%0d",
                         dut_switch_policy, dut_det_variant, dut_xy_only, dut_dual, dut_use_ewma, dut_thigh, dut_tlow, dut_watchdog_limit,
                         chk_scoreboard, chk_route, chk_protocol, chk_latency, expect_drain_timeout);
    endfunction

endclass
