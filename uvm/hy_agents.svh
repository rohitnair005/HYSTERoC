// =============================================================================
// hy_agents.svh : inject agent (sequencer + driver + monitor) and eject agent
// (sink driver + monitor) for ONE node. The env sets `node` right after creating
// the agent. Both expose the monitor's analysis port as `ap`.
// =============================================================================
class hy_inject_agent extends uvm_agent;

    int                  node;
    hy_cfg               cfg;
    hy_sequencer         sqr;
    hy_inject_driver     drv;
    hy_inject_monitor    mon;
    uvm_analysis_port #(hy_item) ap;

    `uvm_component_utils(hy_inject_agent)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        ap  = new("ap", this);
        mon = hy_inject_monitor::type_id::create("mon", this);
        mon.node = node;
        if (cfg.inject_en[node]) begin
            sqr = hy_sequencer::type_id::create("sqr", this);
            drv = hy_inject_driver::type_id::create("drv", this);
            drv.node = node;
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        mon.ap.connect(ap);
        if (drv != null) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass

class hy_eject_agent extends uvm_agent;

    int                  node;
    hy_cfg               cfg;
    hy_sink_driver       drv;
    hy_eject_monitor     mon;
    uvm_analysis_port #(hy_item) ap;

    `uvm_component_utils(hy_eject_agent)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        ap  = new("ap", this);
        mon = hy_eject_monitor::type_id::create("mon", this);
        mon.node = node;
        if (cfg.eject_en[node]) begin
            drv = hy_sink_driver::type_id::create("drv", this);
            drv.node = node;
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        mon.ap.connect(ap);
    endfunction

endclass
