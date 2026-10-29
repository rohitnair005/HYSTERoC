// =============================================================================
// pm_log.vh : SIMULATION-ONLY log writer for performance_monitor results.
// `include it INSIDE a testbench module (not synthesizable: $fopen/$fwrite).
//
// The including module must provide
//   clk, rst_n                         the clock and reset
//   wire [31:0]  now                   the monitor's time base
//   wire         active_mode, inject_block_req
//   wire [15:0]  k_pkt_done            sink pulses
//   wire [63:0]  k_pkt_src             4 bit per node
//   wire [127:0] k_pkt_pid             8 bit per node
//   wire [255:0] k_lat_t, k_lat_n      16 bit per node
//   `define PM_INST <instance name>    the performance_monitor instance
//   parameters (strings) LOG_PKT, LOG_SW, LOG_BLK, LOG_SUM, LOG_TAG
//   regs LOG_WARM, LOG_MEAS            the window that was given to the monitor
// and calls  pm_write_summary;  once at the end of the run.
//
// Files (comma separated, one header line each; scripts/metrics.py reads them)
//   packets : cycle,dst,src,pid,lat_total,lat_net,in_window
//   switches: cycle,new_mode,in_window         cycle the new mode is first visible
//   blocks  : start,end,in_window_start        first and LAST cycle of inject_block_req = 1
//             (end = -1: still blocked when the summary was written)
//   summary : key=value, every monitor output plus the window and the tag
// =============================================================================
integer pml_pkt, pml_sw, pml_blk, pml_i;
reg [8*24-1:0] pml_n_pkt, pml_n_sw, pml_n_blk, pml_n_sum, pml_n_tag;
reg     pml_prev_mode, pml_prev_blk, pml_open;
integer pml_blk_start;
reg     pml_blk_win;

initial begin
    pml_n_pkt = LOG_PKT; pml_n_sw = LOG_SW; pml_n_blk = LOG_BLK; pml_n_sum = LOG_SUM; pml_n_tag = LOG_TAG;
    pml_pkt = $fopen(pml_n_pkt, "w");
    pml_sw  = $fopen(pml_n_sw,  "w");
    pml_blk = $fopen(pml_n_blk, "w");
    $fwrite(pml_pkt, "cycle,dst,src,pid,lat_total,lat_net,in_window\n");
    $fwrite(pml_sw,  "cycle,new_mode,in_window\n");
    $fwrite(pml_blk, "start,end,in_window_start\n");
    pml_prev_mode = 1'b0; pml_prev_blk = 1'b0; pml_open = 1'b0; pml_blk_start = 0; pml_blk_win = 1'b0;
end

always @(posedge clk) if (rst_n) begin
    for (pml_i = 0; pml_i < 16; pml_i = pml_i + 1)
        if (k_pkt_done[pml_i])
            $fwrite(pml_pkt, "%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", now, pml_i, k_pkt_src[4*pml_i +: 4], k_pkt_pid[8*pml_i +: 8],
                    k_lat_t[16*pml_i +: 16], k_lat_n[16*pml_i +: 16], `PM_INST.meas_en);
    if (active_mode !== pml_prev_mode)
        $fwrite(pml_sw, "%0d,%0d,%0d\n", now, active_mode, `PM_INST.meas_en);
    if (inject_block_req && !pml_prev_blk) begin
        pml_blk_start = now; pml_blk_win = `PM_INST.meas_en; pml_open = 1'b1;
    end
    if (!inject_block_req && pml_prev_blk) begin
        $fwrite(pml_blk, "%0d,%0d,%0d\n", pml_blk_start, now - 1, pml_blk_win);
        pml_open = 1'b0;
    end
    pml_prev_mode = active_mode; pml_prev_blk = inject_block_req;
end

task pm_write_summary;
    integer f;
    begin
        if (pml_open) $fwrite(pml_blk, "%0d,-1,%0d\n", pml_blk_start, pml_blk_win);
        f = $fopen(pml_n_sum, "w");
        $fwrite(f, "tag=%0s\n", pml_n_tag);
        $fwrite(f, "warmup=%0d\nmeasure=%0d\nnow=%0d\n", LOG_WARM, LOG_MEAS, `PM_INST.now);
        $fwrite(f, "meas_cycles=%0d\nmeas_done=%0d\n", `PM_INST.meas_cycles, `PM_INST.meas_done);
        $fwrite(f, "sw_total=%0d\nw_switches=%0d\nw_to_adapt=%0d\nw_to_xy=%0d\n", `PM_INST.sw_total, `PM_INST.w_switches, `PM_INST.w_to_adapt, `PM_INST.w_to_xy);
        $fwrite(f, "w_req_toggles=%0d\nw_blk_starts=%0d\n", `PM_INST.w_req_toggles, `PM_INST.w_blk_starts);
        $fwrite(f, "w_pp0=%0d\nw_pp1=%0d\nw_pp2=%0d\nw_pp3=%0d\n", `PM_INST.w_pp0, `PM_INST.w_pp1, `PM_INST.w_pp2, `PM_INST.w_pp3);
        $fwrite(f, "pp_t0=%0d\npp_t1=%0d\npp_t2=%0d\npp_t3=%0d\n", `PM_INST.PP0, `PM_INST.PP1, `PM_INST.PP2, `PM_INST.PP3);
        $fwrite(f, "w_dwell_cnt=%0d\nw_dwell_sum=%0d\nw_dwell_min=%0d\nw_dwell_max=%0d\n", `PM_INST.w_dwell_cnt, `PM_INST.w_dwell_sum, `PM_INST.w_dwell_min, `PM_INST.w_dwell_max);
        $fwrite(f, "w_adapt_cycles=%0d\nw_blocked=%0d\n", `PM_INST.w_adapt_cycles, `PM_INST.w_blocked);
        $fwrite(f, "drain_cnt=%0d\ndrain_sum=%0d\ndrain_min=%0d\ndrain_max=%0d\nblk_len_now=%0d\n", `PM_INST.drain_cnt, `PM_INST.drain_sum, `PM_INST.drain_min, `PM_INST.drain_max, `PM_INST.blk_len_now);
        $fwrite(f, "w_pkts=%0d\nw_lat_total_sum=%0d\nw_lat_total_sq=%0d\nw_lat_total_max=%0d\n", `PM_INST.w_pkts, `PM_INST.w_lat_total_sum, `PM_INST.w_lat_total_sq, `PM_INST.w_lat_total_max);
        $fwrite(f, "w_lat_net_sum=%0d\nw_lat_net_sq=%0d\nw_lat_net_max=%0d\n", `PM_INST.w_lat_net_sum, `PM_INST.w_lat_net_sq, `PM_INST.w_lat_net_max);
        $fwrite(f, "w_inj_flits=%0d\nw_ej_flits=%0d\npkts_total=%0d\ninj_flits_total=%0d\nej_flits_total=%0d\ninflight=%0d\n", `PM_INST.w_inj_flits, `PM_INST.w_ej_flits, `PM_INST.pkts_total, `PM_INST.inj_flits_total, `PM_INST.ej_flits_total, `PM_INST.inflight);
        $fwrite(f, "stall_max=%0d\nstall_flag=%0d\n", `PM_INST.stall_max, `PM_INST.stall_flag);
        $fclose(f);
        $fclose(pml_pkt); $fclose(pml_sw); $fclose(pml_blk);
    end
endtask
