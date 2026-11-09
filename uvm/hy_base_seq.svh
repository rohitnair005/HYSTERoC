// =============================================================================
// hy_base_seq.svh : the basic per-node sequence. Sends `n_pkts` random packets
// from node `my_node` (the driver overwrites src and, with auto_pid, pid).
// Constraint hooks: `dst_fixed` (>= 0) forces the destination; `gap_max` bounds
// the idle time before each packet. The U5 library builds all workloads on this.
// =============================================================================
class hy_item_seq extends uvm_sequence #(hy_item);

    int unsigned n_pkts   = 10;
    int          my_node  = 0;
    int          dst_fixed = -1;
    int unsigned gap_max  = 8;
    int unsigned n_sent;

    `uvm_object_utils(hy_item_seq)

    function new(string name = "hy_item_seq");
        super.new(name);
    endfunction

    virtual task body();
        for (int unsigned i = 0; i < n_pkts; i++) begin
            req = hy_item::type_id::create($sformatf("pkt_%0d", i));
            start_item(req);
            if (!req.randomize() with { src == my_node[3:0];
                                        gap <= gap_max;
                                        if (dst_fixed >= 0) dst == dst_fixed[3:0]; })
                `uvm_fatal("RAND", "randomize failed")
            finish_item(req);
            n_sent++;
        end
    endtask

endclass

// =============================================================================
// Workload control + the per-node traffic sequence of the workload library (U5).
// =============================================================================
// Shared, live-editable description of the traffic every node generates. The virtual
// sequences change it while the per-node sequences run (phases, oscillation...).
class hy_load_ctl extends uvm_object;
    hy_pattern_e pattern   = HY_PAT_UNIFORM;
    int unsigned load_pm   = 100;       // offered load, flits per node per cycle x 1000 (0 = idle)
    int          hot_node  = 5;
    int unsigned hot_pct   = 40;
    int          fixed_dst = -1;        // >= 0: every packet goes to this node
    int unsigned len_min   = 4;         // flits per packet (contract: 4)
    int unsigned len_max   = 4;
    bit          halt      = 0;         // 1: every node sequence ends after its current packet
    bit          active[HY_NODES];      // per-node switch (default all on)

    `uvm_object_utils(hy_load_ctl)

    function new(string name = "hy_load_ctl");
        super.new(name);
        foreach (active[i]) active[i] = 1;
    endfunction
endclass

// One node: packets according to the control object until `halt` (or n_pkts sent).
class hy_traffic_seq extends uvm_sequence #(hy_item);

    hy_load_ctl  ctl;
    int          my_node  = 0;
    int unsigned n_pkts   = 0;          // 0 = unlimited (until halt)
    int unsigned n_sent;

    `uvm_object_utils(hy_traffic_seq)

    function new(string name = "hy_traffic_seq");
        super.new(name);
    endfunction

    protected task pause(int unsigned cycles);
        req = hy_item::type_id::create("idle");
        start_item(req);
        req.idle_only = 1;
        req.gap = cycles;
        finish_item(req);
    endtask

    virtual task body();
        while (!ctl.halt && (n_pkts == 0 || n_sent < n_pkts)) begin
            int d;
            int unsigned g, len;
            if (!ctl.active[my_node] || ctl.load_pm == 0) begin pause(8); continue; end
            d = (ctl.fixed_dst >= 0) ? ctl.fixed_dst : hy_pick_dst(ctl.pattern, my_node, ctl.hot_node, ctl.hot_pct);
            if (d < 0) begin
                if (n_pkts != 0) break;               // silent node of a pattern that has to send a fixed number
                pause(16);
                continue;
            end
            len = (ctl.len_max > ctl.len_min) ? $urandom_range(ctl.len_max, ctl.len_min) : ctl.len_min;
            g   = hy_gap_for_load(ctl.load_pm, len);
            req = hy_item::type_id::create($sformatf("pkt_%0d", n_sent));
            start_item(req);
            if (!req.randomize() with { src == my_node[3:0]; dst == d[3:0]; gap == g; payload.size() == len - 1; })
                `uvm_fatal("RAND", "randomize failed")
            finish_item(req);
            n_sent++;
        end
    endtask

endclass
