// =============================================================================
// hy_env.svh : the environment: 16 inject agents, 16 eject agents, the virtual
// sequencer, the hop monitor, the scoreboard, the protocol checker (control-path
// model + invariants) and the functional coverage.
// Needs `cfg` in the config_db (key "cfg", visible to this component and below).
// =============================================================================
class hy_env extends uvm_env;

    hy_cfg            cfg;
    hy_inject_agent   inj[HY_NODES];
    hy_eject_agent    ej[HY_NODES];
    hy_vseqr          vseqr;
    hy_hop_monitor    hop;
    hy_scoreboard     sb;
    hy_protocol_checker pchk;
    hy_coverage       cov;

    `uvm_component_utils(hy_env)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vseqr = hy_vseqr::type_id::create("vseqr", this);
        hop   = hy_hop_monitor::type_id::create("hop", this);
        sb    = hy_scoreboard::type_id::create("sb", this);
        pchk  = hy_protocol_checker::type_id::create("pchk", this);
        cov   = hy_coverage::type_id::create("cov", this);
        for (int n = 0; n < HY_NODES; n++) begin
            inj[n] = hy_inject_agent::type_id::create($sformatf("inj_%0d", n), this);
            inj[n].node = n;
            ej[n]  = hy_eject_agent::type_id::create($sformatf("ej_%0d", n), this);
            ej[n].node = n;
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        for (int n = 0; n < HY_NODES; n++) begin
            vseqr.sqr[n] = inj[n].sqr;                                   // null when the node is not active
            inj[n].ap.connect(sb.inj_imp);
            inj[n].ap.connect(cov.inj_imp);
            ej[n].ap.connect(sb.ej_imp);
        end
        vseqr.cfg = cfg;
        vseqr.sb  = sb;
        hop.ap.connect(sb.hop_imp);
        hop.ap.connect(cov.hop_imp);
    endfunction

endclass
