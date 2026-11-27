// =============================================================================
// hy_types.svh : constants, flit type and PURE helper functions of the HYSTERoC
// UVM environment. Contains NO UVM code, so it can also be compiled and unit
// tested by itself (plain SystemVerilog). Included inside package hy_pkg.
//
// Network contract (DECISIONS / spec 4): 4x4 mesh, node n = 4*y + x (x East,
// y South); flit = 2-bit type + 16-bit data; packet = header, body..., tail
// (contract: 4 flits); header = {dst_x, dst_y, src_x, src_y, pid} (2,2,2,2,8).
// Port ids on a router: N=0 S=1 E=2 W=3 L=4.
// =============================================================================
localparam int HY_NODES = 16;
localparam int HY_DIM   = 4;
localparam int HY_PKT_FLITS = 4;       // contract length (not enforced by the router)

localparam logic [1:0] HY_FT_HDR  = 2'b00;
localparam logic [1:0] HY_FT_BODY = 2'b01;
localparam logic [1:0] HY_FT_TAIL = 2'b10;
localparam logic [1:0] HY_FT_RSVD = 2'b11;

typedef struct packed {
    logic [1:0]  ftype;
    logic [15:0] data;
} hy_flit_t;

typedef enum int { HY_RDY_ALWAYS = 0, HY_RDY_RANDOM = 1, HY_RDY_BURSTY = 2, HY_RDY_NEVER = 3 } hy_ready_mode_e;

typedef enum logic [2:0] {
    HY_ST_RUN = 3'd0, HY_ST_QUIESCE = 3'd1, HY_ST_WAIT = 3'd2, HY_ST_DRAIN = 3'd3,
    HY_ST_SWITCH = 3'd4, HY_ST_RESUME = 3'd5, HY_ST_ERROR = 3'd6
} hy_ctrl_state_e;

// ---------------------------------------------------------------- coordinates
function automatic int hy_x(int n);            return n % HY_DIM;            endfunction
function automatic int hy_y(int n);            return n / HY_DIM;            endfunction
function automatic int hy_dist(int a, int b);
    int dx, dy;
    dx = hy_x(a) - hy_x(b); if (dx < 0) dx = -dx;
    dy = hy_y(a) - hy_y(b); if (dy < 0) dy = -dy;
    return dx + dy;
endfunction

// ---------------------------------------------------------------- header fields
function automatic logic [15:0] hy_make_hdr(logic [3:0] dst, logic [3:0] src, logic [7:0] pid);
    return {dst[1:0], dst[3:2], src[1:0], src[3:2], pid};
endfunction
function automatic logic [3:0] hy_hdr_dst(logic [15:0] h);  return {h[13:12], h[15:14]};  endfunction
function automatic logic [3:0] hy_hdr_src(logic [15:0] h);  return {h[9:8],  h[11:10]};   endfunction
function automatic logic [7:0] hy_hdr_pid(logic [15:0] h);  return h[7:0];                 endfunction

// ---------------------------------------------------------------- packet <-> flits
// payload = data of every flit after the header; the LAST element is the tail.
function automatic void hy_build_flits(logic [3:0] dst, logic [3:0] src, logic [7:0] pid,
                                        input logic [15:0] payload[], ref hy_flit_t q[$]);
    hy_flit_t f;
    q.delete();
    f.ftype = HY_FT_HDR;  f.data = hy_make_hdr(dst, src, pid);  q.push_back(f);
    for (int i = 0; i < payload.size(); i++) begin
        f.data  = payload[i];
        f.ftype = (i == payload.size() - 1) ? HY_FT_TAIL : HY_FT_BODY;
        q.push_back(f);
    end
endfunction

// Parse a complete flit sequence (header ... tail). Returns 1 if it is well
// formed (first = header, middle = body, last = tail, at least header + tail).
function automatic bit hy_parse_flits(input hy_flit_t q[$],
                                       output logic [3:0] dst, output logic [3:0] src, output logic [7:0] pid,
                                       output logic [15:0] payload[], output string err);
    dst = '0; src = '0; pid = '0; payload = new[0]; err = "";
    if (q.size() < 2) begin err = $sformatf("packet with %0d flits", q.size()); return 0; end
    if (q[0].ftype != HY_FT_HDR) begin err = "first flit is not a header"; return 0; end
    dst = hy_hdr_dst(q[0].data); src = hy_hdr_src(q[0].data); pid = hy_hdr_pid(q[0].data);
    payload = new[q.size() - 1];
    for (int i = 1; i < q.size(); i++) begin
        payload[i-1] = q[i].data;
        if (i == q.size() - 1) begin
            if (q[i].ftype != HY_FT_TAIL) begin err = "last flit is not a tail"; return 0; end
        end else begin
            if (q[i].ftype != HY_FT_BODY) begin err = $sformatf("flit %0d is not a body flit", i); return 0; end
        end
    end
    return 1;
endfunction
