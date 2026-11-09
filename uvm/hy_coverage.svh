// =============================================================================
// hy_coverage.svh : functional coverage of the HYSTERoC environment.
//   cg_ctrl   controller state, state steps (the full drain-and-switch sequence and
//             the SWITCH->DRAIN fallback), mode-change direction, congestion band
//             x active mode, requested x active mode
//   cg_net    network load: full FIFOs, non-empty routers, stalled sinks, each x mode,
//             and (controller not in RUN) x stalled sinks
//   cg_pkt    injected packets: source, destination, source x destination, distance,
//             length, distance x mode at injection
//   cg_hop    router decisions: output port x mode x router (boundary ports excluded),
//             number of legal outputs x mode x chosen port class
//   cg_cfg    sink backpressure modes and source bubbles actually used
// Packets come from the inject monitors, hops from the hop monitor (needs the
// link taps). Not every bin of every cross is reachable (e.g. XY mode has exactly
// one legal output); the coverage report of the simulator shows what is left.
// =============================================================================
`uvm_analysis_imp_decl(_cinj)
`uvm_analysis_imp_decl(_chop)

class hy_coverage extends uvm_component;

    hy_cfg        cfg;
    virtual hy_if vif;

    uvm_analysis_imp_cinj #(hy_item,   hy_coverage) inj_imp;
    uvm_analysis_imp_chop #(hy_hop_ev, hy_coverage) hop_imp;

    // ---- sampled values (members, so the covergroups need no arguments)
    protected int unsigned v_state, v_prev_state, v_step, v_mode, v_req, v_cong, v_dir;
    protected int unsigned v_nfull, v_nbusy, v_nstall;
    protected int unsigned v_src, v_dst, v_dist, v_len, v_pmode;
    protected int unsigned v_router, v_port, v_hmode, v_ncand, v_pclass;
    protected int unsigned v_sink_mode, v_bubble;

    // ---- shadow hit counters (named bins) so the end-of-test report can list the empty ones
    protected int unsigned hits[string];
    protected string       all_bins[$];

    protected function void reg_bins(string grp, string names[$]);
        foreach (names[i]) begin string k = {grp, ".", names[i]}; hits[k] = 0; all_bins.push_back(k); end
    endfunction
    protected function void hit(string grp, string nm);
        string k = {grp, ".", nm};
        if (hits.exists(k)) hits[k] = hits[k] + 1;
    endfunction
    protected function string step_name(int unsigned st);
        case (st)
            6'o01: return "run_to_quiesce";   6'o12: return "quiesce_to_wait";  6'o23: return "wait_to_drain";
            6'o34: return "drain_to_switch";  6'o45: return "switch_to_resume"; 6'o50: return "resume_to_run";
            6'o43: return "switch_to_drain";  6'o16, 6'o26, 6'o36: return "to_error";
            default: return "";
        endcase
    endfunction
    // NOTE: a ternary between string literals of different length is a padded bit vector, which broke the
    // shadow-counter keys for "xy"; always go through this function.
    protected function string mode_name(bit m);
        string r;
        if (m) r = "adapt"; else r = "xy";
        return r;
    endfunction
    protected function string cong_name(int unsigned c);
        if (c == 0) return "zero";  if (c < 96) return "low";  if (c < 160) return "dead_band";
        if (c < 255) return "high"; return "saturated";
    endfunction

    // ---- controller
    covergroup cg_ctrl;
        option.per_instance = 1;
        cp_state: coverpoint v_state { bins s[] = {[0:6]}; }
        cp_step: coverpoint v_step {
            bins run_to_quiesce    = {6'o01};
            bins quiesce_to_wait   = {6'o12};
            bins wait_to_drain     = {6'o23};
            bins drain_to_switch   = {6'o34};
            bins switch_to_resume  = {6'o45};
            bins resume_to_run     = {6'o50};
            ignore_bins switch_to_drain = {6'o43};     // defensive path: injection is blocked in SWITCH so quiescence cannot be lost at system level; covered in tb_transition_controller
            bins to_error          = {6'o16, 6'o26, 6'o36};
        }
        cp_mode: coverpoint v_mode { bins xy = {0}; bins adapt = {1}; }
        cp_req:  coverpoint v_req  { bins xy = {0}; bins adapt = {1}; }
        cp_cong: coverpoint v_cong {
            bins zero = {0}; bins low = {[1:95]}; bins dead_band = {[96:159]}; bins high = {[160:254]}; bins saturated = {255};
        }
        x_cong_mode: cross cp_cong, cp_mode;
        x_req_mode:  cross cp_req, cp_mode;
    endgroup

    covergroup cg_dir;
        option.per_instance = 1;
        cp_dir: coverpoint v_dir { bins to_adapt = {1}; bins to_xy = {0}; }
    endgroup

    // ---- network load
    covergroup cg_net;
        option.per_instance = 1;
        cp_full:  coverpoint v_nfull  { bins none = {0}; bins one = {1}; bins few = {[2:4]}; bins some = {[5:15]}; bins many = {[16:80]}; }
        cp_busy:  coverpoint v_nbusy  { bins idle = {0}; bins light = {[1:3]}; bins mid = {[4:8]}; bins heavy = {[9:16]}; }
        cp_stall: coverpoint v_nstall { bins none = {0}; bins one = {1}; bins few = {[2:4]}; bins many = {[5:16]}; }
        cp_mode:  coverpoint v_mode   { bins xy = {0}; bins adapt = {1}; }
        cp_state: coverpoint v_state  { bins run = {0}; bins transition = {[1:5]}; }
        x_full_mode:  cross cp_full,  cp_mode;
        x_busy_mode:  cross cp_busy,  cp_mode;
        x_stall_mode: cross cp_stall, cp_mode;
        x_state_stall: cross cp_state, cp_stall;
    endgroup

    // ---- packets
    covergroup cg_pkt;
        option.per_instance = 1;
        cp_src:  coverpoint v_src  { bins n[] = {[0:15]}; }
        cp_dst:  coverpoint v_dst  { bins n[] = {[0:15]}; }
        x_src_dst: cross cp_src, cp_dst {
            ignore_bins self0 = binsof(cp_src) intersect {0} && binsof(cp_dst) intersect {0};
            ignore_bins self1 = binsof(cp_src) intersect {1} && binsof(cp_dst) intersect {1};
            ignore_bins self2 = binsof(cp_src) intersect {2} && binsof(cp_dst) intersect {2};
            ignore_bins self3 = binsof(cp_src) intersect {3} && binsof(cp_dst) intersect {3};
            ignore_bins self4 = binsof(cp_src) intersect {4} && binsof(cp_dst) intersect {4};
            ignore_bins self5 = binsof(cp_src) intersect {5} && binsof(cp_dst) intersect {5};
            ignore_bins self6 = binsof(cp_src) intersect {6} && binsof(cp_dst) intersect {6};
            ignore_bins self7 = binsof(cp_src) intersect {7} && binsof(cp_dst) intersect {7};
            ignore_bins self8 = binsof(cp_src) intersect {8} && binsof(cp_dst) intersect {8};
            ignore_bins self9 = binsof(cp_src) intersect {9} && binsof(cp_dst) intersect {9};
            ignore_bins self10 = binsof(cp_src) intersect {10} && binsof(cp_dst) intersect {10};
            ignore_bins self11 = binsof(cp_src) intersect {11} && binsof(cp_dst) intersect {11};
            ignore_bins self12 = binsof(cp_src) intersect {12} && binsof(cp_dst) intersect {12};
            ignore_bins self13 = binsof(cp_src) intersect {13} && binsof(cp_dst) intersect {13};
            ignore_bins self14 = binsof(cp_src) intersect {14} && binsof(cp_dst) intersect {14};
            ignore_bins self15 = binsof(cp_src) intersect {15} && binsof(cp_dst) intersect {15};
        }
        cp_dist: coverpoint v_dist { bins d0 = {0}; bins d[] = {[1:6]}; }
        cp_len:  coverpoint v_len  { bins l2 = {2}; bins l3 = {3}; bins l4 = {4}; bins longer = {[5:16]}; }
        cp_pmode: coverpoint v_pmode { bins xy = {0}; bins adapt = {1}; }
        x_dist_mode: cross cp_dist, cp_pmode;
    endgroup

    // ---- router decisions
    covergroup cg_hop;
        option.per_instance = 1;
        cp_router: coverpoint v_router { bins r[] = {[0:15]}; }
        cp_port:   coverpoint v_port   { bins n = {0}; bins s = {1}; bins e = {2}; bins w = {3}; bins l = {4}; }
        cp_mode:   coverpoint v_hmode  { bins xy = {0}; bins adapt = {1}; }
        cp_ncand:  coverpoint v_ncand  { bins one = {1}; bins two = {2}; }
        cp_class:  coverpoint v_pclass { bins vertical = {0}; bins horizontal = {1}; bins loc = {2}; }
        x_port_mode: cross cp_port, cp_mode;
        x_router_port: cross cp_router, cp_port {
            ignore_bins no_north = binsof(cp_port.n) && binsof(cp_router) intersect {0, 1, 2, 3};
            ignore_bins no_south = binsof(cp_port.s) && binsof(cp_router) intersect {12, 13, 14, 15};
            ignore_bins no_west  = binsof(cp_port.w) && binsof(cp_router) intersect {0, 4, 8, 12};
            ignore_bins no_east  = binsof(cp_port.e) && binsof(cp_router) intersect {3, 7, 11, 15};
        }
        x_choice: cross cp_mode, cp_ncand, cp_class {
            ignore_bins xy_two  = binsof(cp_mode.xy) && binsof(cp_ncand.two);          // XY mode has exactly one legal output
            ignore_bins loc_two = binsof(cp_class.loc) && binsof(cp_ncand.two);        // Local ejection has exactly one output
        }
    endgroup

    // ---- configuration actually used
    covergroup cg_cfg;
        option.per_instance = 1;
        cp_sink: coverpoint v_sink_mode { bins always_rdy = {0}; bins random_ = {1}; bins bursty = {2}; bins never = {3}; }
        cp_bubble: coverpoint v_bubble { bins off = {0}; bins on = {1}; }
    endgroup

    `uvm_component_utils(hy_coverage)

    string cg_names[2]   = '{"xy","adapt"};
    string cong_names[5] = '{"zero","low","dead_band","high","saturated"};
    string full_names[5] = '{"none","one","few","some","many"};
    function new(string name, uvm_component parent);
        super.new(name, parent);
        inj_imp = new("inj_imp", this);
        hop_imp = new("hop_imp", this);
        cg_ctrl = new();
        cg_dir  = new();
        cg_net  = new();
        cg_pkt  = new();
        cg_hop  = new();
        cg_cfg  = new();
        reg_bins("step",  '{"run_to_quiesce","quiesce_to_wait","wait_to_drain","drain_to_switch","switch_to_resume","resume_to_run","to_error"});
        reg_bins("cong",  '{"zero","low","dead_band","high","saturated"});
        reg_bins("len",   '{"l2","l3","l4","longer"});
        reg_bins("dist",  '{"d0","d1","d2","d3","d4","d5","d6"});
        reg_bins("sink",  '{"always_rdy","random_","bursty","never"});
        reg_bins("bubble",'{"off","on"});
        reg_bins("nfull", '{"none","one","few","some","many"});
        reg_bins("nbusy", '{"idle","light","mid","heavy"});
        reg_bins("nstall",'{"none","one","few","many"});
        reg_bins("mode",  '{"xy","adapt"});
        foreach (cg_names[m]) begin
            string q[$];
            q = {}; foreach (cong_names[i]) q.push_back({cong_names[i], "_", cg_names[m]}); reg_bins("xcong", q);
            q = {}; foreach (full_names[i]) q.push_back({full_names[i], "_", cg_names[m]}); reg_bins("xfull", q);
            q = {}; for (int d = 0; d <= 6; d++) q.push_back($sformatf("d%0d_%s", d, cg_names[m])); reg_bins("xdist", q);
        end
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(hy_cfg)::get(this, "", "cfg", cfg)) `uvm_fatal("CFG", "hy_cfg not found")
        vif = cfg.vif;
        if (vif == null) `uvm_fatal("VIF", "cfg.vif is null")
    endfunction

    function void write_cinj(hy_item it);
        v_src = it.src; v_dst = it.dst; v_dist = hy_dist(it.src, it.dst); v_len = it.n_flits();
        v_pmode = vif.active_mode;
        cg_pkt.sample();
        hit("len", (v_len == 2) ? "l2" : (v_len == 3) ? "l3" : (v_len == 4) ? "l4" : "longer");
        hit("dist", $sformatf("d%0d", v_dist));
        begin
            string pm;
            pm = mode_name(v_pmode);     // string variable: a ternary of different-length literals is zero-padded and %s would print the padding
            hit("xdist", $sformatf("d%0d_%s", v_dist, pm));
        end
    endfunction

    function void write_chop(hy_hop_ev ev);
        v_router = ev.router; v_port = ev.port; v_hmode = ev.mode; v_ncand = ev.n_cand;
        v_pclass = (ev.port == HY_P_L) ? 2 : ((ev.port == HY_P_N || ev.port == HY_P_S) ? 0 : 1);
        cg_hop.sample();
    endfunction

    protected function void sample_cfg();
        for (int n = 0; n < HY_NODES; n++) begin
            v_sink_mode = int'(cfg.sink_mode[n]);
            v_bubble = (cfg.src_bubble_pct > 0 || cfg.flit_bubble_pct > 0);
            cg_cfg.sample();
            hit("sink", (v_sink_mode == 0) ? "always_rdy" : (v_sink_mode == 1) ? "random_" : (v_sink_mode == 2) ? "bursty" : "never");
            hit("bubble", v_bubble ? "on" : "off");
        end
    endfunction

    task run_phase(uvm_phase phase);
        bit prev_mode = 0;
        v_prev_state = 0;
        wait (vif.rst_n === 1'b1);
        sample_cfg();
        forever begin
            @(posedge vif.clk);
            if (vif.cyc[5:0] == 6'd0) sample_cfg();
            if (vif.rst_n !== 1'b1) begin v_prev_state = 0; prev_mode = vif.active_mode; continue; end
            v_state = vif.ctrl_state;
            v_step  = {v_prev_state[2:0], v_state[2:0]};
            v_mode  = vif.active_mode;
            v_req   = vif.req_mode;
            v_cong  = vif.global_congestion;
            if (v_step[5:3] != v_step[2:0]) begin cg_ctrl.sample(); hit("step", step_name(v_step)); end
            else begin v_step = 6'o77; cg_ctrl.sample(); end
            hit("cong", cong_name(v_cong));
            begin string ms; ms = v_mode ? "adapt" : "xy"; hit("xcong", {cong_name(v_cong), "_", ms}); end
            hit("mode", v_mode ? "adapt" : "xy");
            if (vif.active_mode !== prev_mode) begin v_dir = vif.active_mode; cg_dir.sample(); end
            prev_mode = vif.active_mode;
            // network load
            v_nfull = 0;
            for (int i = 0; i < 80; i++) if (vif.fifo_occ_all[3*i +: 3] == 3'd4) v_nfull++;
            v_nbusy = 0;
            for (int i = 0; i < 16; i++) if (!vif.router_empty[i]) v_nbusy++;
            v_nstall = 0;
            for (int i = 0; i < 16; i++) if (!vif.ej_ready[i]) v_nstall++;   // sinks refusing flits (ej_valid is only high when ej_ready is, so valid&&!ready never happens)
            cg_net.sample();
            hit("nfull",  (v_nfull == 0) ? "none" : (v_nfull == 1) ? "one" : (v_nfull <= 4) ? "few" : (v_nfull <= 15) ? "some" : "many");
            begin
                string ms, fn;
                ms = v_mode ? "adapt" : "xy";
                fn = (v_nfull == 0) ? "none" : (v_nfull == 1) ? "one" : (v_nfull <= 4) ? "few" : (v_nfull <= 15) ? "some" : "many";
                hit("xfull", {fn, "_", ms});
            end
            hit("nbusy",  (v_nbusy == 0) ? "idle" : (v_nbusy <= 3) ? "light" : (v_nbusy <= 8) ? "mid" : "heavy");
            hit("nstall", (v_nstall == 0) ? "none" : (v_nstall == 1) ? "one" : (v_nstall <= 4) ? "few" : "many");
            v_prev_state = v_state;
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("COV", $sformatf("ctrl %0.1f%%  net %0.1f%%  pkt %0.1f%%  hop %0.1f%%  cfg %0.1f%%  dir %0.1f%%",
                  cg_ctrl.get_inst_coverage(), cg_net.get_inst_coverage(), cg_pkt.get_inst_coverage(),
                  cg_hop.get_inst_coverage(), cg_cfg.get_inst_coverage(), cg_dir.get_inst_coverage()), UVM_LOW)
        // coverage holes of the named bins (hit counts of the shadow counters)
        begin
            string empty = "";
            int unsigned n_empty = 0;
            foreach (all_bins[i]) if (hits[all_bins[i]] == 0) begin empty = {empty, " ", all_bins[i]}; n_empty++; end
            if (n_empty == 0) `uvm_info("COV_HOLES", $sformatf("all %0d tracked bins were hit", all_bins.size()), UVM_LOW)
            else              `uvm_info("COV_HOLES", $sformatf("%0d of %0d tracked bins never hit:%s", n_empty, all_bins.size(), empty), UVM_LOW)
        end
        // per coverpoint / cross coverage of the groups that are not complete
        `uvm_info("COV_DETAIL", $sformatf("ctrl: state %0.0f step %0.0f mode %0.0f req %0.0f cong %0.0f x_cong_mode %0.0f x_req_mode %0.0f",
                  cg_ctrl.cp_state.get_inst_coverage(), cg_ctrl.cp_step.get_inst_coverage(), cg_ctrl.cp_mode.get_inst_coverage(),
                  cg_ctrl.cp_req.get_inst_coverage(), cg_ctrl.cp_cong.get_inst_coverage(),
                  cg_ctrl.x_cong_mode.get_inst_coverage(), cg_ctrl.x_req_mode.get_inst_coverage()), UVM_LOW)
        `uvm_info("COV_DETAIL", $sformatf("net:  full %0.0f busy %0.0f stall %0.0f x_full_mode %0.0f x_busy_mode %0.0f x_stall_mode %0.0f x_state_stall %0.0f",
                  cg_net.cp_full.get_inst_coverage(), cg_net.cp_busy.get_inst_coverage(), cg_net.cp_stall.get_inst_coverage(),
                  cg_net.x_full_mode.get_inst_coverage(), cg_net.x_busy_mode.get_inst_coverage(),
                  cg_net.x_stall_mode.get_inst_coverage(), cg_net.x_state_stall.get_inst_coverage()), UVM_LOW)
        `uvm_info("COV_DETAIL", $sformatf("pkt:  src %0.0f dst %0.0f x_src_dst %0.0f dist %0.0f len %0.0f x_dist_mode %0.0f",
                  cg_pkt.cp_src.get_inst_coverage(), cg_pkt.cp_dst.get_inst_coverage(), cg_pkt.x_src_dst.get_inst_coverage(),
                  cg_pkt.cp_dist.get_inst_coverage(), cg_pkt.cp_len.get_inst_coverage(), cg_pkt.x_dist_mode.get_inst_coverage()), UVM_LOW)
        `uvm_info("COV_DETAIL", $sformatf("hop:  router %0.0f port %0.0f x_port_mode %0.0f x_router_port %0.0f x_choice %0.0f",
                  cg_hop.cp_router.get_inst_coverage(), cg_hop.cp_port.get_inst_coverage(), cg_hop.x_port_mode.get_inst_coverage(),
                  cg_hop.x_router_port.get_inst_coverage(), cg_hop.x_choice.get_inst_coverage()), UVM_LOW)
    endfunction

endclass
