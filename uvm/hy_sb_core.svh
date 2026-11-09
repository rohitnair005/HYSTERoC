// =============================================================================
// hy_sb_core.svh : the scoreboard LOGIC without any UVM dependency (so it can be
// unit tested in plain SystemVerilog). hy_scoreboard (hy_scoreboard.svh) is a thin
// UVM wrapper around it. Records are copies of the monitors' observations.
//
// Rules checked
//   R1  every injected packet is delivered exactly once, and nothing is delivered
//       that was not injected (phantom / duplicate)          [on_eject, check_end]
//   R2  delivered content equals injected content (src, dst, pid, every payload word)
//   R3  delivered at the node named in the header (unless allow_dest_mismatch)
//   R4  framing errors reported by the monitors are errors
//   R5  network latency (first header transfer at the source to tail transfer at the
//       sink) >= distance + packet length in flits (zero-load law, DECISIONS 58: 4-flit
//       packets give distance + 4)
//   R6  XY-only networks keep per-flow order (same src and dst): chk_order
//   R7  minimal routing: the header leaves exactly dst_dist + 1 routers (every router on
//       the path, the last one through its Local port): chk_hops
//   R8  at the end nothing is left undelivered                         [check_end]
// =============================================================================
class hy_pkt_rec;
    logic [3:0]  src, dst;
    logic [7:0]  pid;
    logic [15:0] payload[];
    int          cyc_first, cyc_last;
    int          tx_node, rx_node;
    string       frame_err;
    function new();
        frame_err = ""; tx_node = -1; rx_node = -1;
    endfunction
    function int unsigned key();   return {src, pid};   endfunction
    function bit same_as(hy_pkt_rec o);
        if (src != o.src || dst != o.dst || pid != o.pid) return 0;
        if (payload.size() != o.payload.size()) return 0;
        foreach (payload[i]) if (payload[i] !== o.payload[i]) return 0;
        return 1;
    endfunction
endclass

class hy_sb_core;
    // ---- knobs
    bit chk_order      = 0;
    bit chk_latency    = 1;
    bit chk_hops       = 0;
    bit allow_dest_mismatch = 0;

    // ---- state
    hy_pkt_rec   pend[int unsigned][$];      // key -> injected, not yet delivered
    int unsigned flow_q[int][$];             // flow = {src, dst} -> keys in injection order
    int          hops[int unsigned];         // key -> header transfers out of routers
    string       errors[$];

    // ---- statistics
    int unsigned n_inj, n_ej, n_inj_flits, n_ej_flits, n_errors;
    int          last_lat_excess;            // (latency - (dist + flits)) of the packet delivered last
    int          lat_min_excess = 1000000;   // min over packets of (latency - (dst_dist + flits))
    longint      lat_sum;

    function void err(string s);
        n_errors++;
        errors.push_back(s);
    endfunction

    function void reset();
        pend.delete(); flow_q.delete(); hops.delete();
    endfunction

    function int unsigned n_pending();
        int unsigned c = 0;
        foreach (pend[k]) c += pend[k].size();
        return c;
    endfunction

    function void on_inject(hy_pkt_rec r);
        int unsigned k = r.key();
        int flow = {r.src, r.dst};
        n_inj++;
        n_inj_flits += r.payload.size() + 1;
        if (r.frame_err != "") begin err($sformatf("injected packet malformed: %s", r.frame_err)); return; end
        pend[k].push_back(r);
        flow_q[flow].push_back(k);
    endfunction

    function void on_hop_header(int unsigned k);
        if (hops.exists(k)) hops[k] = hops[k] + 1; else hops[k] = 1;
    endfunction

    function void on_eject(hy_pkt_rec r);
        int unsigned k = r.key();
        int idx = -1;
        hy_pkt_rec inj;
        int flow, dst_dist, lat, nfl;
        n_ej++;
        n_ej_flits += r.payload.size() + 1;
        if (r.frame_err != "") begin err($sformatf("delivered packet malformed at node %0d: %s", r.rx_node, r.frame_err)); return; end
        if (!pend.exists(k) || pend[k].size() == 0) begin
            err($sformatf("delivered packet src=%0d pid=%0d at node %0d was never injected or was already delivered (phantom/duplicate)", r.src, r.pid, r.rx_node));
            return;
        end
        foreach (pend[k][i]) if (idx < 0 && pend[k][i].same_as(r)) idx = i;
        if (idx < 0) begin
            idx = 0;
            err($sformatf("content mismatch for src=%0d pid=%0d: injected dst=%0d, delivered dst=%0d at node %0d (payload or header differs)",
                          r.src, r.pid, pend[k][0].dst, r.dst, r.rx_node));
        end
        inj  = pend[k][idx];
        pend[k].delete(idx);
        if (pend[k].size() == 0) pend.delete(k);

        // R3
        if (!allow_dest_mismatch && r.rx_node != int'(inj.dst))
            err($sformatf("src=%0d pid=%0d addressed to %0d was delivered at node %0d", inj.src, inj.pid, inj.dst, r.rx_node));
        // R5
        dst_dist = hy_dist(inj.src, inj.dst);
        nfl  = int'(inj.payload.size()) + 1;        // flits in the packet (header + payload)
        lat  = r.cyc_last - inj.cyc_first;
        lat_sum += lat;
        last_lat_excess = lat - (dst_dist + nfl);
        if (lat - (dst_dist + nfl) < lat_min_excess) lat_min_excess = lat - (dst_dist + nfl);
        if (chk_latency && lat < dst_dist + nfl)
            err($sformatf("src=%0d pid=%0d %0d->%0d: network latency %0d is below the physical minimum %0d", inj.src, inj.pid, inj.src, inj.dst, lat, dst_dist + nfl));
        // R6
        flow = {inj.src, inj.dst};
        if (flow_q.exists(flow)) begin
            int pos = -1;
            foreach (flow_q[flow][i]) if (pos < 0 && flow_q[flow][i] == k) pos = i;
            if (chk_order && pos > 0)
                err($sformatf("flow %0d->%0d reordered: src pid=%0d delivered before %0d earlier packet(s) of the same flow", inj.src, inj.dst, inj.pid, pos));
            if (pos >= 0) flow_q[flow].delete(pos);
            if (flow_q[flow].size() == 0) flow_q.delete(flow);
        end
        // R7
        if (chk_hops) begin
            int h = hops.exists(k) ? hops[k] : 0;
            if (h != dst_dist + 1)
                err($sformatf("src=%0d pid=%0d %0d->%0d: header left %0d routers, minimal path has %0d", inj.src, inj.pid, inj.src, inj.dst, h, dst_dist + 1));
        end
        if (hops.exists(k)) hops.delete(k);
    endfunction

    function void check_end();
        int shown = 0;
        foreach (pend[k]) foreach (pend[k][i]) begin
            if (shown < 10) err($sformatf("R8 never delivered: src=%0d dst=%0d pid=%0d", pend[k][i].src, pend[k][i].dst, pend[k][i].pid));
            shown++;
        end
        if (shown > 10) err($sformatf("R8 ... and %0d more undelivered packets", shown - 10));
    endfunction
endclass
