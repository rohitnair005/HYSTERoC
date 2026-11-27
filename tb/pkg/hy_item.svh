// =============================================================================
// hy_item.svh : one packet. Used both as the sequence item (generated) and as the
// observed transaction published by the monitors.
//   src/dst   node numbers 0..15 (n = 4*y + x)
//   pid       8-bit packet id in the header (the scoreboard key is {src, pid})
//   payload   data of every flit after the header; LAST element = tail
//             (contract: size 3 -> 4 flits; tests may change it)
//   gap       idle cycles the inject driver waits before starting this packet
// Observation fields (set by monitors, never randomised):
//   cyc_first / cyc_last   interface cycle of the first and the last flit transfer
//   tx_node / rx_node      node whose inject / eject port the packet was seen at
//   frame_err              non-empty if the monitor saw a malformed packet
// =============================================================================
class hy_item extends uvm_sequence_item;

    rand logic [3:0]  src;
    rand logic [3:0]  dst;
    rand logic [7:0]  pid;
    rand logic [15:0] payload[];
    rand int unsigned gap;

    int unsigned cyc_first;
    int unsigned cyc_last;
    int          tx_node = -1;      // observed at this inject port
    int          rx_node = -1;      // observed at this eject port
    bit          idle_only = 0;     // 1: no packet, the driver just stays idle for `gap` cycles (at least 1)
    bit          auto_pid = 1;      // 1: the inject driver overwrites pid with a per-node counter (unique per source)
    string       frame_err;

`ifndef HY_NO_CONSTRAINTS
    constraint c_dst_c  { soft dst != src; }
    constraint c_len_c  { soft payload.size() == HY_PKT_FLITS - 1; payload.size() inside {[1:15]}; }
    constraint c_gap_c  { soft gap inside {[0:8]}; }
`endif

    `uvm_object_utils(hy_item)

    function new(string name = "hy_item");
        super.new(name);
        frame_err = "";
    endfunction

    function int unsigned n_flits();  return payload.size() + 1;  endfunction
    function int unsigned key();      return {src, pid};          endfunction     // {src, pid}, 12 bit

    function void to_flits(ref hy_flit_t q[$]);
        hy_build_flits(dst, src, pid, payload, q);
    endfunction

    // fill from an observed flit sequence; returns 0 and sets frame_err if malformed
    function bit from_flits(hy_flit_t q[$]);
        logic [3:0]  d, s;
        logic [7:0]  p;
        logic [15:0] pl[];
        string       e;
        bit ok = hy_parse_flits(q, d, s, p, pl, e);
        frame_err = e;
        if (ok) begin dst = d; src = s; pid = p; payload = pl; end
        return ok;
    endfunction

    // same packet content (src, dst, pid and every payload word)
    function bit same_as(hy_item o);
        if (o == null) return 0;
        if (src != o.src || dst != o.dst || pid != o.pid) return 0;
        if (payload.size() != o.payload.size()) return 0;
        foreach (payload[i]) if (payload[i] !== o.payload[i]) return 0;
        return 1;
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("%0d->%0d pid=%0d flits=%0d [", src, dst, pid, n_flits());
        foreach (payload[i]) s = {s, $sformatf("%04h%s", payload[i], (i == payload.size() - 1) ? "" : " ")};
        s = {s, "]"};
        if (frame_err != "") s = {s, " FRAME_ERR:", frame_err};
        return s;
    endfunction

    function void do_copy(uvm_object rhs);
        hy_item r;
        super.do_copy(rhs);
        if (!$cast(r, rhs)) `uvm_fatal("hy_item", "do_copy: wrong type")
        src = r.src; dst = r.dst; pid = r.pid; payload = r.payload; gap = r.gap;
        cyc_first = r.cyc_first; cyc_last = r.cyc_last; idle_only = r.idle_only; tx_node = r.tx_node; rx_node = r.rx_node; auto_pid = r.auto_pid; frame_err = r.frame_err;
    endfunction

endclass
