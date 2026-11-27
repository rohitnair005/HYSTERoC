// =============================================================================
// hy_protocol_checker.svh : UVM wrapper of hy_model (hy_model.svh: cycle-accurate
// reference model of the control part of noc_top + protocol invariants, validated
// against the real RTL in unit/tb_unit_model.sv). One observation per clock edge
// (values before the edge, what the DUT flip-flops see) is fed to the model; each
// model error becomes a uvm_error.
//   cfg.chk_models     M1..M6 compare EWMA, global maxima, hysteresis, FSM, drain
//                      detector and statistics counters with the model every cycle
//   cfg.chk_protocol   invariants I1..I6 (drained => empty network, mode change only
//                      in SWITCH with an empty network, no injection in DRAIN/SWITCH,
//                      router error flags, watchdog, XY-only)
//   cfg.expect_drain_timeout  the test provokes the watchdog: ERROR is then REQUIRED
// check_phase also reports: flits still in flight, assertion failures counted by
// hy_sva (vif.sva_errors).
// The drain-detector comparison (M5) needs the link taps (vif.link_taps = 1).
// =============================================================================
class hy_protocol_checker extends uvm_component;

    hy_cfg        cfg;
    virtual hy_if vif;
    hy_model      model;

    `uvm_component_utils(hy_protocol_checker)

    function new(string name, uvm_component parent);
        super.new(name, parent);
        model = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        if (vif == null) `uvm_fatal("VIF", "cfg.vif is null")
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
        model.xy_only        = cfg.dut_xy_only;
        model.dual           = cfg.dut_dual;
        model.use_ewma       = cfg.dut_use_ewma;
        model.thigh          = cfg.dut_thigh;
        model.tlow           = cfg.dut_tlow;
        model.thresh_single  = cfg.dut_thresh_single;
        model.sample_period  = cfg.dut_sample_period;
        model.wd_limit       = cfg.dut_watchdog_limit;
        model.mask_cycles    = cfg.dut_post_resume_mask;
        model.confirm        = cfg.dut_drain_confirm;
        model.enable_stats   = cfg.dut_enable_stats;
        model.switch_policy  = cfg.dut_switch_policy;
        model.expect_timeout = cfg.expect_drain_timeout;
        model.chk_models     = cfg.chk_models;
        model.chk_invariants = cfg.chk_protocol;
    endfunction

    protected function hy_obs_t sample();
        hy_obs_t o;
        logic [15:0] la;
        for (int k = 0; k < HY_NODES; k++) la[k] = (|vif.link_out_valid[5*k +: 5]) | vif.inj_valid[k];
        o.fifo_occ_all = vif.fifo_occ_all;   o.ewma_all = vif.ewma_all;
        o.global_congestion = vif.global_congestion;  o.global_raw = vif.global_raw;
        o.req_mode = vif.req_mode;           o.active_mode = vif.active_mode;
        o.ctrl_state = vif.ctrl_state;       o.inject_block_req = vif.inject_block_req;
        o.inject_block_ack = vif.inject_block_ack;   o.src_empty = vif.src_empty;
        o.router_empty = vif.router_empty;   o.network_drained = vif.network_drained;
        o.drain_timeout = vif.drain_timeout; o.transition_busy = vif.transition_busy;
        o.proto_err_any = vif.proto_err_any; o.alloc_err_any = vif.alloc_err_any;
        o.inj_valid = vif.inj_valid;  o.inj_ready = vif.inj_ready;
        o.ej_valid  = vif.ej_valid;   o.ej_ready  = vif.ej_ready;
        o.link_active = la;           o.has_links = vif.link_taps;
        o.cycle_cnt = vif.cycle_cnt;  o.tot_blocked = vif.tot_blocked; o.tot_ackwait = vif.tot_ackwait;
        o.tot_drain = vif.tot_drain;  o.transitions = vif.transitions;
        return o;
    endfunction

    protected function void emit_errors();
        while (model.errors.size() != 0) begin
            string m = model.errors.pop_front();
            `uvm_error("PROT", m)
        end
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            if (vif.rst_n !== 1'b1) begin model.reset(); continue; end
            if (!cfg.chk_models && !cfg.chk_protocol) continue;
            model.step(sample());
            emit_errors();
        end
    endtask

    function void check_phase(uvm_phase phase);
        if (cfg.chk_protocol) begin
            if (model.inflight != 0 && !cfg.expect_drain_timeout)
                `uvm_error("PROT", $sformatf("%0d flits are still inside the network at the end of the test", model.inflight))
            if (cfg.expect_drain_timeout && !model.err_seen)
                `uvm_error("PROT", "the test expected a watchdog timeout (controller ERROR state) but it never happened")
        end
        if (cfg.dut_switch_policy && cfg.require_inflight_switch && model.n_chg_inflight == 0)
            `uvm_error("PROT", "no-drain policy: no mode change happened with flits in flight, the policy was not exercised")
        if (vif.sva_errors != 0)
            `uvm_error("SVA", $sformatf("%0d concurrent assertion failure(s) (see the messages above)", vif.sva_errors))
        emit_errors();
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("PROT", $sformatf("%0d cycles checked, %0d mode changes (%0d with flits in flight), %0d cycles in ERROR, %0d errors, %0d SVA failures",
                  model.n_cycles, model.n_mode_changes, model.n_chg_inflight, model.n_error_state_cycles, model.n_errors, vif.sva_errors), UVM_LOW)
    endfunction

endclass
