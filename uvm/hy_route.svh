// =============================================================================
// hy_route.svh : reference model of the HYSTERoC route functions. PURE functions,
// no UVM. Written from the published minimal Odd-Even pseudocode (Chiu), the same
// way as scripts/route_model.py, independently of rtl/route_compute.v.
// Coordinates: x grows East, y grows South. Port ids N0 S1 E2 W3 L4; a "mask" has
// bit i set when port i is a legal output.
// Modes: 0 = XY (deterministic), 1 = adaptive minimal Odd-Even.
// =============================================================================
localparam int HY_P_N = 0;
localparam int HY_P_S = 1;
localparam int HY_P_E = 2;
localparam int HY_P_W = 3;
localparam int HY_P_L = 4;

function automatic logic [4:0] hy_xy_mask(int x, int y, int dx, int dy);
    if (dx > x) return 5'b00100;       // E
    if (dx < x) return 5'b01000;       // W
    if (dy > y) return 5'b00010;       // S
    if (dy < y) return 5'b00001;       // N
    return 5'b10000;                   // L
endfunction

function automatic logic [4:0] hy_oe_mask(int x, int y, int sx, int dx, int dy);
    int e0, e1;
    logic [4:0] vert, c;
    e0 = dx - x;
    e1 = dy - y;
    vert = (e1 > 0) ? 5'b00010 : 5'b00001;
    c = 5'b00000;
    if (e0 == 0 && e1 == 0) return 5'b10000;
    if (e0 == 0)            return vert;
    if (e0 > 0) begin
        if (e1 == 0) return 5'b00100;
        if ((x % 2) == 1 || x == sx)  c |= vert;          // vertical allowed
        if ((dx % 2) == 1 || e0 != 1) c |= 5'b00100;      // East allowed
        return c;
    end
    c = 5'b01000;                                          // West always allowed
    if (e1 != 0 && (x % 2) == 0) c |= vert;
    return c;
endfunction

// SWITCH_POLICY = 1 (no-drain): mode 0 is the DETERMINISTIC ODD-EVEN route (oe_fixed), not XY.
// Set once by the base test from the DUT parameter.
bit hy_nodrain_policy = 0;
// DET_VARIANT (no-drain only): 0 = oe_fixed (v2), 2 = oe_x21 (v5: source column 2 -> destination column 1 goes vertical first), 1 = oe_par (v3): even-parity sources (x+y of the
// source) take the vertical port first wherever Odd-Even allows, the others use oe_fixed.
int hy_det_variant = 0;

// oe_fixed of rtl/route_compute.v written from its specification: of the Odd-Even
// candidates take Local, else East, else West, else the vertical one.
function automatic logic [4:0] hy_fixed_mask(logic [4:0] c);
    if (c[4]) return 5'b10000;
    if (c[2]) return 5'b00100;
    if (c[3]) return 5'b01000;
    return c;
endfunction

// oe_par of rtl/route_compute.v (v3) written from its specification
function automatic logic [4:0] hy_par_mask(logic [4:0] c, int src_x, int src_y);
    if (((src_x + src_y) % 2) == 0) begin
        if (c[4]) return 5'b10000;
        if (c[0] || c[1]) return c & 5'b00011;       // vertical first (N and S are never both set)
        return c;                                      // only a horizontal candidate is left
    end
    return hy_fixed_mask(c);
endfunction

// oe_x21 of rtl/route_compute.v (v5): oe_fixed, except source column 2 -> destination column 1
// takes the vertical port first (Local > vertical > horizontal)
function automatic logic [4:0] hy_x21_mask(logic [4:0] c, int src_x, int dst_x);
    if (src_x == 2 && dst_x == 1) begin
        if (c[4]) return 5'b10000;
        if (c[0] || c[1]) return c & 5'b00011;
        return c;
    end
    return hy_fixed_mask(c);
endfunction

// legal output set for a header at `router`, in `mode`
function automatic logic [4:0] hy_legal_mask(bit mode, int router, logic [15:0] hdr);
    int dst, src;
    logic [4:0] oe;
    dst = hy_hdr_dst(hdr);
    src = hy_hdr_src(hdr);
    oe  = hy_oe_mask(hy_x(router), hy_y(router), hy_x(src), hy_x(dst), hy_y(dst));
    if (mode)                 return oe;
    if (hy_nodrain_policy)    return (hy_det_variant == 2) ? hy_x21_mask(oe, hy_x(src), hy_x(dst)) : ((hy_det_variant == 1) ? hy_par_mask(oe, hy_x(src), hy_y(src)) : hy_fixed_mask(oe));
    return hy_xy_mask(hy_x(router), hy_y(router), hy_x(dst), hy_y(dst));
endfunction

// "" when a header leaving `router` through `port` is legal, otherwise a message
function automatic string hy_route_check(bit mode, int router, int port, logic [15:0] hdr);
    logic [4:0] m;
    m = hy_legal_mask(mode, router, hdr);
    if (port < 0 || port > 4) return $sformatf("bad port %0d", port);
    if (m[port]) return "";
    return $sformatf("router %0d (x=%0d,y=%0d) sent a header %0d->%0d out of port %0d in %s mode; legal ports mask %05b",
                     router, hy_x(router), hy_y(router), hy_hdr_src(hdr), hy_hdr_dst(hdr), port,
                     mode ? "ADAPT" : (hy_nodrain_policy ? ((hy_det_variant == 2) ? "OE-X21" : ((hy_det_variant == 1) ? "OE-PAR" : "OE-FIXED")) : "XY"), m);
endfunction
