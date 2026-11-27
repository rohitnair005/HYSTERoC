// hy_sequencer.svh : one sequencer per inject agent (item = one packet from that node).
typedef uvm_sequencer #(hy_item) hy_sequencer;

typedef class hy_scoreboard;

// Virtual sequencer: handles to the 16 per-node sequencers, the configuration and the
// scoreboard (filled by the env). Virtual sequences use them to wait for time / idle.
class hy_vseqr extends uvm_sequencer;
    hy_sequencer   sqr[HY_NODES];
    hy_cfg         cfg;
    hy_scoreboard  sb;
    `uvm_component_utils(hy_vseqr)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass
