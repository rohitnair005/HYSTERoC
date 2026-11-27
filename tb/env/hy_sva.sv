// =============================================================================
// hy_sva.sv : concurrent assertions on the interface (module, instantiated once in
// test.sv with the interface). Stateless / short-history properties only, so any
// simulator can run them; the deep checks are in hy_model (hy_protocol_checker).
// A failure increments vif.sva_errors, which the protocol checker reports in
// check_phase (UVM does not count SVA $error messages by itself).
// Controller state codes: RUN 0, QUIESCE 1, WAIT 2, DRAIN 3, SWITCH 4, RESUME 5, ERROR 6.
// =============================================================================
`define HY_ASSERT(NAME, PROP, MSG) \
    NAME: assert property (@(posedge vif.clk) disable iff (!vif.rst_n) PROP) \
          else begin vif.sva_hit(); $error("SVA %s: %s", `"NAME`", MSG); end

module hy_sva #(parameter SWITCH_POLICY = 0) (hy_if vif);

    // ---- control plane
    `HY_ASSERT(a_blk_implies_busy, (vif.inject_block_req |-> vif.transition_busy),
               "inject_block_req without transition_busy")
    `HY_ASSERT(a_state_legal,      (vif.ctrl_state != 3'd7),
               "illegal ctrl_state encoding 7")
    `HY_ASSERT(a_timeout_is_error, (vif.drain_timeout == (vif.ctrl_state == 3'd6)),
               "drain_timeout does not equal (state == ERROR)")
    generate
      if (SWITCH_POLICY == 0) begin : g_drain
        `HY_ASSERT(a_mode_change_only_after_switch,
                   ($changed(vif.active_mode) |-> (($past(vif.ctrl_state) == 3'd4) && $past(vif.network_drained))),
                   "active_mode changed outside a SWITCH cycle with network_drained")
        `HY_ASSERT(a_mode_change_sources_idle,
                   ($changed(vif.active_mode) |-> (vif.src_empty == 16'hFFFF)),
                   "active_mode changed while a source was busy")
        `HY_ASSERT(a_start_only_from_run,
                   ($rose(vif.transition_busy) |-> (($past(vif.ctrl_state) == 3'd0) && ($past(vif.req_mode) != $past(vif.active_mode)))),
                   "a transition started from a state other than RUN or without a mode request")
        `HY_ASSERT(a_block_rises_from_run,
                   ($rose(vif.inject_block_req) |-> ($past(vif.ctrl_state) == 3'd0)),
                   "inject_block_req rose from a state other than RUN")
        `HY_ASSERT(a_release_in_resume,
                   ($fell(vif.inject_block_req) |-> (vif.ctrl_state == 3'd5)),
                   "injection released outside the first RESUME cycle")
        `HY_ASSERT(a_error_sticky,
                   ((vif.ctrl_state == 3'd6) |=> (vif.ctrl_state == 3'd6)),
                   "ERROR state left without reset")
        `HY_ASSERT(a_no_inject_in_drain_switch,
                   (((vif.ctrl_state == 3'd3) || (vif.ctrl_state == 3'd4)) |-> (vif.inj_valid == 16'h0000)),
                   "a source offered a flit during DRAIN or SWITCH")
      end else begin : g_nodrain
        // ---- no-drain policy: the controller is a wire, active_mode = req_mode one cycle later
        `HY_ASSERT(a_nd_run_only, (vif.ctrl_state == 3'd0 && !vif.inject_block_req && !vif.transition_busy && !vif.drain_timeout),
                   "no-drain policy: controller left RUN or blocked injection")
        `HY_ASSERT(a_nd_mode_follows_req, (1'b1 |=> (vif.active_mode == $past(vif.req_mode))),
                   "no-drain policy: active_mode is not req_mode delayed by one cycle")
      end
    endgenerate

    `HY_ASSERT(a_drained_means_empty,
               (vif.network_drained |-> ((&vif.router_empty) && (&vif.src_empty))),
               "network_drained while a router or a source is not empty")
    `HY_ASSERT(a_no_internal_errors,
               ((!vif.proto_err_any) && (!vif.alloc_err_any)),
               "proto_err_any or alloc_err_any is set")
    `HY_ASSERT(a_no_x_control,
               (!$isunknown({vif.ctrl_state, vif.active_mode, vif.req_mode, vif.inject_block_req,
                             vif.network_drained, vif.inj_ready, vif.ej_valid, vif.router_empty})),
               "X or Z on a control or handshake output")

    // ---- per ejection port: a stalled output must hold
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : g_ej
            `HY_ASSERT(a_ej_hold,
                       ((vif.ej_valid[i] && !vif.ej_ready[i]) |=>
                        (vif.ej_valid[i] && $stable(vif.ej_data[16*i +: 16]) && $stable(vif.ej_type[2*i +: 2]))),
                       "ejection output changed or dropped while stalled")
        end
    endgenerate

endmodule
