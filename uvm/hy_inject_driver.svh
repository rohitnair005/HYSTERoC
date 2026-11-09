// =============================================================================
// hy_inject_driver.svh : drives ONE node's Local input port and implements the
// SOURCE side of the transition protocol for that node.
//
// Packet start rule (identical to rtl/traffic_generator.v, DECISIONS 56): at a
// clock edge where `inject_block_req` is 0 (sampled before the edge) a waiting
// packet is STARTED: src_busy and the header are driven in that same edge, so
// they are visible in the next cycle. A started packet always finishes. While
// no packet is started, src_busy = 0 (src_empty = 1, ack = block_req).
// After the tail transfer src_busy is cleared; the next packet can be decided at
// the following edge (one idle cycle between packets).
//
// Flits: header, body..., tail, each held (valid, data, type stable) until
// `inj_ready` is sampled 1 with valid 1. Optional source bubbles inside a
// packet: cfg.src_bubble_pct. Reset: the loop is aborted, the port is idle, a
// pending item is completed so that its sequence does not hang.
// =============================================================================
class hy_inject_driver extends uvm_driver #(hy_item);

    int          node;
    hy_cfg       cfg;
    virtual hy_if vif;

    int unsigned n_pkts;       // packets fully injected
    int unsigned n_flits;      // flits transferred
    bit [7:0]    pid_cnt;
    protected bit have_item;

    `uvm_component_utils(hy_inject_driver)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        if (vif == null) `uvm_fatal("VIF", "cfg.vif is null")
    endfunction

    task drive_idle();
        vif.inj_valid[node]          <= 1'b0;
        vif.inj_data[16*node +: 16]  <= 16'h0000;
        vif.inj_type[2*node +: 2]    <= 2'b00;
        vif.src_busy[node]           <= 1'b0;
    endtask

    task run_phase(uvm_phase phase);
        drive_idle();
        forever begin
            wait (vif.rst_n === 1'b1);
            fork
                drive_loop();
                begin @(negedge vif.rst_n); end
            join_any
            disable fork;
            drive_idle();
            if (have_item) begin seq_item_port.item_done(); have_item = 0; end
            pid_cnt = 0;
        end
    endtask

    protected task drive_loop();
        forever begin
            seq_item_port.get_next_item(req);
            have_item = 1;
            drive_packet(req);
            seq_item_port.item_done();
            have_item = 0;
        end
    endtask

    protected task drive_packet(hy_item it);
        hy_flit_t q[$];
        if (it.idle_only) begin                         // workload pause, no packet
            repeat ((it.gap > 0) ? it.gap : 1) @(posedge vif.clk);
            return;
        end
        it.src = node[3:0];
        if (it.auto_pid) begin it.pid = pid_cnt; pid_cnt = pid_cnt + 1; end
        it.to_flits(q);

        repeat (it.gap) @(posedge vif.clk);

        // wait for the permission to start: first edge with inject_block_req == 0
        do @(posedge vif.clk); while (vif.inject_block_req !== 1'b0);

        vif.src_busy[node] <= 1'b1;                       // started: from now on no ack, src_empty = 0
        for (int i = 0; i < q.size(); i++) begin
            vif.inj_data[16*node +: 16] <= q[i].data;
            vif.inj_type[2*node +: 2]   <= q[i].ftype;
            vif.inj_valid[node]         <= 1'b1;
            do @(posedge vif.clk); while (vif.inj_ready[node] !== 1'b1);   // transfer at this edge
            n_flits++;
            if (i != q.size() - 1 && cfg.src_bubble_pct > 0 && $urandom_range(99) < cfg.src_bubble_pct) begin
                vif.inj_valid[node] <= 1'b0;              // idle cycle(s) inside the packet
                repeat ($urandom_range(1, 3)) @(posedge vif.clk);
            end
        end
        vif.inj_valid[node] <= 1'b0;
        vif.src_busy[node]  <= 1'b0;
        n_pkts++;
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("INJ_DRV", $sformatf("node %0d: %0d packets, %0d flits injected", node, n_pkts, n_flits), UVM_MEDIUM)
    endfunction

endclass
