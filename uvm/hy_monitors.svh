// =============================================================================
// hy_monitors.svh : inject monitor and eject monitor. Passive: sample the Local
// ports at every clock edge (active region, i.e. what the DUT flip-flops see),
// reassemble flits into packets and publish each packet on `ap` at its tail.
//
// Checks done here (protocol level only, the scoreboard does content checks):
//   inject monitor : flit sequence is header, body.., tail; no reserved type;
//                    header source field = this node.
//   eject monitor  : same framing checks on what the DUT delivers; and
//                    DUT OUTPUT STABILITY: after ej_valid && !ej_ready the DUT
//                    must keep ej_valid, data and type unchanged next cycle.
// A malformed packet is still published with frame_err set (the scoreboard then
// reports it); the monitor keeps going.
// =============================================================================
class hy_port_monitor_base extends uvm_monitor;

    int           node;
    bit           is_eject;
    hy_cfg        cfg;
    virtual hy_if vif;
    uvm_analysis_port #(hy_item) ap;

    int unsigned n_pkts, n_flits, n_frame_err;

    protected hy_flit_t q[$];
    protected int unsigned first_cyc;
    protected bit in_pkt;
    // eject stability memory
    protected bit        prev_stall;
    protected hy_flit_t  prev_flit;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        if (vif == null) `uvm_fatal("VIF", "cfg.vif is null")
    endfunction

    protected function void frame_error(string msg);
        n_frame_err++;
        `uvm_error("FRAME", $sformatf("%s port %0d: %s", is_eject ? "eject" : "inject", node, msg))
    endfunction

    protected function void publish(string err);
        hy_item it = hy_item::type_id::create("obs");
        bit ok = it.from_flits(q);
        if (err != "") begin
            it.frame_err = (it.frame_err == "") ? err : {err, "; ", it.frame_err};
            ok = 0;
        end
        it.cyc_first = first_cyc;
        it.cyc_last  = vif.cyc;
        if (is_eject) it.rx_node = node; else it.tx_node = node;
        if (!ok && it.frame_err == "") it.frame_err = "malformed";
        ap.write(it);
        n_pkts++;
        q.delete();
        in_pkt = 0;
    endfunction

    // one transferred flit (valid && ready at this edge)
    protected function void take_flit(hy_flit_t f);
        string err = "";
        n_flits++;
        if (f.ftype == HY_FT_RSVD) begin frame_error("reserved flit type 2'b11"); err = "reserved flit type"; end
        if (!in_pkt) begin
            if (f.ftype != HY_FT_HDR) begin frame_error($sformatf("flit of type %0b outside a packet (no header)", f.ftype)); return; end
            in_pkt = 1; first_cyc = vif.cyc; q.delete();
            if (!is_eject && hy_hdr_src(f.data) != node[3:0])
                frame_error($sformatf("header source field %0d differs from the injecting node", hy_hdr_src(f.data)));
        end else if (f.ftype == HY_FT_HDR) begin
            frame_error("header inside a packet (previous packet had no tail)");
            q.delete(); first_cyc = vif.cyc;
        end
        q.push_back(f);
        if (f.ftype == HY_FT_TAIL) publish(err);
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            if (vif.rst_n !== 1'b1) begin q.delete(); in_pkt = 0; prev_stall = 0; continue; end
            sample_edge();
        end
    endtask

    protected virtual function void sample_edge();
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("PORT_MON", $sformatf("%s %0d: %0d packets, %0d flits, %0d framing errors, %s",
                  is_eject ? "eject" : "inject", node, n_pkts, n_flits, n_frame_err,
                  in_pkt ? "PACKET IN PROGRESS" : "idle"), UVM_MEDIUM)
    endfunction

endclass

class hy_inject_monitor extends hy_port_monitor_base;
    `uvm_component_utils(hy_inject_monitor)
    function new(string name, uvm_component parent);
        super.new(name, parent);
        is_eject = 0;
    endfunction
    protected virtual function void sample_edge();
        if (vif.inj_valid[node] === 1'b1 && vif.inj_ready[node] === 1'b1) begin
            hy_flit_t f;
            f.ftype = vif.inj_ty(node);
            f.data  = vif.inj_word(node);
            take_flit(f);
        end
    endfunction
endclass

class hy_eject_monitor extends hy_port_monitor_base;
    `uvm_component_utils(hy_eject_monitor)
    function new(string name, uvm_component parent);
        super.new(name, parent);
        is_eject = 1;
    endfunction
    protected virtual function void sample_edge();
        hy_flit_t f;
        bit v = (vif.ej_valid[node] === 1'b1);
        bit r = (vif.ej_ready[node] === 1'b1);
        f.ftype = vif.ej_ty(node);
        f.data  = vif.ej_word(node);
        if (^{vif.ej_valid[node], vif.ej_ready[node]} === 1'bx)
            `uvm_error("XVAL", $sformatf("eject port %0d: ej_valid or ej_ready is X/Z", node))
        // stability of a stalled output
        if (prev_stall) begin
            if (!v)                         `uvm_error("EJ_STABLE", $sformatf("eject port %0d: ej_valid dropped while stalled", node))
            else if (f !== prev_flit)       `uvm_error("EJ_STABLE", $sformatf("eject port %0d: flit changed while stalled (%0h -> %0h)", node, prev_flit, f))
        end
        prev_stall = v && !r;
        prev_flit  = f;
        if (v && r) take_flit(f);
    endfunction
endclass
