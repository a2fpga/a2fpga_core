// tb_uthernet2.sv : Uthernet II card (hdl/uthernet2/uthernet2.sv) on an
// Apple II bus whose data strobe lands EARLY in phi0, as the a2p25/a2mega bus
// module raises it (~15 of 27 ticks), with the CPU latching read data at the
// END of phi0. The 2026-11-17 defect: the indirect address auto-incremented at
// the strobe, so every data-port read returned the byte AFTER the one
// addressed (IP65 "No device found" on the a2p25).
//
// Checks, each with a single strobe and with two strobes per cycle:
//   1. IP65's probe: MR |= 03, addr 0017, two data reads -> 07 D0 (the RTR
//      seeded through the host port), and read data is constant across phi0.
//   2. Write path with auto-increment: six bytes at 0009, read back through
//      the Apple side and the host side.
//   3. Doorbell: write 01 to 0401 raises cmd_pending[0]; clear drops it.
//   4. MR without AI: two reads of the data port return the same byte.
//   5. MR RST: reads back 00, address pointer back at 0000.
// Run: sim/uthernet2/run.sh
`timescale 1ns/1ps
module tb_uthernet2;
    localparam [7:0] CARD_ID = 8'd5;
    localparam [2:0] SLOT    = 3'd3;
    localparam int   STROBE_TICK = 15;   // a2mega apple_bus DATA_COUNT
    localparam int   PHI0_TICKS  = 27;

    reg clk = 1'b0;
    always #9.26 clk = ~clk;          // 54 MHz

    a2bus_if a2bus_if ();
    slot_if  slot_if ();

    wire [7:0] data_o;
    wire       rd_en_o, irq_n_o;
    reg        host_wr = 1'b0;
    reg [15:0] host_addr = 16'h0;
    reg [7:0]  host_wdata = 8'h0;
    wire [7:0] host_rdata;
    wire [3:0] cmd_pending;
    reg  [3:0] cmd_clr = 4'b0;

    Uthernet2 #(.ID(CARD_ID), .ENABLE(1'b1)) dut (
        .a2bus_if(a2bus_if), .slot_if(slot_if),
        .data_o(data_o), .rd_en_o(rd_en_o), .irq_n_o(irq_n_o),
        .w5100_host_wr(host_wr), .w5100_host_addr(host_addr),
        .w5100_host_wdata(host_wdata), .w5100_host_rdata(host_rdata),
        .cmd_pending_o(cmd_pending), .cmd_pending_clr(cmd_clr),
        .dbg_portb_wr_count(), .dbg_portb_last_addr(), .dbg_portb_last_wdata()
    );

    // ---- bus interface defaults ------------------------------------------
    reg reset_n = 1'b0;
    reg        phi0 = 1'b0;
    reg [15:0] addr = 16'h0;
    reg        rw_n = 1'b1;
    reg [7:0]  data = 8'h0;
    reg        strobe = 1'b0;
    reg        dev_select_n = 1'b1;
    reg        config_select_n = 1'b1;
    reg        card_enable = 1'b0;
    assign a2bus_if.clk_logic      = clk;
    assign a2bus_if.clk_pixel      = clk;
    assign a2bus_if.system_reset_n = reset_n;
    assign a2bus_if.device_reset_n = reset_n;
    assign a2bus_if.phi0 = phi0;
    assign a2bus_if.phi1 = ~phi0;
    assign a2bus_if.addr = addr;
    assign a2bus_if.rw_n = rw_n;
    assign a2bus_if.data = data;
    assign a2bus_if.phi0_posedge = 1'b0;
    assign a2bus_if.phi0_negedge = 1'b0;
    assign a2bus_if.phi1_posedge = 1'b0;
    assign a2bus_if.phi1_negedge = 1'b0;
    assign a2bus_if.clk_q3 = 1'b0;
    assign a2bus_if.clk_q3_posedge = 1'b0;
    assign a2bus_if.clk_q3_negedge = 1'b0;
    assign a2bus_if.clk_7M = 1'b0;
    assign a2bus_if.clk_7M_posedge = 1'b0;
    assign a2bus_if.clk_7M_negedge = 1'b0;
    assign a2bus_if.clk_14M_posedge = 1'b0;
    assign a2bus_if.m2sel_n = 1'b0;
    assign a2bus_if.m2b0 = 1'b0;
    assign a2bus_if.data_in_strobe = strobe;
    assign a2bus_if.sw_gs = 1'b1;
    assign a2bus_if.extended_cycle = 1'b0;
    assign a2bus_if.control_inh_n = 1'b1;
    assign a2bus_if.control_irq_n = 1'b1;
    assign a2bus_if.control_rdy_n = 1'b1;
    assign a2bus_if.control_dma_n = 1'b1;
    assign a2bus_if.control_nmi_n = 1'b1;
    assign a2bus_if.control_reset_n = reset_n;
    assign slot_if.slot            = SLOT;
    assign slot_if.card_id         = CARD_ID;
    assign slot_if.io_select_n     = 1'b1;
    assign slot_if.dev_select_n    = dev_select_n;
    assign slot_if.io_strobe_n     = 1'b1;
    assign slot_if.config_select_n = config_select_n;
    assign slot_if.card_config     = 32'd0;
    assign slot_if.card_enable     = card_enable;

    integer errors = 0;
    bit double_strobe = 0;

    // ---- host (ESP32 / SPACE 3) port ---------------------------------------
    task automatic host_write(input [15:0] a, input [7:0] d);
        begin
            @(posedge clk); host_addr = a; host_wdata = d; host_wr = 1'b1;
            @(posedge clk); host_wr = 1'b0;
            @(posedge clk);
        end
    endtask
    task automatic host_read(input [15:0] a, output [7:0] d);
        begin
            @(posedge clk); host_addr = a; host_wr = 1'b0;
            @(posedge clk); @(posedge clk); #1 d = host_rdata;
        end
    endtask

    // ---- 6502/65816 bus cycle: strobe at STROBE_TICK, CPU latches at the end --
    task automatic bus_cycle(input [3:0] reg_a, input wr, input [7:0] wd, output [7:0] rd, output bit stable);
        reg [7:0] first;
        integer t;
        begin
            addr = 16'hC080 | {12'h0, SLOT, 4'h0} | {12'h0, reg_a};
            rw_n = !wr; data = wr ? wd : 8'hxx; dev_select_n = 1'b0;
            repeat (PHI0_TICKS) @(posedge clk);
            phi0 = 1'b1; stable = 1;
            for (t = 0; t < PHI0_TICKS; t++) begin
                @(posedge clk);
                strobe <= (t == STROBE_TICK) || (double_strobe && t == STROBE_TICK + 5);
                #1;
                if (!wr) begin
                    if (t == 3) first = data_o;
                    else if (t > 3 && data_o !== first) stable = 0;
                end
            end
            #1 rd = data_o;                 // end of phi0: the CPU's latch point
            strobe <= 1'b0;
            @(posedge clk);
            phi0 = 1'b0; dev_select_n = 1'b1; rw_n = 1'b1; addr = 16'h0; data = 8'h0;
            repeat (PHI0_TICKS * 2) @(posedge clk);
        end
    endtask
    task automatic cpu_write(input [3:0] r, input [7:0] d);
        reg [7:0] x; bit s; begin bus_cycle(r, 1, d, x, s); end
    endtask
    task automatic cpu_read(input [3:0] r, output [7:0] d);
        bit s; begin bus_cycle(r, 0, 8'h0, d, s);
            if (!s) begin $display("FAIL: read of reg %0d changed during phi0", r); errors++; end
        end
    endtask
    task automatic set_addr(input [15:0] a);
        begin cpu_write(4'h5, a[15:8]); cpu_write(4'h6, a[7:0]); end
    endtask
    task automatic expect8(input string what, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin $display("FAIL: %s = %02x, expected %02x", what, got, exp); errors++; end
        end
    endtask

    task automatic run_suite(input string name);
        reg [7:0] b, b2; integer i;
        begin
            $display("--- %s ---", name);
            // 1. IP65 probe
            cpu_read(4'h4, b); cpu_write(4'h4, b | 8'h03);
            cpu_read(4'h4, b); expect8("MR after |03", b, 8'h03);
            set_addr(16'h0017);
            cpu_read(4'h7, b);  expect8("RTR hi", b, 8'h07);
            cpu_read(4'h7, b2); expect8("RTR lo", b2, 8'hD0);
            cpu_read(4'h7, b);  expect8("RCR", b, 8'h08);
            cpu_read(4'h7, b);  expect8("RMSR", b, 8'h55);
            cpu_read(4'h5, b); cpu_read(4'h6, b2);
            expect8("addr hi after 4 reads", b, 8'h00); expect8("addr lo after 4 reads", b2, 8'h1B);
            // 2. write path
            set_addr(16'h0009);
            for (i = 0; i < 6; i++) cpu_write(4'h7, 8'hA0 + i[7:0]);
            set_addr(16'h0009);
            for (i = 0; i < 6; i++) begin cpu_read(4'h7, b); expect8($sformatf("MAC[%0d] via Apple", i), b, 8'hA0 + i[7:0]); end
            for (i = 0; i < 6; i++) begin host_read(16'h0009 + i[15:0], b); expect8($sformatf("MAC[%0d] via host", i), b, 8'hA0 + i[7:0]); end
            // 3. doorbell
            set_addr(16'h0401); cpu_write(4'h7, 8'h01);
            repeat (4) @(posedge clk);
            if (cmd_pending !== 4'b0001) begin $display("FAIL: doorbell = %b", cmd_pending); errors++; end
            cmd_clr = 4'b0001; @(posedge clk); cmd_clr = 4'b0; repeat (2) @(posedge clk);
            if (cmd_pending !== 4'b0000) begin $display("FAIL: doorbell not cleared"); errors++; end
            // 4. no auto-increment
            cpu_write(4'h4, 8'h01); set_addr(16'h0017);
            cpu_read(4'h7, b); cpu_read(4'h7, b2);
            expect8("no-AI read 1", b, 8'h07); expect8("no-AI read 2", b2, 8'h07);
            // 5. reset
            cpu_write(4'h4, 8'h80);
            cpu_read(4'h4, b); expect8("MR after RST", b, 8'h00);
            cpu_read(4'h5, b); cpu_read(4'h6, b2);
            expect8("addr hi after RST", b, 8'h00); expect8("addr lo after RST", b2, 8'h00);
        end
    endtask

    reg [7:0] v;
    initial begin
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);
        card_enable = 1'b1; config_select_n = 1'b0;
        repeat (2) @(posedge clk);
        config_select_n = 1'b1;
        repeat (4) @(posedge clk);

        // host seeds the W5100 reset defaults (w5100.c W5100_DEFAULTS)
        host_write(16'h0017, 8'h07); host_write(16'h0018, 8'hD0);
        host_write(16'h0019, 8'h08); host_write(16'h001A, 8'h55);
        host_write(16'h001B, 8'h55); host_write(16'h0028, 8'h28);
        host_read(16'h0017, v); expect8("host read-back RTR hi", v, 8'h07);

        double_strobe = 0; run_suite("single strobe at tick 15");
        double_strobe = 1; run_suite("two strobes per cycle (15, 20)");

        if (errors == 0) $display("UTHERNET2 RESULT: PASS");
        else $display("UTHERNET2 RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
