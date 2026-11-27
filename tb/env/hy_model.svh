// =============================================================================
// hy_model.svh : cycle-accurate REFERENCE MODEL + protocol checks for the control
// part of noc_top. PURE SystemVerilog (no UVM), so it can be unit tested against
// the RTL in a plain simulator. hy_protocol_checker (hy_protocol_checker.svh) is a
// thin UVM wrapper that feeds it one observation per clock edge.
//
// One call of step() = one clock edge. The observation holds what the DUT shows
// BEFORE that edge (= what its flip-flops sample). step() first COMPARES the
// model's expected values with the observation, then ADVANCES the model.
//
// Models (written from the specification, not copied from the RTL structure)
//   M1  per router: registered neighbour-occupancy sideband (one cycle old),
//       congestion = map(max occupancy of the available directions),
//       EWMA S' = S - (S>>3) + C, E = S>>3, frozen outside RUN, sample period
//   M2  global maxima of the 16 EWMA values and of the 16 raw values
//   M3  hysteresis: dual threshold (>= THIGH up, <= TLOW down) or single, EWMA or
//       raw, held outside RUN, forced 0 for XY_ONLY
//   M4  transition FSM RUN/QUIESCE/WAIT/DRAIN/SWITCH/RESUME/ERROR with the
//       watchdog (cycle LIMIT counted from the first inject_block_req cycle)
//   M5  drain detector: router_empty & src_empty & no link activity, CONFIRM cycles
//   M6  statistics counters (cycle_cnt, tot_blocked, tot_ackwait, tot_drain, transitions)
// Independent invariants
//   I1  network_drained => no flit inside (accepted - delivered == 0) and all routers empty
//   I2  active_mode changes only from SWITCH with network_drained, with nothing in flight
//   I3  no source injects in DRAIN / SWITCH
//   I4  proto_err_any / alloc_err_any are never set
//   I5  ERROR (watchdog) never happens unless the test expects it
//   I6  XY_ONLY: mode 0, RUN, no transitions
// =============================================================================
typedef struct {
    logic [239:0] fifo_occ_all;
    logic [127:0] ewma_all;
    logic [7:0]   global_congestion, global_raw;
    logic         req_mode, active_mode;
    logic [2:0]   ctrl_state;
    logic         inject_block_req;
    logic [15:0]  inject_block_ack, src_empty, router_empty;
    logic         network_drained, drain_timeout, transition_busy, proto_err_any, alloc_err_any;
    logic [15:0]  inj_valid, inj_ready, ej_valid, ej_ready;
    logic [15:0]  link_active;           // valid only when has_links
    bit           has_links;
    logic [31:0]  cycle_cnt, tot_blocked, tot_ackwait, tot_drain, transitions;
} hy_obs_t;

class hy_model;
    // ---- configuration (mirror of the DUT parameters)
    bit          xy_only       = 0;
    bit          dual          = 1;
    bit          use_ewma      = 1;
    int          thigh         = 160;
    int          tlow          = 96;
    int          thresh_single = 128;
    int          sample_period = 1;
    int          wd_limit      = 1000;
    int          mask_cycles   = 0;
    int          confirm       = 2;
    bit          enable_stats  = 1;
    bit          switch_policy = 0;      // 1: no-drain policy (SWITCH_POLICY=1): active_mode follows req_mode one cycle later
    bit          expect_timeout = 0;
    bit          chk_models    = 1;      // M1..M6 comparisons
    bit          chk_invariants = 1;     // I1..I6

    // ---- model state
    int          S[16];                  // EWMA state (11 bit)
    int          Q[16][4];               // registered neighbour occupancy N,S,E,W
    int          cnt;                    // sample-period counter
    bit          req_m;
    int          st_m;                   // 0 RUN 1 QUIESCE 2 WAIT 3 DRAIN 4 SWITCH 5 RESUME 6 ERROR
    bit          target_m, active_m;
    int          wd_m, mask_m;
    int          quiet_m;
    longint      cyc_m, tot_blocked_m, tot_ackwait_m, tot_drain_m, trans_m;
    int          inflight;
    bit          prev_active, have_prev;
    int          prev_st;
    bit          prev_drained;
    int          prev_inflight;
    bit          err_seen;

    // ---- results
    string       errors[$];
    int unsigned n_errors, n_cycles, n_mode_changes, n_error_state_cycles;
    int unsigned n_chg_inflight;            // no-drain: mode changes that happened with flits inside the network
    int unsigned n_hi_eq, n_lo_eq;          // boundary coverage: value == THIGH while requesting up, value == TLOW while requesting down
    int          cat_cnt[string];

    function void err(string cat, string msg);
        n_errors++;
        if (!cat_cnt.exists(cat)) cat_cnt[cat] = 0;
        cat_cnt[cat] = cat_cnt[cat] + 1;
        if (cat_cnt[cat] <= 5) errors.push_back($sformatf("[%s] cycle %0d: %s", cat, n_cycles, msg));
    endfunction

    function void reset();
        foreach (S[i]) begin S[i] = 0; for (int d = 0; d < 4; d++) Q[i][d] = 0; end
        cnt = 0; req_m = 0; st_m = 0; target_m = 0; active_m = 0; wd_m = 0; mask_m = 0; quiet_m = 0;
        cyc_m = 0; tot_blocked_m = 0; tot_ackwait_m = 0; tot_drain_m = 0; trans_m = 0;
        inflight = 0; err_seen = 0; have_prev = 0; prev_st = 0; prev_active = 0; prev_drained = 0; prev_inflight = 0;
    endfunction

    function new();
        reset();
    endfunction

    // ------------------------------------------------------------ helpers
    static function int map_occ(int o);
        case (o)
            0: return 0;
            1: return 64;
            2: return 128;
            3: return 192;
            default: return 255;
        endcase
    endfunction

    // neighbour occupancy seen by router n in direction d (0 N, 1 S, 2 E, 3 W); -1 at the boundary
    static function int nbr_occ(logic [239:0] occ, int n, int d);
        int x = hy_x(n), y = hy_y(n), b, port;
        case (d)
            0: begin if (y == 0)          return -1; b = n - HY_DIM; port = 1; end   // north neighbour, its S input
            1: begin if (y == HY_DIM - 1) return -1; b = n + HY_DIM; port = 0; end   // south neighbour, its N input
            2: begin if (x == HY_DIM - 1) return -1; b = n + 1;      port = 3; end   // east neighbour, its W input
            default: begin if (x == 0)    return -1; b = n - 1;      port = 2; end   // west neighbour, its E input
        endcase
        return int'(occ[15*b + 3*port +: 3]);
    endfunction

    function int cong_of(int n);
        int m = 0, o;
        for (int d = 0; d < 4; d++) begin
            if (nbr_occ(240'h0, n, d) == -1) continue;      // boundary: not available (position only)
            o = Q[n][d];
            if (o > 4) o = 4;
            if (o > m) m = o;
        end
        return map_occ(m);
    endfunction

    function bit blk_of(int st);
        return (st == 1 || st == 2 || st == 3 || st == 4 || st == 6);
    endfunction

    function int popc(logic [15:0] v);
        int c = 0;
        for (int i = 0; i < 16; i++) if (v[i] === 1'b1) c++;
        return c;
    endfunction

    // ------------------------------------------------------------ one clock edge
    function void step(hy_obs_t o);
        int c[16];
        int exp_raw = 0, exp_glob = 0, e, value;
        bit exp_req, exp_blk, drained_now, exp_drained, enable_run, tick, all_ack, wd_last, wd_over, next_req;
        int next_st, acc_i, acc_e;

        n_cycles++;
        for (int n = 0; n < 16; n++) begin
            c[n] = cong_of(n);
            e = S[n] >> 3;
            if (c[n] > exp_raw) exp_raw = c[n];
            if (e > exp_glob) exp_glob = e;
            if (chk_models && o.ewma_all[8*n +: 8] !== 8'(e))
                err("M1 ewma", $sformatf("router %0d EWMA %0d expected %0d", n, o.ewma_all[8*n +: 8], e));
        end
        if (chk_models) begin
            if (o.global_raw        !== 8'(exp_raw))  err("M2 global", $sformatf("global_raw %0d expected %0d", o.global_raw, exp_raw));
            if (o.global_congestion !== 8'(exp_glob)) err("M2 global", $sformatf("global_congestion %0d expected %0d", o.global_congestion, exp_glob));
        end

        // ---------------- hysteresis M3
        exp_req = xy_only ? 1'b0 : req_m;
        if (chk_models && o.req_mode !== exp_req) err("M3 hysteresis", $sformatf("req_mode %0b expected %0b", o.req_mode, exp_req));
        value = use_ewma ? int'(o.global_congestion) : int'(o.global_raw);

        // ---------------- FSM M4 compare
        exp_blk = blk_of(st_m);
        if (chk_models && switch_policy) begin
            // no-drain controller: always RUN, never blocks, active_mode = req_mode of the previous cycle
            if (o.ctrl_state !== 3'd0)         err("N1 nodrain", $sformatf("ctrl_state %0d, must stay RUN(0)", o.ctrl_state));
            if (o.active_mode !== active_m)    err("N1 nodrain", $sformatf("active_mode %0b expected %0b (= req_mode one cycle earlier)", o.active_mode, active_m));
            if (o.inject_block_req !== 1'b0)   err("N1 nodrain", "inject_block_req asserted");
            if (o.transition_busy !== 1'b0)    err("N1 nodrain", "transition_busy asserted");
            if (o.drain_timeout !== 1'b0)      err("N1 nodrain", "drain_timeout asserted");
        end else if (chk_models) begin
            if (o.ctrl_state !== 3'(st_m))        err("M4 fsm", $sformatf("ctrl_state %0d expected %0d", o.ctrl_state, st_m));
            if (o.active_mode !== active_m)       err("M4 fsm", $sformatf("active_mode %0b expected %0b", o.active_mode, active_m));
            if (o.inject_block_req !== exp_blk)   err("M4 fsm", $sformatf("inject_block_req %0b expected %0b (state %0d)", o.inject_block_req, exp_blk, st_m));
            if (o.transition_busy !== (st_m != 0))err("M4 fsm", $sformatf("transition_busy %0b in state %0d", o.transition_busy, st_m));
            if (o.drain_timeout !== (st_m == 6))  err("M4 fsm", $sformatf("drain_timeout %0b in state %0d", o.drain_timeout, st_m));
        end

        // ---------------- drain detector M5
        drained_now = (&o.router_empty) & (&o.src_empty);
        if (o.has_links) drained_now = drained_now & ~(|o.link_active);
        exp_drained = drained_now & (quiet_m >= confirm - 1);
        if (chk_models && o.has_links && o.network_drained !== exp_drained)
            err("M5 drain", $sformatf("network_drained %0b expected %0b (quiet %0d)", o.network_drained, exp_drained, quiet_m));

        // ---------------- statistics M6
        if (chk_models && enable_stats) begin
            if (o.cycle_cnt   !== 32'(cyc_m))          err("M6 stats", $sformatf("cycle_cnt %0d expected %0d", o.cycle_cnt, cyc_m));
            if (o.tot_blocked !== 32'(tot_blocked_m))  err("M6 stats", $sformatf("tot_blocked %0d expected %0d", o.tot_blocked, tot_blocked_m));
            if (o.tot_ackwait !== 32'(tot_ackwait_m))  err("M6 stats", $sformatf("tot_ackwait %0d expected %0d", o.tot_ackwait, tot_ackwait_m));
            if (o.tot_drain   !== 32'(tot_drain_m))    err("M6 stats", $sformatf("tot_drain %0d expected %0d", o.tot_drain, tot_drain_m));
            if (o.transitions !== 32'(trans_m))        err("M6 stats", $sformatf("transitions %0d expected %0d", o.transitions, trans_m));
        end

        // ---------------- invariants
        if (chk_invariants) begin
            if (o.network_drained === 1'b1 && inflight != 0) err("I1 drained", $sformatf("network_drained with %0d flits inside the network", inflight));
            if (o.network_drained === 1'b1 && !(&o.router_empty)) err("I1 drained", "network_drained but a router is not empty");
            if (have_prev && o.active_mode !== prev_active) begin
                n_mode_changes++;
                if (switch_policy) begin
                    if (inflight != 0) n_chg_inflight++;       // allowed (that is the point of the policy), only counted
                end else begin
                    if (prev_st != 4)     err("I2 mode change", $sformatf("mode changed after state %0d (must be SWITCH)", prev_st));
                    if (!prev_drained)    err("I2 mode change", "mode changed without network_drained in the SWITCH cycle");
                    if (inflight != 0)    err("I2 mode change", $sformatf("mode changed with %0d flits in flight", inflight));
                end
            end
            if (!switch_policy && (o.ctrl_state === 3'd3 || o.ctrl_state === 3'd4) && (|o.inj_valid))
                err("I3 inject", $sformatf("source injecting (inj_valid=%04h) in state %0d", o.inj_valid, o.ctrl_state));
            if (o.proto_err_any === 1'b1) err("I4 router", "proto_err_any set (illegal flit sequence seen inside a router)");
            if (o.alloc_err_any === 1'b1) err("I4 router", "alloc_err_any set (allocator inconsistency)");
            if (!switch_policy && o.ctrl_state === 3'd6) begin
                n_error_state_cycles++;
                if (!expect_timeout && !err_seen) err("I5 watchdog", "watchdog ERROR state reached");
                err_seen = 1;
            end
            if (xy_only && (o.active_mode !== 1'b0 || o.ctrl_state !== 3'd0 || o.transitions !== 32'd0))
                err("I6 xy-only", "XY_ONLY network left the RUN state or changed mode");
        end

        // ======================= advance the model (registers update at this edge)
        acc_i = popc(o.inj_valid & o.inj_ready);
        acc_e = popc(o.ej_valid & o.ej_ready);
        enable_run = (st_m == 0);
        tick = (sample_period <= 1) ? 1'b1 : (cnt == sample_period - 1);
        // M1 EWMA and sideband registers
        for (int n = 0; n < 16; n++) begin
            if (enable_run && tick) S[n] = (S[n] - (S[n] >> 3) + c[n]) & 11'h7FF;
            for (int d = 0; d < 4; d++) begin
                int v = nbr_occ(o.fifo_occ_all, n, d);
                Q[n][d] = (v < 0) ? 0 : v;
            end
        end
        if (sample_period > 1 && enable_run) cnt = tick ? 0 : cnt + 1;
        // M3 hysteresis
        next_req = req_m;
        if (dual) begin
            if (!req_m) begin if (value >= thigh) next_req = 1'b1; end
            else        begin if (value <= tlow)  next_req = 1'b0; end
        end else next_req = (value >= thresh_single);
        if (enable_run && dual && !req_m && value == thigh) n_hi_eq++;
        if (enable_run && dual &&  req_m && value == tlow)  n_lo_eq++;
        if (enable_run) req_m = next_req;
        // M5 quiet counter
        if (!drained_now)            quiet_m = 0;
        else if (quiet_m < confirm)  quiet_m = quiet_m + 1;
        // M6 statistics (count the cycle being spent in the state)
        if (blk_of(st_m))                  tot_blocked_m++;
        if (st_m == 1 || st_m == 2)        tot_ackwait_m++;
        if (st_m == 3)                     tot_drain_m++;
        cyc_m++;
        // M4 FSM
        all_ack = (&o.inject_block_ack);
        wd_last = (wd_m >= wd_limit - 1);
        wd_over = (wd_m >= wd_limit);
        next_st = st_m;
        if (switch_policy) begin
            if (o.req_mode !== o.active_mode) trans_m++;      // transitions counts every active_mode change
            active_m = o.req_mode;
        end else begin
        if (blk_of(st_m) && st_m != 6) wd_m = wd_m + 1;
        case (st_m)
            0: begin
                wd_m = 0;
                if (o.req_mode !== active_m) begin target_m = o.req_mode; next_st = 1; end
            end
            1: next_st = wd_last ? 6 : 2;
            2: begin if (wd_last) next_st = 6; else if (all_ack) next_st = 3; end
            3: begin if (o.network_drained === 1'b1 && !wd_over) next_st = 4; else if (wd_last) next_st = 6; end
            4: begin
                if (o.network_drained === 1'b1) begin
                    active_m = target_m; trans_m++; mask_m = mask_cycles; next_st = 5;
                end else next_st = 3;
            end
            5: begin if (mask_m == 0) next_st = 0; else mask_m = mask_m - 1; end
            6: next_st = 6;
            default: next_st = 6;
        endcase
        end
        // bookkeeping for the invariants of the NEXT cycle
        prev_st = st_m; prev_active = o.active_mode; prev_drained = (o.network_drained === 1'b1); have_prev = 1;
        st_m = next_st;
        inflight = inflight + acc_i - acc_e;
    endfunction
endclass
