// =============================================================================
// tb_performance_monitor.v : self-checking testbench for performance_monitor
//
// Two monitor instances (default parameters PP 50/100/200/400, STALL_LIMIT
// 2000, and small parameters PP 3/7/20/40, STALL_LIMIT 30) get the SAME random
// stimulus. Every cycle the stimulus is recorded in a trace; after the run an
// independent model scans the trace (not a copy of the RTL structure) and
// every output is compared.
//   * scenarios: window position/length variants (window at the start, in the
//     middle, window longer than the run, zero length, warm-up beyond the run),
//     switch gaps around the T_PP boundaries (<=, =, +1), blocked periods with
//     and without a mode change, a blocked period still open at the end,
//     packet latencies up to 65535, 16 simultaneous packets, long stalls.
//   * checks: now, window flags, switches (direction), request toggles, block
//     starts, ping-pong x4, dwell sum/count/min/max, blocked cycles, blocked
//     periods (count/sum/min/max/open length), packets, latency sums, sums of
//     squares and maxima, flits, totals, in-flight, stall counters and flag.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps

module tb_performance_monitor;
    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg  [31:0] warmup, measure;
    reg         active_mode, req_mode, blk;
    reg  [15:0] inj_x, ej_x, pk;
    reg  [255:0] lt, ln;

    // ---------------- DUT A (defaults) ----------------
    wire [31:0] a_now; wire a_en, a_done; wire [31:0] a_mc;
    wire [31:0] a_swt, a_sw, a_ta, a_tx, a_rt, a_bs, a_p0, a_p1, a_p2, a_p3, a_dc; wire [47:0] a_ds;
    wire [31:0] a_dmin, a_dmax, a_adc, a_wb, a_drc; wire [47:0] a_drs; wire [31:0] a_drmin, a_drmax, a_bln;
    wire [31:0] a_wp; wire [47:0] a_lts; wire [63:0] a_ltq; wire [15:0] a_ltm; wire [47:0] a_lns; wire [63:0] a_lnq; wire [15:0] a_lnm;
    wire [31:0] a_wi, a_we, a_pt, a_it, a_et, a_infl, a_sc, a_sm; wire a_sf;

    performance_monitor dutA (
        .clk(clk), .rst_n(rst_n), .warmup(warmup), .measure(measure),
        .active_mode(active_mode), .req_mode(req_mode), .inject_block_req(blk),
        .inj_xfer(inj_x), .ej_xfer(ej_x), .pkt_done(pk), .lat_total(lt), .lat_net(ln),
        .now(a_now), .meas_en(a_en), .meas_done(a_done), .meas_cycles(a_mc),
        .sw_total(a_swt), .w_switches(a_sw), .w_to_adapt(a_ta), .w_to_xy(a_tx),
        .w_req_toggles(a_rt), .w_blk_starts(a_bs),
        .w_pp0(a_p0), .w_pp1(a_p1), .w_pp2(a_p2), .w_pp3(a_p3),
        .w_dwell_cnt(a_dc), .w_dwell_sum(a_ds), .w_dwell_min(a_dmin), .w_dwell_max(a_dmax),
        .w_adapt_cycles(a_adc), .w_blocked(a_wb),
        .drain_cnt(a_drc), .drain_sum(a_drs), .drain_min(a_drmin), .drain_max(a_drmax), .blk_len_now(a_bln),
        .w_pkts(a_wp), .w_lat_total_sum(a_lts), .w_lat_total_sq(a_ltq), .w_lat_total_max(a_ltm),
        .w_lat_net_sum(a_lns), .w_lat_net_sq(a_lnq), .w_lat_net_max(a_lnm),
        .w_inj_flits(a_wi), .w_ej_flits(a_we), .pkts_total(a_pt), .inj_flits_total(a_it),
        .ej_flits_total(a_et), .inflight(a_infl),
        .stall_cnt(a_sc), .stall_max(a_sm), .stall_flag(a_sf));

    // ---------------- DUT B (small parameters) ----------------
    wire [31:0] b_now; wire b_en, b_done; wire [31:0] b_mc;
    wire [31:0] b_swt, b_sw, b_ta, b_tx, b_rt, b_bs, b_p0, b_p1, b_p2, b_p3, b_dc; wire [47:0] b_ds;
    wire [31:0] b_dmin, b_dmax, b_adc, b_wb, b_drc; wire [47:0] b_drs; wire [31:0] b_drmin, b_drmax, b_bln;
    wire [31:0] b_wp; wire [47:0] b_lts; wire [63:0] b_ltq; wire [15:0] b_ltm; wire [47:0] b_lns; wire [63:0] b_lnq; wire [15:0] b_lnm;
    wire [31:0] b_wi, b_we, b_pt, b_it, b_et, b_infl, b_sc, b_sm; wire b_sf;

    performance_monitor #(.PP0(3), .PP1(7), .PP2(20), .PP3(40), .STALL_LIMIT(30)) dutB (
        .clk(clk), .rst_n(rst_n), .warmup(warmup), .measure(measure),
        .active_mode(active_mode), .req_mode(req_mode), .inject_block_req(blk),
        .inj_xfer(inj_x), .ej_xfer(ej_x), .pkt_done(pk), .lat_total(lt), .lat_net(ln),
        .now(b_now), .meas_en(b_en), .meas_done(b_done), .meas_cycles(b_mc),
        .sw_total(b_swt), .w_switches(b_sw), .w_to_adapt(b_ta), .w_to_xy(b_tx),
        .w_req_toggles(b_rt), .w_blk_starts(b_bs),
        .w_pp0(b_p0), .w_pp1(b_p1), .w_pp2(b_p2), .w_pp3(b_p3),
        .w_dwell_cnt(b_dc), .w_dwell_sum(b_ds), .w_dwell_min(b_dmin), .w_dwell_max(b_dmax),
        .w_adapt_cycles(b_adc), .w_blocked(b_wb),
        .drain_cnt(b_drc), .drain_sum(b_drs), .drain_min(b_drmin), .drain_max(b_drmax), .blk_len_now(b_bln),
        .w_pkts(b_wp), .w_lat_total_sum(b_lts), .w_lat_total_sq(b_ltq), .w_lat_total_max(b_ltm),
        .w_lat_net_sum(b_lns), .w_lat_net_sq(b_lnq), .w_lat_net_max(b_lnm),
        .w_inj_flits(b_wi), .w_ej_flits(b_we), .pkts_total(b_pt), .inj_flits_total(b_it),
        .ej_flits_total(b_et), .inflight(b_infl),
        .stall_cnt(b_sc), .stall_max(b_sm), .stall_flag(b_sf));

    // ---------------- trace ----------------
    localparam NMAX = 12000;
    reg        t_mode [0:NMAX-1];
    reg        t_req  [0:NMAX-1];
    reg        t_blk  [0:NMAX-1];
    reg [4:0]  t_inj  [0:NMAX-1];
    reg [4:0]  t_ej   [0:NMAX-1];
    reg [4:0]  t_pk   [0:NMAX-1];
    reg [31:0] t_s_tot [0:NMAX-1];
    reg [31:0] t_s_net [0:NMAX-1];
    reg [63:0] t_q_tot [0:NMAX-1];
    reg [63:0] t_q_net [0:NMAX-1];
    reg [15:0] t_m_tot [0:NMAX-1];
    reg [15:0] t_m_net [0:NMAX-1];

    integer errors, seed, scen;
    integer N, sweep;

    task chk;
        input [8*24-1:0] nm;
        input [63:0] got;
        input [63:0] exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                if (errors < 40) $display("ERROR scen %0d %0s: got %0d expected %0d", scen, nm, got, exp);
            end
        end
    endtask

    // popcount helper
    function [4:0] pc16;
        input [15:0] v;
        integer k;
        begin pc16 = 0; for (k = 0; k < 16; k = k + 1) pc16 = pc16 + v[k]; end
    endfunction

    // ---------------- model results ----------------
    // (one set per T_PP parameter set: index 0 = DUT A, 1 = DUT B)
    integer W, M;
    integer m_sw, m_ta, m_tx, m_rt, m_bs, m_dc, m_wb, m_adc, m_wpk, m_wi, m_we, m_swt;
    integer m_pp [0:3];
    integer m_dsum, m_dmin, m_dmax;
    integer m_drc, m_drs, m_drmin, m_drmax, m_bln;
    reg [63:0] m_lts, m_ltq, m_lns, m_lnq;
    reg [15:0] m_ltm, m_lnm;
    integer m_pt, m_it, m_et, m_infl;
    integer m_sc, m_smax;
    reg m_sf;
    reg m_done;
    integer m_mc;

    integer pp_val [0:7];

    task model;
        input integer which;            // 0 = A, 1 = B
        integer t, u, last, gap, s, run, cum_i, cum_e, stl, lim;
        reg meas, prevm, lastvalid;
        begin
            m_sw = 0; m_ta = 0; m_tx = 0; m_rt = 0; m_bs = 0; m_dc = 0; m_wb = 0; m_adc = 0;
            m_wpk = 0; m_wi = 0; m_we = 0; m_swt = 0;
            for (u = 0; u < 4; u = u + 1) m_pp[u] = 0;
            m_dsum = 0; m_dmin = -1; m_dmax = 0;
            m_drc = 0; m_drs = 0; m_drmin = -1; m_drmax = 0; m_bln = 0;
            m_lts = 0; m_ltq = 0; m_lns = 0; m_lnq = 0; m_ltm = 0; m_lnm = 0;
            m_pt = 0; m_it = 0; m_et = 0; m_infl = 0;
            m_sc = 0; m_smax = 0; m_sf = 0; m_mc = 0;
            lim = which ? 30 : 2000;
            last = -1; prevm = 0;
            run = 0; s = 0;
            cum_i = 0; cum_e = 0; stl = 0;
            for (t = 0; t < N; t = t + 1) begin
                meas = (t >= W) && (t < W + M);
                if (meas) m_mc = m_mc + 1;
                // switches
                if (t_mode[t] != prevm) begin
                    m_swt = m_swt + 1;
                    if (meas) begin
                        m_sw = m_sw + 1;
                        if (t_mode[t]) m_ta = m_ta + 1; else m_tx = m_tx + 1;
                        if (last >= 0) begin
                            if ((last >= W) && (last < W + M)) begin
                                gap = t - last;
                                m_dc = m_dc + 1; m_dsum = m_dsum + gap;
                                if (m_dmin < 0 || gap < m_dmin) m_dmin = gap;
                                if (gap > m_dmax) m_dmax = gap;
                                for (u = 0; u < 4; u = u + 1)
                                    if (gap <= pp_val[which*4 + u]) m_pp[u] = m_pp[u] + 1;
                            end
                        end
                    end
                    last = t;
                end
                prevm = t_mode[t];
                // requests
                if (meas) begin
                    if (t_req[t] != ((t == 0) ? 1'b0 : t_req[t-1])) m_rt = m_rt + 1;
                    if (t_blk[t] && !((t == 0) ? 1'b0 : t_blk[t-1])) m_bs = m_bs + 1;
                    if (t_blk[t]) m_wb = m_wb + 1;
                    if (t_mode[t]) m_adc = m_adc + 1;
                    m_wi = m_wi + t_inj[t];
                    m_we = m_we + t_ej[t];
                    m_wpk = m_wpk + t_pk[t];
                    m_lts = m_lts + t_s_tot[t]; m_lns = m_lns + t_s_net[t];
                    m_ltq = m_ltq + t_q_tot[t]; m_lnq = m_lnq + t_q_net[t];
                    if (t_m_tot[t] > m_ltm) m_ltm = t_m_tot[t];
                    if (t_m_net[t] > m_lnm) m_lnm = t_m_net[t];
                end
                m_pt = m_pt + t_pk[t];
                // stall (in-flight counted BEFORE this cycle)
                if ((cum_i - cum_e) != 0 && t_ej[t] == 0) begin
                    stl = stl + 1;
                    if (stl > m_smax) m_smax = stl;
                    if (stl >= lim) m_sf = 1;
                end else stl = 0;
                cum_i = cum_i + t_inj[t];
                cum_e = cum_e + t_ej[t];
            end
            m_it = cum_i; m_et = cum_e; m_infl = cum_i - cum_e; m_sc = stl;
            // blocked periods: maximal runs of blk=1 that end inside the trace
            t = 0;
            while (t < N) begin
                if (t_blk[t]) begin
                    s = t;
                    while (t < N && t_blk[t]) t = t + 1;
                    if (t < N) begin                      // ended inside the trace
                        if ((s >= W) && (s < W + M)) begin
                            m_drc = m_drc + 1; m_drs = m_drs + (t - s);
                            if (m_drmin < 0 || (t - s) < m_drmin) m_drmin = t - s;
                            if ((t - s) > m_drmax) m_drmax = t - s;
                        end
                        m_bln = 0;
                    end else m_bln = t - s;               // still open
                end else t = t + 1;
            end
            m_done = (M > 0) && (N >= W + M);
        end
    endtask

    task compare;
        input integer which;
        begin
            model(which);
            if (which == 0) begin
                chk("now", a_now, N);
                chk("meas_cycles", a_mc, m_mc);
                chk("meas_done", a_done, m_done);
                chk("sw_total", a_swt, m_swt);
                chk("w_switches", a_sw, m_sw); chk("w_to_adapt", a_ta, m_ta); chk("w_to_xy", a_tx, m_tx);
                chk("w_req_toggles", a_rt, m_rt); chk("w_blk_starts", a_bs, m_bs);
                chk("pp0", a_p0, m_pp[0]); chk("pp1", a_p1, m_pp[1]); chk("pp2", a_p2, m_pp[2]); chk("pp3", a_p3, m_pp[3]);
                chk("dwell_cnt", a_dc, m_dc); chk("dwell_sum", a_ds, m_dsum);
                chk("dwell_min", a_dmin, (m_dmin < 0) ? 32'hFFFFFFFF : m_dmin); chk("dwell_max", a_dmax, m_dmax);
                chk("adapt_cycles", a_adc, m_adc); chk("w_blocked", a_wb, m_wb);
                chk("drain_cnt", a_drc, m_drc); chk("drain_sum", a_drs, m_drs);
                chk("drain_min", a_drmin, (m_drmin < 0) ? 32'hFFFFFFFF : m_drmin); chk("drain_max", a_drmax, m_drmax);
                chk("blk_len_now", a_bln, m_bln);
                chk("w_pkts", a_wp, m_wpk); chk("lat_total_sum", a_lts, m_lts); chk("lat_total_sq", a_ltq, m_ltq);
                chk("lat_total_max", a_ltm, m_ltm); chk("lat_net_sum", a_lns, m_lns); chk("lat_net_sq", a_lnq, m_lnq);
                chk("lat_net_max", a_lnm, m_lnm);
                chk("w_inj_flits", a_wi, m_wi); chk("w_ej_flits", a_we, m_we);
                chk("pkts_total", a_pt, m_pt); chk("inj_total", a_it, m_it); chk("ej_total", a_et, m_et);
                chk("inflight", a_infl, m_infl[31:0]);
                chk("stall_cnt", a_sc, m_sc); chk("stall_max", a_sm, m_smax); chk("stall_flag", a_sf, m_sf);
            end else begin
                chk("B now", b_now, N);
                chk("B meas_cycles", b_mc, m_mc);
                chk("B meas_done", b_done, m_done);
                chk("B sw_total", b_swt, m_swt);
                chk("B w_switches", b_sw, m_sw); chk("B w_to_adapt", b_ta, m_ta); chk("B w_to_xy", b_tx, m_tx);
                chk("B w_req_toggles", b_rt, m_rt); chk("B w_blk_starts", b_bs, m_bs);
                chk("B pp0", b_p0, m_pp[0]); chk("B pp1", b_p1, m_pp[1]); chk("B pp2", b_p2, m_pp[2]); chk("B pp3", b_p3, m_pp[3]);
                chk("B dwell_cnt", b_dc, m_dc); chk("B dwell_sum", b_ds, m_dsum);
                chk("B dwell_min", b_dmin, (m_dmin < 0) ? 32'hFFFFFFFF : m_dmin); chk("B dwell_max", b_dmax, m_dmax);
                chk("B adapt_cycles", b_adc, m_adc); chk("B w_blocked", b_wb, m_wb);
                chk("B drain_cnt", b_drc, m_drc); chk("B drain_sum", b_drs, m_drs);
                chk("B drain_min", b_drmin, (m_drmin < 0) ? 32'hFFFFFFFF : m_drmin); chk("B drain_max", b_drmax, m_drmax);
                chk("B blk_len_now", b_bln, m_bln);
                chk("B w_pkts", b_wp, m_wpk); chk("B lat_total_sum", b_lts, m_lts); chk("B lat_total_sq", b_ltq, m_ltq);
                chk("B lat_total_max", b_ltm, m_ltm); chk("B lat_net_sum", b_lns, m_lns); chk("B lat_net_sq", b_lnq, m_lnq);
                chk("B lat_net_max", b_lnm, m_lnm);
                chk("B w_inj_flits", b_wi, m_wi); chk("B w_ej_flits", b_we, m_we);
                chk("B pkts_total", b_pt, m_pt); chk("B inj_total", b_it, m_it); chk("B ej_total", b_et, m_et);
                chk("B inflight", b_infl, m_infl[31:0]);
                chk("B stall_cnt", b_sc, m_sc); chk("B stall_max", b_sm, m_smax); chk("B stall_flag", b_sf, m_sf);
            end
        end
    endtask

    // ---------------- stimulus ----------------
    reg [31:0] rnd;
    function [31:0] xs;
        input [31:0] x;
        reg [31:0] y;
        begin y = x; y = y ^ (y << 13); y = y ^ (y >> 17); y = y ^ (y << 5); xs = y; end
    endfunction

    integer next_sw, next_blk_start, blk_left, gapsel, style;
    integer stall_left, st_i, st_e, exact_stall;
    integer cov_pp_eq, cov_pp_lt, cov_pp_gt, cov_sw_in, cov_open;
    reg [31:0] gaps [0:19];

    task run_scen;
        input integer sc;
        input integer w_in, m_in, n_in;
        input integer sty;               // 0 normal, 1 long stalls, 2 saturated, 3 quiet
        integer t, k, ci, ce, cp, ts_, tn_, tmax_, nmax_, ls, ln_, kk;
        reg [63:0] qs, qn;
        reg [15:0] lv, nv;
        begin
            scen = sc; W = w_in; M = m_in; N = n_in; style = sty;
            warmup = w_in; measure = m_in;
            rst_n = 1'b0; active_mode = 0; req_mode = 0; blk = 0; inj_x = 0; ej_x = 0; pk = 0; lt = 0; ln = 0;
            repeat (3) @(posedge clk);
            #1 rst_n = 1'b1;
            next_sw = 20 + (xs(seed) % 30); blk_left = 0; next_blk_start = 10 + (xs(seed + 1) % 40);
            stall_left = 0; st_i = 0; st_e = 0;
            for (t = 0; t < N; t = t + 1) begin
                // ---- generate cycle t inputs ----
                rnd = xs(seed); seed = rnd;
                // mode
                if (next_sw == 0) begin
                    active_mode = ~active_mode;
                    gapsel = xs(rnd + t) % 28;
                    if (gapsel < 20) next_sw = gaps[gapsel] - 1; else next_sw = 1 + (xs(rnd ^ 32'h55) % 600);
                end else next_sw = next_sw - 1;
                // req toggles randomly
                if ((xs(rnd ^ 32'hA5) % 37) == 0) req_mode = ~req_mode;
                // block periods (independent of the mode changes)
                if (blk_left > 0) begin blk_left = blk_left - 1; blk = (blk_left > 0); end
                else if (next_blk_start == 0) begin
                    blk_left = 1 + (xs(rnd ^ 32'h99) % 45); blk = 1;
                    next_blk_start = 5 + (xs(rnd ^ 32'h77) % 200);
                end else begin blk = 0; next_blk_start = next_blk_start - 1; end
                if (sty == 2 && t == N - 12) begin blk = 1; blk_left = 1000; end   // open period at the end
                if (sty == 2 && t >  N - 12) blk = 1;
                // traffic
                inj_x = xs(rnd ^ 32'h11) & xs(rnd ^ 32'h12);
                if (sty == 3) inj_x = 0;
                if (sty == 4) inj_x = 16'h00FF;
                if (stall_left > 0) begin stall_left = stall_left - 1; ej_x = 0; end
                else begin
                    ej_x = xs(rnd ^ 32'h21) & xs(rnd ^ 32'h22) & xs(rnd ^ 32'h23);
                    if (sty == 1 && (xs(rnd ^ 32'h31) % 200) == 0) stall_left = 20 + (xs(rnd ^ 32'h32) % 150);
                    if (sty == 3) ej_x = 0;
                end
                if (sty == 4) begin ej_x = 16'h0001; if (t >= 200 && t < 200 + exact_stall) ej_x = 0; end
                if (sty == 1 && t > N - 400) ej_x = 0;                       // end inside a stall
                // physical: never deliver more flits than are inside the network
                for (k = 0; k < 16; k = k + 1)
                    if (ej_x[k] && (st_i - st_e) < pc16(ej_x)) ej_x[k] = 1'b0;
                st_i = st_i + pc16(inj_x); st_e = st_e + pc16(ej_x);
                pk = xs(rnd ^ 32'h41) & xs(rnd ^ 32'h42) & xs(rnd ^ 32'h43);
                if (sty == 2) pk = (t % 7 == 0) ? 16'hFFFF : pk;             // 16 simultaneous packets
                if (sty == 3) pk = (t % 50 == 0) ? 16'h0001 : 16'h0000;
                for (k = 0; k < 16; k = k + 1) begin
                    kk = xs(rnd + k * 977 + t);
                    case (kk[3:0])
                        4'd0:    begin lv = 16'hFFFF; nv = 16'hFFFE; end
                        4'd1:    begin lv = 16'd0;    nv = 16'd0;    end
                        4'd2, 4'd3, 4'd4, 4'd5: begin lv = kk[31:16]; nv = kk[31:16] ^ kk[15:8]; end
                        default: begin lv = kk[27:16] & 16'h01FF; nv = lv - (kk[8:6]); end
                    endcase
                    lt[16*k +: 16] = lv; ln[16*k +: 16] = nv;
                end
                // ---- record trace ----
                t_mode[t] = active_mode; t_req[t] = req_mode; t_blk[t] = blk;
                t_inj[t] = pc16(inj_x); t_ej[t] = pc16(ej_x); t_pk[t] = pc16(pk);
                ts_ = 0; tn_ = 0; qs = 0; qn = 0; tmax_ = 0; nmax_ = 0;
                for (k = 0; k < 16; k = k + 1) if (pk[k]) begin
                    ts_ = ts_ + lt[16*k +: 16]; tn_ = tn_ + ln[16*k +: 16];
                    qs = qs + lt[16*k +: 16] * lt[16*k +: 16]; qn = qn + ln[16*k +: 16] * ln[16*k +: 16];
                    if (lt[16*k +: 16] > tmax_) tmax_ = lt[16*k +: 16];
                    if (ln[16*k +: 16] > nmax_) nmax_ = ln[16*k +: 16];
                end
                t_s_tot[t] = ts_; t_s_net[t] = tn_; t_q_tot[t] = qs; t_q_net[t] = qn;
                t_m_tot[t] = tmax_; t_m_net[t] = nmax_;
                @(posedge clk); #1;
            end
            // ---- compare both DUTs ----
            compare(0);
            compare(1);
            $display("INFO scen %0d: W=%0d M=%0d N=%0d style=%0d | switches=%0d pp(50,100,200,400)=%0d,%0d,%0d,%0d dwell_min=%0d drain_cnt=%0d pkts=%0d stall_max=%0d open_len=%0d",
                     sc, W, M, N, sty, m_sw, m_pp[0], m_pp[1], m_pp[2], m_pp[3], m_dmin, m_drc, m_wpk, m_smax, m_bln);
        end
    endtask

    initial begin
        errors = 0; seed = 32'h1badcafe; scen = 0;
        pp_val[0] = 50; pp_val[1] = 100; pp_val[2] = 200; pp_val[3] = 400;
        pp_val[4] = 3;  pp_val[5] = 7;   pp_val[6] = 20;  pp_val[7] = 40;
        // gaps around every T_PP of both parameter sets
        gaps[0] = 1;   gaps[1] = 2;   gaps[2] = 3;   gaps[3] = 4;   gaps[4] = 7;   gaps[5] = 8;
        gaps[6] = 20;  gaps[7] = 21;  gaps[8] = 40;  gaps[9] = 41;  gaps[10] = 50; gaps[11] = 51;
        gaps[12] = 100; gaps[13] = 101; gaps[14] = 200; gaps[15] = 201; gaps[16] = 400; gaps[17] = 401;
        gaps[18] = 49; gaps[19] = 99;
        warmup = 0; measure = 0; rst_n = 1'b0; active_mode = 0; req_mode = 0; blk = 0;
        inj_x = 0; ej_x = 0; pk = 0; lt = 0; ln = 0;
        #1;
        //            sc  W     M     N     style
        exact_stall = 0;
        run_scen(1,   0,    8000, 8000, 0);     // window = whole run
        run_scen(2,   500,  3000, 8000, 0);     // window in the middle
        run_scen(3,   100,  20000, 6000, 0);    // window longer than the run
        run_scen(4,   200,  0,    3000, 0);     // zero length
        run_scen(5,   9000, 1000, 5000, 0);     // warm-up beyond the run
        run_scen(6,   0,    1,    500,  0);     // one-cycle window at the start
        run_scen(7,   1000, 2500, 9000, 1);     // long stalls (watchdog on both)
        run_scen(8,   50,   4000, 5000, 2);     // 16 simultaneous packets, open blocked period
        run_scen(9,   0,    4000, 4000, 3);     // quiet network
        run_scen(10,  2000, 1500, 7000, 0);
        run_scen(11,  0,    11000, 11500, 0);   // long
        // window start sweep: a switch just before the window must not pair with one inside it
        for (sweep = 0; sweep < 60; sweep = sweep + 1)
            run_scen(100 + sweep, 100 + 9 * sweep, 300, 700, 0);
        // a stall of exactly 29 / 30 / 31 cycles (limit of instance B is 30)
        exact_stall = 29; run_scen(201, 0, 500, 600, 4);
        exact_stall = 30; run_scen(202, 0, 500, 600, 4);
        exact_stall = 31; run_scen(203, 0, 500, 600, 4);
        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
