// Bench for the socket arm sequencer (gs_socket_arm_seq.sv): the S6 reset
// rule with "the last release of /RESET, whoever held it" as its reference.
// For Verilator --timing (see run_gs_arm_seq_sim.sh).
//
// The sequencer feeds the real socket PHY and a PHI2-clocked core (the S6
// arrangement), so the cases check what reaches the socket, not only the
// sequencer's output: before the arm point nothing is driven and the
// control-input shifter is off; after it the core starts on the machine's
// own clock.  The slot /RESET line is modelled as what it is - an open-drain
// net pulled low by any of several holders:
//
//   mb     the motherboard's power-on reset
//   card2  another card that keeps the line low after the motherboard lets go
//          (an a2p25 does until its disks are mounted)
//   adb    the ROM 01 machine's re-assert (the ADB micro's Control-Reset path)
//
// Cases, at real time scale (20 ms = 2 160 000 clks at 108 MHz):
//   A  motherboard alone: armed 20 ms after its release
//   B  card2 keeps holding for a long, variable time after the motherboard
//      releases (fixed values plus +nrand=N seeded random ones): armed 20 ms
//      after card2's release, never 20 ms after the motherboard's
//   C  the line is re-asserted INSIDE the 20 ms window (at the ROM 01 mark,
//      9.97 ms after the release, for 5 ms; and a 3 us glitch 100 us before
//      the end): the count starts again, armed 20 ms after the last release
//   D  a release that the request arrives late for (line high > 20 ms
//      already): passes at once
//   E  /RESET after arming: default = stays armed, the PHY holds the core in
//      reset and restarts it (S6); rearm = the socket is dropped and the
//      sequence runs again
//   F  seq_en = 0: the requests pass straight through (S6, firmware timing)
//
`timescale 1ns/1ps

module tb_gs_arm_seq;

    localparam real TCLK    = 9.260;          // 108 MHz (a whole number of ps per half period)
    localparam int  MS_CLKS = 108_000;
    localparam real T_MS    = TCLK * MS_CLKS; // the sequencer's millisecond, in ns
    localparam int  DELAY_MS = 20;

    logic clk = 1'b0;
    always #(TCLK/2.0) clk = ~clk;
    logic rst_n = 1'b0;

    // the machine's clock: PHI2 at ~2.86 MHz, running whenever it is powered
    logic ph2 = 1'b0;
    always begin #140.0 ph2 = 1'b1; #209.2 ph2 = 1'b0; end

    // the slot /RESET line
    logic mb_hold = 1'b1, card2_hold = 1'b0, adb_hold = 1'b0;
    wire  res_n_line = ~(mb_hold | card2_hold | adb_hold);

    // requests and configuration
    logic       seq_en = 1'b1, rearm = 1'b0, arm_req = 1'b0, listen_req = 1'b0;
    logic       arm_o, listen_o;
    logic [1:0] seq_state;
    logic [7:0] high_ms, restarts;

    gs_socket_arm_seq #(.MS_CLKS(MS_CLKS)) u_seq (
        .clk(clk), .rst_n(rst_n),
        .seq_en_i(seq_en), .rearm_i(rearm), .delay_ms_i(8'(DELAY_MS)),
        .arm_i(arm_req), .listen_i(listen_req), .res_n_i(res_n_line),
        .arm_o(arm_o), .listen_o(listen_o),
        .state_o(seq_state), .high_ms_o(high_ms), .restarts_o(restarts)
    );

    // S6 arrangement: PHY + PHI2-clocked core
    logic        cpu_clk, cpu_rst_n, cpu_we_n, cpu_vp_n, cpu_vpa, cpu_vda;
    logic [7:0]  cpu_d_out;
    logic [23:0] cpu_a;
    logic [7:0]  gs_d_o;
    logic        gs_d_oe, gs_rw, gs_vp, gs_d_dir, gs_data_oe_n, gs_addr_oe_n, gs_ctl_oe_n;
    logic [15:0] gs_a;
    logic        ph2_alive, running, enabled;
    logic [31:0] cycle_count;

    gs_socket_phy u_phy (
        .force_slow_i(1'b0),
        .clk(clk), .rst_n(rst_n), .armed_i(arm_o), .listen_i(listen_o), .out_extra_i(4'd0),
        .cpu_clk_o(cpu_clk), .cpu_rst_n_o(cpu_rst_n),
        .cpu_a_i(cpu_a), .cpu_d_out_i(cpu_d_out), .cpu_we_n_i(cpu_we_n), .cpu_vp_n_i(cpu_vp_n),
        .cpu_vpa_i(cpu_vpa), .cpu_vda_i(cpu_vda),
        .gs_ph2_i(ph2), .gs_rdy_i(1'b1), .gs_res_n_i(res_n_line), .gs_be_i(1'b1),
        .gs_d_o(gs_d_o), .gs_d_oe_o(gs_d_oe),
        .gs_a_o(gs_a), .gs_rw_o(gs_rw), .gs_vp_o(gs_vp), .gs_rdy_out_o(),
        .gs_d_dir_o(gs_d_dir), .gs_data_oe_n_o(gs_data_oe_n), .gs_addr_oe_n_o(gs_addr_oe_n),
        .gs_ctl_oe_n_o(gs_ctl_oe_n),
        .ph2_alive_o(ph2_alive), .running_o(running), .enabled_o(enabled), .be_ok_o(),
        .fall_evt_o(), .issue_evt_o(), .ended_read_o(),
        .cycle_count_o(cycle_count), .stall_count_o(), .be_count_o()
    );

    // a 64 KB machine: INC $0200 / JMP at the reset vector
    logic [7:0] mem [0:65535];
    P65C816 u_cpu (
        .CLK(cpu_clk), .RST_N(cpu_rst_n), .CE(1'b1), .RDY_IN(1'b1),
        .NMI_N(1'b1), .IRQ_N(1'b1), .ABORT_N(1'b1),
        .D_IN(mem[cpu_a[15:0]]), .D_OUT(cpu_d_out), .A_OUT(cpu_a), .WE(cpu_we_n), .RDY_OUT(),
        .VPA(cpu_vpa), .VDA(cpu_vda), .MLB(), .VPB(cpu_vp_n), .I_FLAG()
    );
    always @(posedge cpu_clk) if (cpu_rst_n && !cpu_we_n) mem[cpu_a[15:0]] <= cpu_d_out;

    //---------------------------------------------------------------- checks
    int  errors = 0;
    task automatic err(input string s);
        errors++;
        $display("[%0.3f ms] ERROR: %s", $realtime / 1.0e6, s);
    endtask

    wire socket_on = arm_o | listen_o | ~gs_addr_oe_n | ~gs_ctl_oe_n | ~gs_data_oe_n | gs_d_oe;

    bit  must_be_off = 1'b1;          // the socket must be completely off
    always @(posedge clk) if (rst_n && must_be_off && socket_on)
        err($sformatf("socket not off: arm %b listen %b addr_oe_n %b ctl_oe_n %b data_oe_n %b d_oe %b",
                      arm_o, listen_o, gs_addr_oe_n, gs_ctl_oe_n, gs_data_oe_n, gs_d_oe));
    // the core never runs while the sequencer holds the socket off (the PHY
    // takes up to two PHI2 cycles to stop it once the arm goes away)
    int arm_low_clks = 0;
    always @(posedge clk) begin
        if (arm_o || !seq_en) arm_low_clks = 0;
        else if (arm_low_clks < 1000) arm_low_clks++;
        if (rst_n && arm_low_clks >= 200 && running) err("core running without the arm");
    end

    real t_rel = 0, t_arm = 0, t_fall = 0;
    int  n_rel = 0, n_arm = 0;
    always @(posedge res_n_line) begin t_rel = $realtime; n_rel++; end
    always @(negedge res_n_line) t_fall = $realtime;
    always @(posedge arm_o) begin
        t_arm = $realtime; n_arm++;
        // the arm point: DELAY_MS after the last release (2 synchroniser clks + the edge)
        if (seq_en) begin
            if (!res_n_line) err("armed while /RESET is low");
            if (t_arm - t_rel < DELAY_MS * T_MS)
                err($sformatf("armed %.4f ms after the last release, less than %0d ms", (t_arm - t_rel) / 1.0e6, DELAY_MS));
        end
    end

    task automatic ms(input real t);
        #(t * 1.0e6);
    endtask

    // machine in reset, no request: the state every case starts from
    task automatic start_case(input string name);
        $display("[%0.3f ms] ---- case %s", $realtime / 1.0e6, name);
        must_be_off = 1'b0;
        arm_req = 1'b0; listen_req = 1'b0;
        mb_hold = 1'b1; card2_hold = 1'b0; adb_hold = 1'b0;
        ms(0.01);                     // the PHY lets go within a few clks
        if (socket_on) err("socket still on 10 us after the requests were dropped");
        must_be_off = 1'b1;
        ms(0.2);
        if (running) err("core still running at the start of a case");
    endtask

    // wait for the arm and check when it came and that the core started
    task automatic expect_arm(input string name, input real t_last_release);
        real     t0;
        longint  c0;
        logic [7:0] m0;
        t0 = $realtime;
        while (!arm_o && ($realtime - t0) < 60.0e6) @(posedge clk);
        if (!arm_o) begin err({name, ": never armed"}); return; end
        must_be_off = 1'b0;
        if (t_rel != t_last_release) err({name, ": the bench's idea of the last release is wrong"});
        if (t_arm - t_last_release > DELAY_MS * T_MS + 6 * TCLK)
            err($sformatf("%s: armed %.4f ms after the last release, more than %0d ms + 6 clks", name,
                          (t_arm - t_last_release) / 1.0e6, DELAY_MS));
        $display("[%0.3f ms]      armed %.5f ms after the last release of /RESET (%0d ms = %.5f ms of this clock)",
                 $realtime / 1.0e6, (t_arm - t_last_release) / 1.0e6, DELAY_MS, DELAY_MS * T_MS / 1.0e6);
        // the core starts on the machine's clock within a few cycles and runs the program
        c0 = cycle_count; m0 = mem[16'h0200];
        ms(0.05);
        if (!running) err({name, ": core not running 50 us after the arm"});
        if (gs_addr_oe_n || gs_ctl_oe_n) err({name, ": shifters not enabled after the arm"});
        if (cycle_count == c0 || mem[16'h0200] == m0) err({name, ": program not running after the arm"});
    endtask

    initial begin
        int  i, nrand, seed;
        real hold_ms [0:2] = '{3.3, 31.7, 137.9};
        real tr;

        for (i = 0; i < 65536; i++) mem[i] = 8'hEA;
        mem[16'hF000] = 8'hEE; mem[16'hF001] = 8'h00; mem[16'hF002] = 8'h02;    // INC $0200
        mem[16'hF003] = 8'h4C; mem[16'hF004] = 8'h00; mem[16'hF005] = 8'hF0;    // JMP $F000
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'hF0;
        mem[16'h0200] = 8'h00;
        nrand = 2; seed = 20261111;
        void'($value$plusargs("nrand=%d", nrand));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        if ($test$plusargs("vcd")) begin $dumpfile("gs_arm_seq.vcd"); $dumpvars(0, tb_gs_arm_seq); end

        #200 rst_n = 1'b1;

        // ---- A: the motherboard alone
        start_case("A: motherboard release, nobody else holding");
        arm_req = 1'b1; listen_req = 1'b1;       // the firmware asks as soon as the clock is up
        ms(5.0);
        mb_hold = 1'b0; tr = $realtime;
        expect_arm("A", tr);

        // ---- B: a second card keeps the line low after the motherboard lets go
        for (i = 0; i < 3 + nrand; i++) begin
            real h;
            h = (i < 3) ? hold_ms[i] : 0.5 + real'($urandom_range(0, 90000)) / 1000.0;
            start_case($sformatf("B%0d: second card holds /RESET %.3f ms after the motherboard releases", i, h));
            card2_hold = 1'b1;
            arm_req = 1'b1; listen_req = 1'b1;
            ms(3.0);
            mb_hold = 1'b0;                       // the machine's own release: the line stays low
            ms(h);
            if (arm_o) err("B: armed while the second card still holds /RESET");
            card2_hold = 1'b0; tr = $realtime;
            // 20 ms after the MOTHERBOARD's release must not arm it (when that falls before the real point)
            expect_arm($sformatf("B%0d", i), tr);
            if (t_arm < tr + DELAY_MS * T_MS) err("B: armed before 20 ms after the second card's release");
        end

        // ---- C1: the ROM 01 re-assert inside the window
        start_case("C1: /RESET re-asserted 9.97 ms after the release for 5 ms");
        arm_req = 1'b1; listen_req = 1'b1;
        ms(3.0);
        mb_hold = 1'b0;
        ms(9.97);
        adb_hold = 1'b1;
        ms(5.0);
        if (socket_on) err("C1: socket on during the re-assert");
        adb_hold = 1'b0; tr = $realtime;
        ms(DELAY_MS - 0.2);
        if (arm_o) err("C1: armed before 20 ms after the second release");
        expect_arm("C1", tr);
        if (restarts == 8'd0) err("C1: the restart was not counted");

        // ---- C2: a 3 us glitch 100 us before the end of the window
        start_case("C2: 3 us low glitch 100 us before the arm point");
        arm_req = 1'b1; listen_req = 1'b1;
        ms(3.0);
        mb_hold = 1'b0;
        ms(DELAY_MS - 0.1);
        adb_hold = 1'b1;
        #3000.0;
        adb_hold = 1'b0; tr = $realtime;
        ms(1.0);
        if (arm_o) err("C2: armed 1 ms after a glitch");
        expect_arm("C2", tr);

        // ---- D: the request arrives after the line has been high for a long time
        start_case("D: request arrives 30 ms after the release");
        ms(1.0);
        mb_hold = 1'b0; tr = $realtime;
        ms(30.0);
        if (socket_on) err("D: socket on with no request");
        must_be_off = 1'b0;
        arm_req = 1'b1; listen_req = 1'b1;
        ms(0.001);
        if (!arm_o) err("D: a request made 30 ms after the release did not pass at once");
        ms(0.05);
        if (!running) err("D: core not running");

        // ---- E1: /RESET after arming, default policy (S6): stays armed
        $display("[%0.3f ms] ---- case E1: /RESET pulse after arming, rearm off", $realtime / 1.0e6);
        begin
            logic [7:0] m0;
            adb_hold = 1'b1;
            ms(2.0);
            if (!arm_o) err("E1: the arm was dropped by a later /RESET (rearm is off)");
            if (running) err("E1: core running while /RESET is low");
            if (gs_addr_oe_n) err("E1: address shifters released during /RESET (S6 keeps the bus driven)");
            adb_hold = 1'b0;
            ms(0.05);
            m0 = mem[16'h0200];
            if (!running) err("E1: core did not restart after the release");
            ms(0.05);
            if (mem[16'h0200] == m0) err("E1: program not running after the release");
        end

        // ---- E2: /RESET after arming with rearm: socket dropped, sequence repeats
        $display("[%0.3f ms] ---- case E2: /RESET pulse after arming, rearm on", $realtime / 1.0e6);
        rearm = 1'b1;
        adb_hold = 1'b1;
        ms(0.001);
        if (arm_o) err("E2: arm not dropped within 1 us of the /RESET fall");
        ms(0.01);
        if (socket_on) err("E2: socket still on 10 us after the /RESET fall");
        must_be_off = 1'b1;
        ms(4.0);
        adb_hold = 1'b0; tr = $realtime;
        ms(DELAY_MS - 0.2);
        if (arm_o) err("E2: re-armed early");
        expect_arm("E2", tr);
        rearm = 1'b0;

        // ---- F: bypass (S6: the firmware does the timing)
        start_case("F: seq_en = 0, requests pass straight through");
        must_be_off = 1'b0;
        seq_en = 1'b0;
        listen_req = 1'b1;
        #1.0;
        if (!listen_o || arm_o) err("F: listen did not pass straight through");
        arm_req = 1'b1;
        #1.0;
        if (!arm_o) err("F: arm did not pass straight through with /RESET low");
        seq_en = 1'b1;
        #1.0;
        if (arm_o || listen_o) err("F: sequencing back on with /RESET low: requests must be withheld");

        $display("---- gs_arm_seq: %0d releases of /RESET, %0d arms, %0d count restarts", n_rel, n_arm, restarts);
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #(2.0e9);
        $display("TIMEOUT"); $display("FAIL: timeout"); $finish;
    end

endmodule
