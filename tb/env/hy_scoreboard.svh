// =============================================================================
// hy_scoreboard.svh : UVM wrapper around hy_sb_core (all rules are documented in
// hy_sb_core.svh and unit tested without UVM). Three inputs:
//   inj_imp  packets published by the 16 inject monitors
//   ej_imp   packets published by the 16 eject monitors
//   hop_imp  header-hop events of the hop monitor
// On reset the expected-packet table is cleared (a reset legitimately loses
// whatever was inside the network). check_phase reports packets that were never
// delivered. Tests can wait for an empty scoreboard with wait_idle().
// =============================================================================
`uvm_analysis_imp_decl(_inj)
`uvm_analysis_imp_decl(_ej)
`uvm_analysis_imp_decl(_hop)

class hy_scoreboard extends uvm_scoreboard;

    hy_cfg        cfg;
    virtual hy_if vif;
    hy_sb_core    core;

    uvm_analysis_imp_inj #(hy_item,   hy_scoreboard) inj_imp;
    uvm_analysis_imp_ej  #(hy_item,   hy_scoreboard) ej_imp;
    uvm_analysis_imp_hop #(hy_hop_ev, hy_scoreboard) hop_imp;

    `uvm_component_utils(hy_scoreboard)

    function new(string name, uvm_component parent);
        super.new(name, parent);
        inj_imp = new("inj_imp", this);
        ej_imp  = new("ej_imp", this);
        hop_imp = new("hop_imp", this);
        core    = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        core.chk_order           = cfg.dut_xy_only;      // adaptive routing may reorder a flow, XY may not
        core.chk_latency         = cfg.chk_latency;
        core.chk_hops            = cfg.chk_route;
        core.allow_dest_mismatch = cfg.allow_dest_mismatch;
    endfunction

    protected function hy_pkt_rec to_rec(hy_item it);
        hy_pkt_rec r = new();
        r.src = it.src; r.dst = it.dst; r.pid = it.pid; r.payload = it.payload;
        r.cyc_first = it.cyc_first; r.cyc_last = it.cyc_last;
        r.tx_node = it.tx_node; r.rx_node = it.rx_node; r.frame_err = it.frame_err;
        return r;
    endfunction

    protected function void emit_errors();
        while (core.errors.size() != 0) begin
            string s = core.errors.pop_front();
            `uvm_error("SB", s)
        end
    endfunction

    function void write_inj(hy_item it);
        if (!cfg.chk_scoreboard) return;
        core.on_inject(to_rec(it));
        emit_errors();
    endfunction

    function void write_ej(hy_item it);
        if (!cfg.chk_scoreboard) return;
        core.on_eject(to_rec(it));
        emit_errors();
    endfunction

    function void write_hop(hy_hop_ev ev);
        if (!cfg.chk_scoreboard) return;
        core.on_hop_header(ev.key);
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(negedge vif.rst_n);
            core.reset();
        end
    endtask

    function int unsigned n_pending();  return core.n_pending();  endfunction

    // wait until every injected packet has been delivered (or the time-out expires)
    task wait_idle(int unsigned timeout_cycles, output bit ok);
        int unsigned c = 0;
        @(posedge vif.clk);              // let the monitors of the current edge publish first
        @(posedge vif.clk);
        while (core.n_pending() != 0 && c < timeout_cycles) begin
            @(posedge vif.clk);
            c++;
        end
        ok = (core.n_pending() == 0);
    endtask

    function void check_phase(uvm_phase phase);
        if (!cfg.chk_scoreboard) return;
        if (!cfg.expect_drain_timeout) core.check_end();   // after a provoked watchdog ERROR the network stays blocked on purpose
        emit_errors();
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("injected %0d packets (%0d flits), delivered %0d (%0d flits), pending %0d, errors %0d, min latency excess over distance+length: %0d",
                  core.n_inj, core.n_inj_flits, core.n_ej, core.n_ej_flits, core.n_pending(), core.n_errors,
                  (core.n_ej == 0) ? 0 : core.lat_min_excess), UVM_LOW)
    endfunction

endclass
