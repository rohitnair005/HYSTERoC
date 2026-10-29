// =============================================================================
// tb_input_fifo.v : self-checking testbench for input_fifo (Verilog-2001)
//
// Method: a shift-register reference model (independent of the DUT's circular
// pointers) is compared with the DUT outputs at the start of every cycle, so
// every state reached after each clock edge is checked.
// Prints "TB_RESULT: PASS" or "TB_RESULT: FAIL (n errors)".
// =============================================================================
`timescale 1ns/1ps
`include "hysteroc_defs.vh"

module tb_input_fifo;

    localparam DATA_W = 16;
    localparam TYPE_W = 2;
    localparam DEPTH  = 4;

    reg                 clk;
    reg                 rst_n;
    reg                 push;
    reg  [DATA_W-1:0]   data_in;
    reg  [TYPE_W-1:0]   type_in;
    wire                ready_in;
    reg                 pop;
    wire [DATA_W-1:0]   data_out;
    wire [TYPE_W-1:0]   type_out;
    wire                valid_out;
    wire [2:0]          occupancy;

    input_fifo #(.DATA_W(DATA_W), .TYPE_W(TYPE_W), .PTR_W(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .push(push), .data_in(data_in), .type_in(type_in), .ready_in(ready_in),
        .pop(pop), .data_out(data_out), .type_out(type_out), .valid_out(valid_out),
        .occupancy(occupancy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    reg [DATA_W-1:0] m_data [0:DEPTH-1];
    reg [TYPE_W-1:0] m_type [0:DEPTH-1];
    integer          m_count;

    integer errors;
    integer checks;
    integer total_push_ok;
    integer total_pop_ok;
    integer max_seen_occ;
    integer saw_simul_pushpop;
    integer saw_full_pop_push;
    integer saw_ignored_push;
    integer saw_ignored_pop;
    integer i;
    integer          discarded;      // entries thrown away by resets

    task model_reset;
        begin
            discarded = discarded + m_count;
            m_count = 0;
        end
    endtask

    task fail;
        input [255:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("ERROR @%0t: %0s | model_count=%0d dut_occ=%0d valid=%b ready=%b data=%h type=%b",
                         $time, msg, m_count, occupancy, valid_out, ready_in, data_out, type_out);
        end
    endtask

    // Compare DUT outputs with the model (outputs depend only on registered state)
    task check_outputs;
        begin
            checks = checks + 1;
            if (occupancy !== m_count[2:0])               fail("occupancy mismatch");
            if (valid_out !== (m_count != 0))             fail("valid_out mismatch");
            if (ready_in  !== (m_count != DEPTH))         fail("ready_in mismatch (must be count!=4)");
            if (m_count != 0) begin
                if (data_out !== m_data[0])               fail("head data mismatch");
                if (type_out !== m_type[0])               fail("head type mismatch");
            end
            if (m_count > max_seen_occ) max_seen_occ = m_count;
        end
    endtask

    // One clock cycle: drive inputs, check pre-edge outputs, clock, update model.
    task step;
        input             p;
        input             q;
        input [DATA_W-1:0] d;
        input [TYPE_W-1:0] t;
        reg push_ok;
        reg pop_ok;
        begin
            push    = p;
            pop     = q;
            data_in = d;
            type_in = t;
            #1;                       // let combinational outputs settle
            check_outputs;
            // expectation using the model's pre-edge state (rule: ready_in ignores pop)
            push_ok = p && (m_count != DEPTH);
            pop_ok  = q && (m_count != 0);
            if (p && !push_ok) saw_ignored_push = saw_ignored_push + 1;
            if (q && !pop_ok)  saw_ignored_pop  = saw_ignored_pop + 1;
            if (push_ok && pop_ok) saw_simul_pushpop = saw_simul_pushpop + 1;
            if (p && q && m_count == DEPTH) saw_full_pop_push = saw_full_pop_push + 1;
            @(posedge clk);
            #1;
            // update model: pop first, then push (both decided from pre-edge state)
            if (pop_ok) begin
                for (i = 0; i < DEPTH-1; i = i + 1) begin
                    m_data[i] = m_data[i+1];
                    m_type[i] = m_type[i+1];
                end
                m_count = m_count - 1;
                total_pop_ok = total_pop_ok + 1;
            end
            if (push_ok) begin
                m_data[m_count] = d;
                m_type[m_count] = t;
                m_count = m_count + 1;
                total_push_ok = total_push_ok + 1;
            end
        end
    endtask

    task idle;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) step(1'b0, 1'b0, 16'h0, 2'b00);
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            // push/pop asserted during reset must be ignored
            push = 1'b1; pop = 1'b1; data_in = 16'hDEAD; type_in = 2'b11;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1'b1;
            push = 1'b0; pop = 1'b0;
            model_reset;
        end
    endtask

    // ---------------- random stimulus ----------------
    integer seed;
    integer r;
    integer phase;
    integer p_push;   // percent
    integer p_pop;    // percent
    reg [DATA_W-1:0] rd;
    reg [TYPE_W-1:0] rt;
    reg rp, rq;
    integer n;

    task random_phase;
        input integer cycles;
        input integer pp;
        input integer pq;
        integer c;
        begin
            for (c = 0; c < cycles; c = c + 1) begin
                r  = $random(seed); if (r < 0) r = -r;
                rp = ((r % 100) < pp);
                r  = $random(seed); if (r < 0) r = -r;
                rq = ((r % 100) < pq);
                rd = $random(seed);
                rt = $random(seed);
                step(rp, rq, rd, rt);
            end
        end
    endtask

    integer j;
    reg [15:0] stable_data;

    initial begin
        errors = 0; checks = 0; total_push_ok = 0; total_pop_ok = 0; max_seen_occ = 0;
        m_count = 0; discarded = 0;
        saw_simul_pushpop = 0; saw_full_pop_push = 0; saw_ignored_push = 0; saw_ignored_pop = 0;
        seed = 32'h1234ABCD;
        push = 0; pop = 0; data_in = 0; type_in = 0; rst_n = 1'b0;
        model_reset;
        do_reset;

        // ---- T1: state after reset ----
        idle(2);
        if (occupancy !== 3'd0 || valid_out !== 1'b0 || ready_in !== 1'b1) fail("T1 reset state");

        // ---- T2: fill to full, check ready_in drops only at 4 entries ----
        step(1,0,16'hA001,`HY_FT_HEADER);
        step(1,0,16'hA002,`HY_FT_BODY);
        step(1,0,16'hA003,`HY_FT_BODY);
        step(1,0,16'hA004,`HY_FT_TAIL);
        idle(1);
        if (occupancy !== 3'd4 || ready_in !== 1'b0 || valid_out !== 1'b1) fail("T2 not full after 4 pushes");

        // ---- T3: push while full is ignored (no overwrite) ----
        step(1,0,16'hBAD0,2'b11);
        step(1,0,16'hBAD1,2'b11);
        idle(1);
        if (occupancy !== 3'd4) fail("T3 occupancy changed on push-while-full");

        // ---- T4: full + pop + push same cycle: push must be refused (conservative) ----
        step(1,1,16'hBAD2,2'b11);        // pop A001 accepted, push refused
        idle(1);
        if (occupancy !== 3'd3) fail("T4 expected count 3 after pop with refused push");
        if (data_out !== 16'hA002) fail("T4 head should be A002");

        // ---- T5: stability of head while not popped ----
        stable_data = data_out;
        for (j = 0; j < 6; j = j + 1) begin
            step(0,0,16'h0,2'b00);
            if (data_out !== stable_data || valid_out !== 1'b1) fail("T5 head unstable");
        end

        // ---- T6: drain in order, then pop on empty ignored ----
        step(0,1,16'h0,2'b00);   // pops A002
        step(0,1,16'h0,2'b00);   // pops A003
        step(0,1,16'h0,2'b00);   // pops A004
        step(0,1,16'h0,2'b00);   // empty: ignored
        step(0,1,16'h0,2'b00);   // empty: ignored
        idle(1);
        if (occupancy !== 3'd0 || valid_out !== 1'b0) fail("T6 not empty / underflow corrupted state");

        // ---- T7: wraparound, 30 entries streamed through partially filled FIFO ----
        for (j = 0; j < 30; j = j + 1) begin
            step(1,0,16'h1000+j, j[1:0]);
            if (j >= 1) step(0,1,16'h0,2'b00);      // keep occupancy around 1
        end
        idle(2);

        // ---- T8: simultaneous push+pop at 1, 2, 3 entries ----
        model_reset; do_reset;
        step(1,0,16'h2001,2'b00);                    // count 1
        step(1,1,16'h2002,2'b01);                    // simul at 1
        step(1,0,16'h2003,2'b01);                    // count 2
        step(1,1,16'h2004,2'b10);                    // simul at 2
        step(1,0,16'h2005,2'b01);                    // count 3
        step(1,1,16'h2006,2'b01);                    // simul at 3 (not full, push accepted)
        idle(1);
        if (occupancy !== 3'd3) fail("T8 simul push/pop should keep count 3");

        // ---- T9: reset in the middle of activity (with push/pop asserted) ----
        do_reset;
        idle(2);
        if (occupancy !== 3'd0 || valid_out !== 1'b0 || ready_in !== 1'b1) fail("T9 reset did not clear");

        // ---- T10: random phases (full-biased, empty-biased, balanced, both-always) ----
        random_phase(20000, 90, 20);
        random_phase(20000, 20, 90);
        random_phase(40000, 50, 50);
        random_phase(20000, 100, 100);
        random_phase(20000, 70, 70);
        // mid-stream reset while busy, then continue
        do_reset;
        random_phase(40000, 60, 55);
        idle(6);

        // ---- summary / coverage of corner cases ----
        $display("INFO: cycles checked=%0d pushes_accepted=%0d pops_accepted=%0d max_occupancy=%0d",
                 checks, total_push_ok, total_pop_ok, max_seen_occ);
        $display("INFO: corner cases hit: simul_push_pop=%0d full+pop+push=%0d ignored_push=%0d ignored_pop=%0d",
                 saw_simul_pushpop, saw_full_pop_push, saw_ignored_push, saw_ignored_pop);
        if (max_seen_occ != DEPTH)        begin errors = errors + 1; $display("ERROR: never reached full"); end
        if (saw_simul_pushpop == 0)       begin errors = errors + 1; $display("ERROR: simultaneous push/pop never exercised"); end
        if (saw_full_pop_push == 0)       begin errors = errors + 1; $display("ERROR: full+pop+push never exercised"); end
        if (saw_ignored_push == 0)        begin errors = errors + 1; $display("ERROR: push-while-full never exercised"); end
        if (saw_ignored_pop == 0)         begin errors = errors + 1; $display("ERROR: pop-while-empty never exercised"); end
        $display("INFO: accepted pushes=%0d = accepted pops=%0d + left=%0d + discarded_by_reset=%0d",
                 total_push_ok, total_pop_ok, m_count, discarded);
        if (total_push_ok != total_pop_ok + m_count + discarded) begin
            errors = errors + 1;
            $display("ERROR: conservation violated (pushes != pops + left + discarded)");
        end

        if (errors == 0) $display("TB_RESULT: PASS");
        else             $display("TB_RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    // watchdog so a hang is reported instead of silently stalling
    initial begin
        #200000000;
        $display("TB_RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
