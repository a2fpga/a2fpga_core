// tb_hdd_block.sv — HDD card (hdl/disk/hdd.sv) block transfer bench.
//
// Drives the card the way the driver ROM (hdd_rom.a65) does: COMMAND, UNIT,
// MEMBLOCK, BLOCK, 512 NEXTBYTE stores, EXECUTE; then checks what the card
// drained into its memory window word by word. The 2026-11-13 field failure
// (BENCHMARKv5.2mg, GS/OS directory blocks landing shifted by one 32-bit
// word, word 0 stale) reproduces here on the pre-fix hdd.sv: the drain FSM
// advanced word_cnt_r in the same cycle it registered ram_wr, so word k was
// stored at word address k+1. The read path (window -> sector buffer ->
// NEXTBYTE) is checked the same way.
//
// Run: sim/disk/run.sh (Verilator --binary --timing).
`timescale 1ns / 1ps

module tb_hdd_block;

    localparam [7:0] CARD_ID = 8'd6;
    localparam [2:0] SLOT    = 3'd7;

    reg clk = 1'b0;
    always #9.26 clk = ~clk;          // 54 MHz

    a2bus_if a2bus_if ();
    slot_if  slot_if ();
    mem_port_if #(
        .PORT_ADDR_WIDTH(21), .DATA_WIDTH(32), .DQM_WIDTH(4), .PORT_OUTPUT_WIDTH(32)
    ) ram_if ();
    drive_volume_if volumes[2] ();

    wire [7:0] data_o;
    wire       rd_en_o;

    HDD #(.ID(CARD_ID), .ENABLE(1'b1)) dut (
        .a2bus_if(a2bus_if),
        .slot_if(slot_if),
        .data_o(data_o),
        .rd_en_o(rd_en_o),
        .ram_hdd_if(ram_if),
        .volumes(volumes),
        .storage_settled_i(1'b1)
    );

    // ---- bus interface defaults ------------------------------------------
    reg reset_n = 1'b0;
    assign a2bus_if.clk_logic      = clk;
    assign a2bus_if.clk_pixel      = clk;
    assign a2bus_if.system_reset_n = reset_n;
    assign a2bus_if.device_reset_n = reset_n;
    reg        phi0 = 1'b0;
    reg [15:0] addr = 16'h0000;
    reg        rw_n = 1'b1;
    reg [7:0]  data = 8'h00;
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
    assign a2bus_if.m2sel_n = 1'b1;
    assign a2bus_if.m2b0 = 1'b0;
    assign a2bus_if.data_in_strobe = 1'b0;
    assign a2bus_if.sw_gs = 1'b0;
    assign a2bus_if.extended_cycle = 1'b0;
    assign a2bus_if.control_inh_n = 1'b1;
    assign a2bus_if.control_irq_n = 1'b1;
    assign a2bus_if.control_rdy_n = 1'b1;
    assign a2bus_if.control_dma_n = 1'b1;
    assign a2bus_if.control_nmi_n = 1'b1;
    assign a2bus_if.control_reset_n = reset_n;

    reg        dev_select_n = 1'b1;
    reg        config_select_n = 1'b1;
    reg        card_enable = 1'b0;
    assign slot_if.slot            = SLOT;
    assign slot_if.card_id         = CARD_ID;
    assign slot_if.io_select_n     = 1'b1;
    assign slot_if.dev_select_n    = dev_select_n;
    assign slot_if.io_strobe_n     = 1'b1;
    assign slot_if.config_select_n = config_select_n;
    assign slot_if.card_config     = 32'd0;
    assign slot_if.card_enable     = card_enable;

    // ---- memory window model (the connector's SPACE 5 BSRAM / SDRAM port) --
    reg [31:0] win [0:255];
    reg [31:0] q_r;
    reg        ready_r;
    integer    wr_count;
    always @(posedge clk) begin
        ready_r <= ram_if.rd | ram_if.wr;
        if (ram_if.wr) begin
            win[ram_if.addr[7:0]] <= ram_if.data;
            wr_count = wr_count + 1;
        end
        if (ram_if.rd) q_r <= win[ram_if.addr[7:0]];
    end
    assign ram_if.q = q_r;
    assign ram_if.ready = ready_r;
    assign ram_if.available = 1'b1;

    // ---- volume model (the MCU side of drive_volume_if) ------------------
    reg ack0 = 1'b0, ack1 = 1'b0;
    integer vol_rd_seen = 0, vol_wr_seen = 0;
    assign volumes[0].ready = 1'b1;  assign volumes[1].ready = 1'b1;
    assign volumes[0].mounted = 1'b1; assign volumes[1].mounted = 1'b1;
    assign volumes[0].readonly = 1'b0; assign volumes[1].readonly = 1'b0;
    assign volumes[0].size = 32'd1600; assign volumes[1].size = 32'd1600;
    assign volumes[0].ack = ack0; assign volumes[1].ack = ack1;

    // MCU serves a request ~2 us after it appears (the drain must be complete
    // by then — the real firmware polls every 2 ms).
    always @(posedge clk) begin
        ack0 <= 1'b0;
        if (volumes[0].rd | volumes[0].wr) begin
            if (volumes[0].rd) vol_rd_seen = vol_rd_seen + 1;
            if (volumes[0].wr) vol_wr_seen = vol_wr_seen + 1;
            repeat (100) @(posedge clk);
            ack0 <= 1'b1;
            @(posedge clk);
            ack0 <= 1'b0;
        end
    end

    // ---- 6502 bus cycle emulation ----------------------------------------
    // One Apple cycle ~ 54 clk_logic ticks; the address and DEVICE SELECT are
    // valid across the whole cycle, phi0 high for the second half. Writes
    // present data during phi0. A read samples data_o at the end of phi0.
    task automatic cpu_write(input [3:0] reg_a, input [7:0] d);
        begin
            addr = 16'hC080 | {8'h00, SLOT, 1'b0, 4'h0} | {12'h0, reg_a};
            rw_n = 1'b0; data = d; dev_select_n = 1'b0;
            repeat (27) @(posedge clk);
            phi0 = 1'b1;
            repeat (27) @(posedge clk);
            phi0 = 1'b0;
            dev_select_n = 1'b1; rw_n = 1'b1; addr = 16'h0000;
            repeat (54) @(posedge clk);  // a non-card cycle
        end
    endtask

    task automatic cpu_read(input [3:0] reg_a, output [7:0] d);
        begin
            addr = 16'hC080 | {12'h0, reg_a};
            rw_n = 1'b1; dev_select_n = 1'b0;
            repeat (27) @(posedge clk);
            phi0 = 1'b1;
            repeat (26) @(posedge clk);
            d = data_o;
            @(posedge clk);
            phi0 = 1'b0;
            dev_select_n = 1'b1; addr = 16'h0000;
            repeat (54) @(posedge clk);
        end
    endtask

    // Test pattern: byte i of the block
    function automatic [7:0] pat(input integer i, input integer seed);
        pat = 8'(i) ^ 8'(i >> 8) ^ 8'(seed * 8'h5B);
    endfunction

    integer i, errors, pass_all;
    reg [7:0] st, rb;
    reg [31:0] expect_w;

    initial begin
        wr_count = 0;
        errors = 0; pass_all = 1;
        for (i = 0; i < 256; i = i + 1) win[i] = 32'hDEADBEEF;

        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        // slotmaker config sweep: enable this card
        card_enable = 1'b1; config_select_n = 1'b0;
        repeat (2) @(posedge clk);
        config_select_n = 1'b1;
        repeat (4) @(posedge clk);

        // =============== WRITE block 2, unit 0 ===============================
        cpu_write(4'h2, 8'h02);       // COMMAND = WRITE (resets buffer ptr)
        cpu_write(4'h3, 8'h00);       // UNIT
        cpu_write(4'h4, 8'h00);       // MEMBLOCK
        cpu_write(4'h5, 8'h20);
        cpu_write(4'h6, 8'h02);       // BLOCK = 2
        cpu_write(4'h7, 8'h00);
        for (i = 0; i < 512; i = i + 1)
            cpu_write(4'h8, pat(i, 1));
        cpu_read(4'h0, st);           // EXECUTE
        // poll STATUS until not busy
        i = 0;
        do begin cpu_read(4'h1, st); i = i + 1; end while (st[7] && i < 2000);
        if (st[7]) begin $display("FAIL: write never completed"); errors = errors + 1; end
        if (st[0]) begin $display("FAIL: write reported error"); errors = errors + 1; end
        if (vol_wr_seen != 1) begin $display("FAIL: vol wr requests = %0d", vol_wr_seen); errors = errors + 1; end
        if (volumes[0].lba != 32'd2) begin $display("FAIL: lba = %0d", volumes[0].lba); errors = errors + 1; end

        $display("write drained %0d words", wr_count);
        for (i = 0; i < 128; i = i + 1) begin
            expect_w = {pat(4*i+3, 1), pat(4*i+2, 1), pat(4*i+1, 1), pat(4*i, 1)};
            if (win[i] !== expect_w) begin
                if (errors < 8)
                    $display("FAIL: window word %0d = %08x, expected %08x%s", i, win[i], expect_w,
                             (i > 0 && win[i] === {pat(4*(i-1)+3, 1), pat(4*(i-1)+2, 1), pat(4*(i-1)+1, 1), pat(4*(i-1), 1)})
                             ? "  (= expected word of i-1: SHIFTED)" : "");
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("WRITE PATH: PASS (128 words in place)");
        else begin $display("WRITE PATH: FAIL (%0d words wrong)", errors); pass_all = 0; end

        // =============== READ block 7, unit 0 ================================
        errors = 0;
        for (i = 0; i < 128; i = i + 1)
            win[i] = {pat(4*i+3, 2), pat(4*i+2, 2), pat(4*i+1, 2), pat(4*i, 2)};
        cpu_write(4'h2, 8'h01);       // COMMAND = READ
        cpu_write(4'h3, 8'h00);
        cpu_write(4'h6, 8'h07);
        cpu_write(4'h7, 8'h00);
        cpu_read(4'h0, st);           // EXECUTE
        i = 0;
        do begin cpu_read(4'h1, st); i = i + 1; end while (st[7] && i < 2000);
        if (st[7]) begin $display("FAIL: read never completed"); errors = errors + 1; end
        if (st[0]) begin $display("FAIL: read reported error"); errors = errors + 1; end
        for (i = 0; i < 512; i = i + 1) begin
            cpu_read(4'h8, rb);
            if (rb !== pat(i, 2)) begin
                if (errors < 8) $display("FAIL: NEXTBYTE %0d = %02x, expected %02x", i, rb, pat(i, 2));
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("READ PATH: PASS (512 bytes in order)");
        else begin $display("READ PATH: FAIL (%0d bytes wrong)", errors); pass_all = 0; end

        // =============== second WRITE: stale word 0 must not survive =========
        // (block 9, different pattern) — guards the fix against leaving any
        // word unwritten.
        errors = 0;
        for (i = 0; i < 256; i = i + 1) win[i] = 32'hCAFEF00D;
        cpu_write(4'h2, 8'h02);
        cpu_write(4'h3, 8'h00);
        cpu_write(4'h6, 8'h09);
        cpu_write(4'h7, 8'h00);
        for (i = 0; i < 512; i = i + 1)
            cpu_write(4'h8, pat(i, 3));
        cpu_read(4'h0, st);
        i = 0;
        do begin cpu_read(4'h1, st); i = i + 1; end while (st[7] && i < 2000);
        for (i = 0; i < 128; i = i + 1) begin
            expect_w = {pat(4*i+3, 3), pat(4*i+2, 3), pat(4*i+1, 3), pat(4*i, 3)};
            if (win[i] !== expect_w) errors = errors + 1;
        end
        if (errors == 0) $display("WRITE PATH 2: PASS");
        else begin $display("WRITE PATH 2: FAIL (%0d words wrong)", errors); pass_all = 0; end

        $display("HDD BLOCK RESULT: %s", pass_all ? "PASS" : "FAIL");
        $finish;
    end

endmodule
