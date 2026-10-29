// =============================================================================
// tb_route_dump.v : OPTIONAL helper. Prints the RTL result for all 1024 inputs in
// the same format as `python3 scripts/cdg_check.py --dump`, so the RTL and the
// Python reference model can be compared with a plain text diff.
// Line format: "x y src_x dst_x dst_y xy_mask_hex oe_mask_hex"
// Not needed for normal simulation.
// =============================================================================
`timescale 1ns/1ps

module tb_route_dump;
    reg  [1:0] x, y, dst_x, dst_y, src_x;
    wire [4:0] xy_port, oe_cand;
    route_compute dut (.x(x), .y(y), .dst_x(dst_x), .dst_y(dst_y), .src_x(src_x),
                       .xy_port(xy_port), .oe_cand(oe_cand));
    integer ix, iy, isx, idx, idy;
    initial begin
        for (ix = 0; ix < 4; ix = ix + 1)
         for (iy = 0; iy < 4; iy = iy + 1)
          for (isx = 0; isx < 4; isx = isx + 1)
           for (idx = 0; idx < 4; idx = idx + 1)
            for (idy = 0; idy < 4; idy = idy + 1) begin
                x = ix; y = iy; src_x = isx; dst_x = idx; dst_y = idy;
                #1;
                $display("%0d %0d %0d %0d %0d %02x %02x", ix, iy, isx, idx, idy, xy_port, oe_cand);
            end
        $finish;
    end
endmodule
