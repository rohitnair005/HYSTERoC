// =============================================================================
// hy_hop_monitor.svh : watches the OUTPUT of every router (80 router output ports,
// through the taps of hy_if) and checks the routing behaviour of the DUT. Needs
// vif.link_taps = 1 (the tb top connects the taps); without it the monitor stays
// silent and warns once.
//
// Checks
//   H1  a header leaves a router through a LEGAL output for the active mode
//       (hy_route_check: XY = exactly the XY port, adaptive = the Odd-Even set)
//   H2  nothing leaves through a port that does not exist (mesh boundary)
//   H3  packets never interleave on an output: header .. body .. tail, no header
//       before the tail, no body/tail without a header
//   H4  out_valid is only asserted together with out_ready (DECISIONS 38)
// Publishes one hy_hop_ev per header transfer out of a router (the scoreboard
// counts them: a minimal path has distance + 1).
// =============================================================================
class hy_hop_ev extends uvm_object;
    int          router;
    int          port;
    int unsigned key;        // {src, pid}
    int unsigned cyc;
    bit          mode;       // active mode when the header left
    logic [4:0]  legal;      // legal output set for this header at this router (reference model)
    int          n_cand;     // number of legal outputs
    `uvm_object_utils(hy_hop_ev)
    function new(string name = "hy_hop_ev");
        super.new(name);
    endfunction
endclass

class hy_hop_monitor extends uvm_monitor;

    hy_cfg        cfg;
    virtual hy_if vif;
    uvm_analysis_port #(hy_hop_ev) ap;

    int unsigned n_hdr, n_flits, n_err;
    protected bit in_pkt [HY_NODES*5];
    protected bit warned;
    protected int unsigned since_change = 100;   // cycles since active_mode last changed
    protected bit prev_mode;

    `uvm_component_utils(hy_hop_monitor)

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

    protected function bit port_exists(int n, int p);
        case (p)
            HY_P_N: return hy_y(n) != 0;
            HY_P_S: return hy_y(n) != HY_DIM - 1;
            HY_P_E: return hy_x(n) != HY_DIM - 1;
            HY_P_W: return hy_x(n) != 0;
            default: return 1;
        endcase
    endfunction

    protected function void bad(string msg);
        n_err++;
        `uvm_error("HOP", msg)
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.clk);
            if (vif.rst_n !== 1'b1) begin
                foreach (in_pkt[i]) in_pkt[i] = 0;
                continue;
            end
            if (vif.active_mode !== prev_mode) since_change = 0;
            else if (since_change < 100) since_change++;
            prev_mode = vif.active_mode;
            if (!cfg.chk_route) continue;
            if (!vif.link_taps) begin
                if (!warned && vif.cyc > 4) begin
                    warned = 1;
                    `uvm_warning("HOP", "link taps are not connected (vif.link_taps = 0): routing checks are OFF")
                end
                continue;
            end
            for (int n = 0; n < HY_NODES; n++)
                for (int p = 0; p < 5; p++) check_port(n, p);
        end
    endtask

    protected function void check_port(int n, int p);
        bit v = (vif.link_out_valid[5*n + p] === 1'b1);
        bit r = (vif.link_out_ready[5*n + p] === 1'b1);
        int i = 5*n + p;
        hy_flit_t f;
        bit eff_mode;
        if (v && !port_exists(n, p)) begin
            bad($sformatf("H2 router %0d: flit leaving through non-existent port %0d", n, p));
            return;
        end
        if (v && !r) bad($sformatf("H4 router %0d port %0d: out_valid without out_ready", n, p));
        if (!(v && r)) return;
        f.ftype = vif.link_out_type[10*n + 2*p +: 2];
        f.data  = vif.link_out_data[80*n + 16*p +: 16];
        n_flits++;
        if (f.ftype == HY_FT_HDR) begin
            string e;
            hy_hop_ev ev;
            if (in_pkt[i]) bad($sformatf("H3 router %0d port %0d: header before the tail of the previous packet", n, p));
            in_pkt[i] = 1;
            n_hdr++;
            // no-drain policy: a header routed just before a mode change may leave up to 2 cycles after it,
            // so right after a change any Odd-Even candidate is accepted (still a hard legality check)
            eff_mode = vif.active_mode | (hy_nodrain_policy && since_change < 3);
            e = hy_route_check(eff_mode, n, p, f.data);
            if (e != "") bad({"H1 ", e});
            ev = hy_hop_ev::type_id::create("hop");
            ev.router = n; ev.port = p; ev.key = {hy_hdr_src(f.data), hy_hdr_pid(f.data)}; ev.cyc = vif.cyc;
            ev.mode = vif.active_mode; ev.legal = hy_legal_mask(eff_mode, n, f.data);
            ev.n_cand = $countones(ev.legal);
            ap.write(ev);
        end else begin
            if (!in_pkt[i]) bad($sformatf("H3 router %0d port %0d: flit of type %0b without a header (interleaved or lost header)", n, p, f.ftype));
            if (f.ftype == HY_FT_TAIL) in_pkt[i] = 0;
            if (f.ftype == HY_FT_RSVD) bad($sformatf("H3 router %0d port %0d: reserved flit type", n, p));
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("HOP_MON", $sformatf("%0d header hops, %0d flits, %0d errors", n_hdr, n_flits, n_err), UVM_MEDIUM)
    endfunction

endclass
