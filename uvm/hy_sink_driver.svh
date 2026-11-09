// =============================================================================
// hy_sink_driver.svh : drives ej_ready of ONE node (the receiver side). The ready
// value for the next cycle is chosen from cfg.sink_mode[node] every clock edge, so
// a test can change the backpressure while it runs. It never looks at ej_valid
// (DECISIONS 38: the DUT requires ej_ready not to depend on ej_valid in the same
// cycle; a registered random bit is also what the sink of the plain testbenches
// does).
//   ALWAYS : ready = 1            NEVER : ready = 0
//   RANDOM : ready with probability sink_pct percent per cycle
//   BURSTY : sink_burst_on cycles ready, sink_burst_off cycles stalled, repeating
//            (sink_pct is ignored)
// =============================================================================
class hy_sink_driver extends uvm_component;

    int           node;
    hy_cfg        cfg;
    virtual hy_if vif;

    protected int unsigned burst_cnt;
    protected bit          burst_ready;

    `uvm_component_utils(hy_sink_driver)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        if (vif == null) `uvm_fatal("VIF", "cfg.vif is null")
    endfunction

    task run_phase(uvm_phase phase);
        bit nxt;
        vif.ej_ready[node] <= 1'b0;
        forever begin
            @(posedge vif.clk);
            case (cfg.sink_mode[node])
                HY_RDY_ALWAYS: nxt = 1'b1;
                HY_RDY_NEVER:  nxt = 1'b0;
                HY_RDY_RANDOM: nxt = ($urandom_range(99) < cfg.sink_pct[node]);
                HY_RDY_BURSTY: begin
                    if (burst_cnt == 0) begin
                        burst_ready = ~burst_ready;
                        burst_cnt   = burst_ready ? cfg.sink_burst_on : cfg.sink_burst_off;
                        if (burst_cnt == 0) burst_cnt = 1;
                    end
                    burst_cnt = burst_cnt - 1;
                    nxt = burst_ready;
                end
                default:       nxt = 1'b1;
            endcase
            vif.ej_ready[node] <= nxt;
        end
    endtask

endclass
