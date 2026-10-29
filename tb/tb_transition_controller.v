// =============================================================================
// tb_transition_controller.v : self-checking testbench for transition_controller
//
// Six environments (module tc_env), each with its own DUT, parameters, driver
// processes and scenario:
//   0 directed timeline (instant, slow acks, slow drain, retarget-ignored,
//     SWITCH re-check) LIMIT=1000 MASK=0
//   1 watchdog boundaries (LIMIT=12): drained exactly at cycle LIMIT succeeds,
//     LIMIT+1 times out, ack too late times out, never-drained times out,
//     ERROR is sticky, reset recovers
//   2 post-resume mask (MASK=5): RESUME lasts 6 cycles, EWMA/hysteresis frozen
//   3,4,5 long random runs (different LIMIT/MASK/seed): random req_mode,
//     per-source random ack delays, random drained levels, random resets
// In every environment, every cycle:
//   * the DUT is compared with an independent cycle model written in terms of
//     the blocked-cycle index k (cycle 1 = first cycle inject_block_req = 1)
//     (state, active_mode, outputs, all counters and timestamps)
//   * safety properties: active_mode changes only after a cycle with
//     state==SWITCH && network_drained; injection block is high in all of
//     QUIESCE/WAIT/DRAIN/SWITCH/ERROR and low in RUN/RESUME; ewma_enable and
//     hys_enable == (state==RUN); once in ERROR the state, active_mode and the
//     block never change until reset; the all-ack/drained conditions held when
//     the FSM left WAIT/DRAIN
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tc_env #(
    parameter SCEN  = 0,
    parameter LIMIT = 1000,
    parameter MASK  = 0,
    parameter SEED  = 1,
    parameter RANDOM_CYCLES = 60000
) (
    input  wire clk,
    output reg  done,
    output reg  [31:0] err_count,
    output reg  [31:0] cov_o
);
    // ---------------- DUT ----------------
    reg         rst_n;
    reg         req_mode;
    reg  [15:0] acks;
    reg         drained;
    wire        active_mode, inject_block_req, ewma_enable, hys_enable, transition_busy, drain_timeout, target_mode;
    wire [2:0]  state;
    wire [31:0] cycle_cnt, tr_blocked, tr_ackwait, tr_drain, tot_blocked, tot_ackwait, tot_drain, transitions;
    wire [31:0] t_block, t_ack, t_drained, t_switch, t_resume;

    transition_controller #(.N_SRC(16), .WATCHDOG_LIMIT_CYCLES(LIMIT), .POST_RESUME_MASK_CYCLES(MASK)) dut (
        .clk(clk), .rst_n(rst_n), .req_mode(req_mode), .inject_block_ack(acks), .network_drained(drained),
        .active_mode(active_mode), .inject_block_req(inject_block_req), .ewma_enable(ewma_enable),
        .hys_enable(hys_enable), .transition_busy(transition_busy), .drain_timeout(drain_timeout),
        .state_o(state), .target_mode_o(target_mode),
        .cycle_cnt(cycle_cnt), .tr_blocked(tr_blocked), .tr_ackwait(tr_ackwait), .tr_drain(tr_drain),
        .tot_blocked(tot_blocked), .tot_ackwait(tot_ackwait), .tot_drain(tot_drain), .transitions(transitions),
        .t_block(t_block), .t_ack(t_ack), .t_drained(t_drained), .t_switch(t_switch), .t_resume(t_resume)
    );

    localparam [2:0] S_RUN = 0, S_QUIESCE = 1, S_WAIT = 2, S_DRAIN = 3, S_SWITCH = 4, S_RESUME = 5, S_ERROR = 6;

    integer errors;
    task fail; input [255:0] msg;
        begin errors = errors + 1; if (errors <= 6) $display("ERROR[scen %0d] @%0t: %0s (state=%0d model=%0d)", SCEN, $time, msg, state, m_state); end
    endtask

    // ---------------- independent model ----------------
    integer m_state, m_target, m_active, m_k, m_mask, m_cyc;
    integer m_tr_blocked, m_tr_ackwait, m_tr_drain, m_tot_blocked, m_tot_ackwait, m_tot_drain, m_trans;
    integer m_t_block, m_t_ack, m_t_drained, m_t_switch;
    reg     m_started;
    integer m_ev_switch_fallback, m_ev_error, m_ev_done, m_ev_slowack, m_ev_ignored_req;

    task model_reset;
        begin
            m_state = 0; m_target = 0; m_active = 0; m_k = 0; m_mask = 0; m_cyc = 0;
            m_tr_blocked = 0; m_tr_ackwait = 0; m_tr_drain = 0; m_tot_blocked = 0; m_tot_ackwait = 0; m_tot_drain = 0; m_trans = 0;
            m_t_block = 0; m_t_ack = 0; m_t_drained = 0; m_t_switch = 0;
        end
    endtask

    // advance the model one clock using inputs sampled before the edge
    task model_step;
        integer k, ns;
        reg allack;
        begin
            allack = (acks == 16'hFFFF);
            m_cyc = m_cyc + 1;
            k = m_k + 1;             // index of THIS cycle if blocked (QUIESCE is 1)
            ns = m_state;
            // counters count the cycle being spent
            if (m_state != S_RUN && m_state != S_RESUME) begin
                m_tr_blocked = m_tr_blocked + 1; m_tot_blocked = m_tot_blocked + 1;
            end
            if (m_state == S_QUIESCE || m_state == S_WAIT) begin m_tr_ackwait = m_tr_ackwait + 1; m_tot_ackwait = m_tot_ackwait + 1; end
            if (m_state == S_DRAIN) begin m_tr_drain = m_tr_drain + 1; m_tot_drain = m_tot_drain + 1; end
            case (m_state)
                S_RUN: begin
                    m_k = 0;
                    if (req_mode != m_active) begin
                        m_target = req_mode; ns = S_QUIESCE;
                        m_tr_blocked = 0; m_tr_ackwait = 0; m_tr_drain = 0;
                        m_t_block = m_cyc + 0;      // value of cycle_cnt in the first QUIESCE cycle
                    end
                end
                S_QUIESCE: begin
                    m_k = k;
                    ns = (k >= LIMIT) ? S_ERROR : S_WAIT;
                end
                S_WAIT: begin
                    m_k = k;
                    if (k >= LIMIT) ns = S_ERROR;
                    else if (allack) begin ns = S_DRAIN; m_t_ack = m_cyc; end
                end
                S_DRAIN: begin
                    m_k = k;
                    if (drained && k <= LIMIT) begin ns = S_SWITCH; m_t_drained = m_cyc; end
                    else if (k >= LIMIT) ns = S_ERROR;
                end
                S_SWITCH: begin
                    m_k = k;
                    if (drained) begin
                        m_active = m_target; m_trans = m_trans + 1; m_mask = MASK; ns = S_RESUME; m_t_switch = m_cyc;
                    end else begin ns = S_DRAIN; m_ev_switch_fallback = m_ev_switch_fallback + 1; end
                end
                S_RESUME: begin
                    if (m_mask == 0) ns = S_RUN; else m_mask = m_mask - 1;
                end
                S_ERROR: ns = S_ERROR;
            endcase
            if (m_state == S_ERROR) m_k = k;   // irrelevant
            m_state = ns;
        end
    endtask

    // ---------------- per-cycle checker (negedge) ----------------
    reg       first_check;
    reg       err_seen;
    reg       err_active;
    integer   cov_trans, cov_fallback, cov_error, cov_mask_cycles, cov_slow;

    always @(negedge clk) if (rst_n) begin
        // model vs DUT
        if (state !== m_state[2:0]) fail("state vs model");
        if (active_mode !== m_active[0]) fail("active_mode vs model");
        if (cycle_cnt !== m_cyc) fail("cycle_cnt");
        if (tr_blocked !== m_tr_blocked) fail("tr_blocked");
        if (tr_ackwait !== m_tr_ackwait) fail("tr_ackwait");
        if (tr_drain !== m_tr_drain) fail("tr_drain");
        if (tot_blocked !== m_tot_blocked) fail("tot_blocked");
        if (tot_ackwait !== m_tot_ackwait) fail("tot_ackwait");
        if (tot_drain !== m_tot_drain) fail("tot_drain");
        if (transitions !== m_trans) fail("transitions");
        if (state != S_RUN && target_mode !== m_target[0]) fail("target_mode");
        // timestamps, checked in the first cycle of the corresponding state
        if (state == S_QUIESCE && s_state != S_QUIESCE && t_block !== cycle_cnt) fail("t_block");
        if (state == S_DRAIN   && s_state == S_WAIT   && t_ack !== cycle_cnt) fail("t_ack");
        if (state == S_SWITCH  && s_state == S_DRAIN  && t_drained !== cycle_cnt) fail("t_drained");
        if (state == S_RESUME  && s_state == S_SWITCH && (t_switch !== cycle_cnt || t_resume !== cycle_cnt)) fail("t_switch/t_resume");
        // static properties
        if (inject_block_req !== (state != S_RUN && state != S_RESUME)) fail("inject_block_req");
        if (ewma_enable !== (state == S_RUN)) fail("ewma_enable");
        if (hys_enable !== (state == S_RUN)) fail("hys_enable");
        if (transition_busy !== (state != S_RUN)) fail("transition_busy");
        if (drain_timeout !== (state == S_ERROR)) fail("drain_timeout");
        // active_mode changes only after SWITCH with drained
        if (!first_check && active_mode !== s_active) begin
            if (!(s_state == S_SWITCH && s_drained)) fail("active_mode changed outside SWITCH/drained");
            if (state != S_RESUME) fail("mode change not followed by RESUME");
        end
        // leaving WAIT toward DRAIN needs all acks; leaving DRAIN toward SWITCH needs drained
        if (!first_check && s_state == S_WAIT && state == S_DRAIN && !s_allack) fail("left WAIT without all acks");
        if (!first_check && s_state == S_DRAIN && state == S_SWITCH && !s_drained) fail("left DRAIN without drained");
        // ERROR is sticky
        if (state == S_ERROR) begin
            if (err_seen) begin
                if (active_mode !== err_active) fail("active_mode changed in ERROR");
                if (s_state != S_ERROR) fail("left ERROR without reset");
            end else begin
                err_seen = 1'b1; err_active = active_mode; cov_error = cov_error + 1;
            end
            if (inject_block_req !== 1'b1) fail("ERROR must keep injection blocked");
        end
        if (state == S_RESUME && s_state != S_RESUME) cov_trans = cov_trans + 1;
        if (state == S_RESUME) cov_mask_cycles = cov_mask_cycles + 1;
        first_check = 1'b0;
    end

    // values of the cycle that is ending, sampled just before the edge
    reg [2:0] s_state; reg s_active, s_drained, s_allack;
    always @(posedge clk) begin
        s_state = state; s_active = active_mode; s_drained = drained; s_allack = (acks == 16'hFFFF);
    end

    // the model advances on every posedge with the input values set at negedge
    always @(posedge clk) begin
        if (!rst_n) model_reset;
        else        model_step;
    end

    // ---------------- drivers ----------------
    // ack_mode: 0 instant, 1 random per-source delay, 2 source 7 held back (ack_hold cycles), 3 never, 4 hold-back then late
    integer ack_mode, ack_hold, drain_mode, drain_delay, drain_k, drain_p, kcnt, dcnt, delay_s [0:15], seed, rr, ii;
    reg     drop_once_armed;
    reg     drained_prev_state_switch;

    always @(negedge clk) begin
        // blocked-cycle index of the cycle now displayed
        if (state != S_RUN && state != S_RESUME) kcnt = kcnt + 1; else kcnt = 0;
        if (state == S_DRAIN) dcnt = dcnt + 1; else if (state != S_SWITCH) dcnt = 0;
        // acks
        for (ii = 0; ii < 16; ii = ii + 1) begin
            if (!inject_block_req) begin
                // block released: acks drop (immediately, or randomly late in the random scenarios)
                if (ack_mode == 1) begin rr = $random(seed); if (rr[1:0] == 0) acks[ii] = 1'b0; end
                else acks[ii] = 1'b0;
                delay_s[ii] = -1;
            end else begin
                case (ack_mode)
                    0: acks[ii] = 1'b1;
                    1: begin
                        if (delay_s[ii] < 0) begin rr = $random(seed); if (rr < 0) rr = -rr; delay_s[ii] = rr % 6; end
                        if (delay_s[ii] == 0) acks[ii] = 1'b1; else delay_s[ii] = delay_s[ii] - 1;
                    end
                    2, 4: acks[ii] = (ii == 7) ? (kcnt > ack_hold) : 1'b1;
                    default: acks[ii] = 1'b0;
                endcase
            end
        end
        // drained
        case (drain_mode)
            0: drained = 1'b1;
            1: drained = (state == S_DRAIN || state == S_SWITCH) && (dcnt >= drain_delay);
            2: drained = 1'b0;
            3: begin rr = $random(seed); if (rr < 0) rr = -rr; drained = ((rr % 100) < drain_p); end
            4: begin  // drained, but drops once in the first SWITCH cycle
                drained = 1'b1;
                if (state == S_SWITCH && drop_once_armed) begin drained = 1'b0; drop_once_armed = 1'b0; end
            end
            5: drained = (kcnt >= drain_k);     // true from blocked-cycle index K on
            6: begin  // random, but sticky for a while once true
                rr = $random(seed); if (rr < 0) rr = -rr;
                if (state != S_DRAIN && state != S_SWITCH) drained = 1'b0;
                else if (!drained) drained = ((rr % 100) < drain_p);
                else if ((rr % 100) < 12) drained = 1'b0;
            end
            default: drained = 1'b0;
        endcase
    end

    // ---------------- scenario helpers ----------------
    task tick; input integer n; integer q; begin for (q = 0; q < n; q = q + 1) @(negedge clk); end endtask
    task wait_run;   // until RUN and stays RUN for 3 cycles
        integer guard;
        begin
            guard = 0;
            tick(2);     // a pending request leaves RUN within two cycles
            while (!(state == S_RUN) && guard < 5000) begin @(negedge clk); guard = guard + 1; end
            if (guard >= 5000) fail("timeout waiting for RUN");
            tick(3);
        end
    endtask
    task do_reset;
        begin
            @(negedge clk); rst_n = 1'b0; acks = 16'h0; drained = 1'b0;
            @(negedge clk); @(negedge clk);
            rst_n = 1'b1;
            err_seen = 1'b0; first_check = 1'b1; kcnt = 0; dcnt = 0;
            @(negedge clk);
        end
    endtask
    task expect_state; input [2:0] s; input [255:0] msg; begin if (state !== s) fail(msg); end endtask

    integer j, n_trans_before, t0, total;
    integer rcnt;

    initial begin
        done = 1'b0; err_count = 0; cov_o = 0; errors = 0; seed = SEED;
        cov_trans = 0; cov_fallback = 0; cov_error = 0; cov_mask_cycles = 0; cov_slow = 0;
        m_ev_switch_fallback = 0; err_seen = 1'b0; err_active = 1'b0; first_check = 1'b1;
        rst_n = 1'b0; req_mode = 1'b0; acks = 16'h0; drained = 1'b0;
        ack_mode = 0; ack_hold = 0; drain_mode = 0; drain_delay = 0; drain_k = 0; drain_p = 50; kcnt = 0; dcnt = 0;
        drop_once_armed = 1'b0; model_reset;
        for (ii = 0; ii < 16; ii = ii + 1) delay_s[ii] = -1;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        case (SCEN)
        // =====================================================================
        0: begin
            // D1: no request -> stays RUN
            tick(20);
            expect_state(S_RUN, "D1 left RUN without request");
            if (inject_block_req) fail("D1 block asserted");
            // D2: instant acks, always drained. Expected: RUN, QUIESCE, WAIT, DRAIN, SWITCH, RESUME, RUN
            ack_mode = 0; drain_mode = 0;
            req_mode = 1'b1;
            @(negedge clk);
            expect_state(S_QUIESCE, "D2 QUIESCE"); if (inject_block_req !== 1'b1) fail("D2 block");
            @(negedge clk); expect_state(S_WAIT, "D2 WAIT");
            @(negedge clk); expect_state(S_DRAIN, "D2 DRAIN");
            @(negedge clk); expect_state(S_SWITCH, "D2 SWITCH"); if (active_mode !== 1'b0) fail("D2 mode changed early");
            @(negedge clk); expect_state(S_RESUME, "D2 RESUME"); if (active_mode !== 1'b1) fail("D2 mode not switched"); if (inject_block_req) fail("D2 block not released");
            @(negedge clk); expect_state(S_RUN, "D2 back to RUN");
            if (tr_blocked !== 4 || tr_ackwait !== 2 || tr_drain !== 1) fail("D2 durations");
            if (transitions !== 1) fail("D2 transitions");
            wait_run;
            // D3: slow ack from one source (20 cycles): WAIT must last until it acks
            req_mode = 1'b0; ack_mode = 2; ack_hold = 20; drain_mode = 0;
            tick(3);
            for (j = 0; j < 15; j = j + 1) begin @(negedge clk); if (state == S_DRAIN) fail("D3 DRAIN before all acks"); end
            wait_run;
            if (tr_ackwait < 21) fail("D3 ack wait too short");
            // D4: slow drain (25 cycles in DRAIN)
            req_mode = 1'b1; ack_mode = 0; drain_mode = 1; drain_delay = 25;
            tick(12);
            if (state !== S_DRAIN) fail("D4 not draining");
            if (active_mode !== 1'b0) fail("D4 switched before drained");
            wait_run;
            if (tr_drain < 25) fail("D4 drain duration");
            // D5: retarget during a transition is ignored; afterwards a new transition starts
            req_mode = 1'b0; ack_mode = 0; drain_mode = 1; drain_delay = 30;     // XY requested (active = ADAPT)
            tick(15);
            if (state !== S_DRAIN) fail("D5 not draining");
            req_mode = 1'b1;       // flips back to the active mode: must be ignored
            tick(5);
            req_mode = 1'b0;
            tick(5);
            req_mode = 1'b1;
            n_trans_before = transitions;
            wait_run;
            // transition 1 finished toward XY, then req=ADAPT starts transition 2
            tick(1);
            if (transitions < n_trans_before + 1) fail("D5 first transition did not finish");
            m_ev_ignored_req = 1;
            wait_run;
            req_mode = 1'b0; drain_mode = 0; wait_run;
            // D6: SWITCH re-check: drained drops in the first SWITCH cycle -> back to DRAIN, no switch
            drain_mode = 4; drop_once_armed = 1'b1; req_mode = 1'b1;
            tick(4);
            wait_run;
            if (active_mode !== 1'b1) fail("D6 final mode");
            if (m_ev_switch_fallback == 0) fail("D6 fallback not exercised");
            // D7: repeated requests, ack=random delays
            ack_mode = 1; drain_mode = 6; drain_p = 30;
            for (j = 0; j < 30; j = j + 1) begin req_mode = ~req_mode; wait_run; tick(2); end
        end
        // =====================================================================
        1: begin   // LIMIT = 12, watchdog boundaries, acks instant
            ack_mode = 0;
            // W1: drained first seen in cycle LIMIT -> success
            drain_mode = 5; drain_k = LIMIT; req_mode = 1'b1;
            wait_run;
            if (transitions !== 1 || active_mode !== 1'b1 || drain_timeout) fail("W1 should succeed at cycle LIMIT");
            // W2: drained at cycle LIMIT+1 -> timeout
            req_mode = 1'b0; drain_mode = 5; drain_k = LIMIT + 1;
            tick(LIMIT + 6);
            if (state !== S_ERROR || !drain_timeout) fail("W2 should time out");
            if (active_mode !== 1'b1) fail("W2 mode changed on timeout");
            tick(50);
            if (state !== S_ERROR || inject_block_req !== 1'b1 || active_mode !== 1'b1) fail("W2 ERROR not sticky");
            if (transitions !== 1) fail("W2 transitions changed");
            drain_mode = 0; req_mode = 1'b1; tick(10);
            if (state !== S_ERROR) fail("W2 left ERROR when drained appeared");
            // reset is the only recovery
            req_mode = 1'b0; do_reset;
            if (state !== S_RUN || active_mode !== 1'b0 || drain_timeout) fail("W2 reset recovery");
            if (transitions !== 0 || tot_blocked !== 0) fail("W2 counters not cleared by reset");
            // W3: never drained
            req_mode = 1'b1; drain_mode = 2; tick(LIMIT + 10);
            if (state !== S_ERROR) fail("W3 should time out");
            if (tr_blocked < LIMIT) fail("W3 blocked cycles");
            req_mode = 1'b0; do_reset;
            // W4: ack arrives too late (in cycle LIMIT) -> timeout even if drained
            req_mode = 1'b1; ack_mode = 2; ack_hold = LIMIT - 1; drain_mode = 0;
            tick(LIMIT + 8);
            if (state !== S_ERROR) fail("W4 late ack should time out");
            req_mode = 1'b0; do_reset;
            // W5: ack in cycle LIMIT-1 and drained in LIMIT -> fine (ack seen cycle LIMIT-2 index...)
            req_mode = 1'b1; ack_mode = 2; ack_hold = 1; drain_mode = 5; drain_k = LIMIT;
            wait_run;
            if (active_mode !== 1'b1) fail("W5 should succeed");
            // W6: no acks ever
            req_mode = 1'b0; ack_mode = 3; drain_mode = 0; tick(LIMIT + 8);
            if (state !== S_ERROR) fail("W6 no ack should time out");
            req_mode = 1'b0; do_reset;
            ack_mode = 0; drain_mode = 0;
            // W7: still functional after recovery
            req_mode = 1'b1; wait_run;
            if (active_mode !== 1'b1) fail("W7 not functional after reset");
        end
        // =====================================================================
        2: begin   // MASK = 5
            ack_mode = 0; drain_mode = 0; req_mode = 1'b1;
            tick(3);
            while (state != S_RESUME) @(negedge clk);
            t0 = cycle_cnt;
            for (j = 0; j < MASK; j = j + 1) begin
                if (state !== S_RESUME || ewma_enable || hys_enable || inject_block_req) fail("M1 RESUME-mask outputs");
                @(negedge clk);
            end
            if (state !== S_RESUME) fail("M1 RESUME should last MASK+1 cycles");
            @(negedge clk);
            if (state !== S_RUN || !ewma_enable || !hys_enable) fail("M1 RUN not reached after mask");
            tick(2);
            // a new request during RESUME is not honoured until RUN
            req_mode = 1'b0;
            tick(2);
            while (state != S_RESUME) @(negedge clk);
            req_mode = 1'b1; tick(2); req_mode = 1'b0;
            wait_run;
        end
        // =====================================================================
        default: begin  // random
            ack_mode = 1; drain_mode = 6; drain_p = 35;
            for (rcnt = 0; rcnt < RANDOM_CYCLES; rcnt = rcnt + 1) begin
                rr = $random(seed); if (rr < 0) rr = -rr;
                if (rr % 23 == 0) req_mode = ~req_mode;
                if (rr % 4001 == 0) begin
                    // random reset (also exercises reset out of ERROR)
                    do_reset;
                    req_mode = $random(seed);
                end
                if (rr % 1999 == 0) begin ack_mode = (ack_mode + 1) % 4; if (ack_mode == 3 && (rr & 1)) ack_mode = 0; end
                if (rr % 1301 == 0) begin drain_mode = (drain_mode == 6) ? 3 : 6; end
                if (rr % 997 == 0) drain_p = 5 + ($random(seed) & 63);
                if (rr % 7919 == 0) begin drain_mode = 4; drop_once_armed = 1'b1; end
                @(negedge clk);
            end
        end
        endcase

        tick(10);
        err_count = errors;
        cov_o = {8'd0, cov_trans[7:0], cov_error[7:0], 8'd0};
        $display("INFO: scen %0d LIMIT=%0d MASK=%0d: completed_transitions_seen=%0d errors_entered=%0d switch_fallbacks=%0d resume_cycles=%0d final_transitions=%0d errors=%0d",
                 SCEN, LIMIT, MASK, cov_trans, cov_error, m_ev_switch_fallback, cov_mask_cycles, transitions, errors);
        if (SCEN == 0 && (cov_trans < 20 || m_ev_switch_fallback == 0)) begin err_count = errors + 1; $display("ERROR: scen0 coverage"); end
        if (SCEN >= 3 && (cov_trans < 50 || cov_error == 0 || m_ev_switch_fallback == 0)) begin err_count = errors + 1; $display("ERROR: random scen %0d coverage (trans=%0d err=%0d fb=%0d)", SCEN, cov_trans, cov_error, m_ev_switch_fallback); end
        done = 1'b1;
    end
endmodule

module tb_transition_controller;
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;
    wire [5:0] dn;
    wire [31:0] e0, e1, e2, e3, e4, e5, c0, c1, c2, c3, c4, c5;

    tc_env #(.SCEN(0), .LIMIT(1000), .MASK(0), .SEED(11)) env0 (.clk(clk), .done(dn[0]), .err_count(e0), .cov_o(c0));
    tc_env #(.SCEN(1), .LIMIT(12),   .MASK(0), .SEED(12)) env1 (.clk(clk), .done(dn[1]), .err_count(e1), .cov_o(c1));
    tc_env #(.SCEN(2), .LIMIT(1000), .MASK(5), .SEED(13)) env2 (.clk(clk), .done(dn[2]), .err_count(e2), .cov_o(c2));
    tc_env #(.SCEN(3), .LIMIT(60),   .MASK(2), .SEED(14), .RANDOM_CYCLES(80000)) env3 (.clk(clk), .done(dn[3]), .err_count(e3), .cov_o(c3));
    tc_env #(.SCEN(4), .LIMIT(200),  .MASK(0), .SEED(15), .RANDOM_CYCLES(80000)) env4 (.clk(clk), .done(dn[4]), .err_count(e4), .cov_o(c4));
    tc_env #(.SCEN(5), .LIMIT(9),    .MASK(1), .SEED(16), .RANDOM_CYCLES(80000)) env5 (.clk(clk), .done(dn[5]), .err_count(e5), .cov_o(c5));

    initial begin
        wait (&dn);
        #5;
        if ((e0 + e1 + e2 + e3 + e4 + e5) == 0) $display("TB_RESULT: PASS");
        else $display("TB_RESULT: FAIL (%0d errors)", e0 + e1 + e2 + e3 + e4 + e5);
        $finish;
    end
    initial begin
        #400000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
