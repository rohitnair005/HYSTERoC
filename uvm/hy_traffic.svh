// =============================================================================
// hy_traffic.svh : PURE helpers of the workload library (no UVM; unit tested).
//   hy_pick_dst       destination of a packet from `src` for a traffic pattern
//                     (-1: this node sends nothing in this pattern)
//   hy_gap_for_load   idle cycles before the next packet for an offered load
// Offered load is in flits per node per cycle x 1000 (100 = 0.10 flits/node/cycle).
// A packet occupies its source for `flits` cycles plus 1 idle cycle (decision cycle);
// the gap is drawn uniformly from 0 .. 2*mean so that the mean period is
// flits*1000/load_pm cycles. A source that is back-pressured sends less than offered.
// =============================================================================
typedef enum int {
    HY_PAT_UNIFORM    = 0,     // any other node, uniformly
    HY_PAT_HOTSPOT    = 1,     // hot_pct % to the hot node, the rest uniform
    HY_PAT_TRANSPOSE  = 2,     // (x,y) -> (y,x); the diagonal is silent
    HY_PAT_COMPLEMENT = 3,     // node n -> 15 - n (opposite corner / mirror)
    HY_PAT_NEIGHBOUR  = 4,     // (x,y) -> (x+1 mod 4, y)
    HY_PAT_BITREV     = 5      // node number with its 4 bits reversed; fixed points silent
} hy_pattern_e;

function automatic int hy_pick_dst(hy_pattern_e pat, int src, int hot, int hot_pct);
    int x = src % HY_DIM;
    int y = src / HY_DIM;
    int d = src;
    logic [3:0] s4 = src[3:0];
    case (pat)
        HY_PAT_HOTSPOT: begin
            if (src != hot && int'($urandom_range(99)) < hot_pct) d = hot;
            else d = (src + 1 + int'($urandom_range(HY_NODES - 2))) % HY_NODES;
        end
        HY_PAT_TRANSPOSE:  d = HY_DIM * x + y;
        HY_PAT_COMPLEMENT: d = HY_NODES - 1 - src;
        HY_PAT_NEIGHBOUR:  d = HY_DIM * y + ((x + 1) % HY_DIM);
        HY_PAT_BITREV:     d = {s4[0], s4[1], s4[2], s4[3]};
        default:           d = (src + 1 + int'($urandom_range(HY_NODES - 2))) % HY_NODES;
    endcase
    if (d == src) return -1;
    return d;
endfunction

function automatic int unsigned hy_gap_for_load(int unsigned load_pm, int unsigned flits);
    int mean;
    if (load_pm == 0) return 0;
    mean = int'((flits * 1000) / load_pm) - int'(flits + 1);
    if (mean <= 0) return 0;
    return $urandom_range(2 * mean);
endfunction
