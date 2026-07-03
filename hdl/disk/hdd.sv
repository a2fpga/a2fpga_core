//
// Apple II ProDOS hard disk (block device) controller
//
// An AppleWin-style ProDOS HDD interface card (registers per AppleWin
// source/Harddisk.cpp), adapted for the A2FPGA multicard bus and the BL616
// track/block-serving model:
//
//   - The 6502 cannot be halted on a real Apple II bus, so commands are
//     asynchronous: reading EXECUTE ($C0s0) latches the command and sets
//     STATUS.b7 (busy); the driver ROM (hdd_rom.a65) polls STATUS until the
//     BL616 has serviced the block, then streams the data through the
//     NEXTBYTE port ($C0s8).
//   - Block data moves through a 512-byte dual-port sector buffer (BSRAM).
//     On READ, after the volume ack, the card prefetches the block from its
//     SDRAM window into the buffer; on WRITE the CPU fills the buffer first
//     and the card drains it to SDRAM before raising the volume request.
//   - Two ProDOS units (unit number bit 7 selects drive 1/2), each backed by
//     a drive_volume_if served by the BL616 (raw 512-byte blocks, LBA 1:1
//     into the image file). The SDRAM window for unit u is 512 bytes at
//     HDD_WORD_BASE + u*128 words.
//
// Registers (s = slot):
//   $C0s0 (r)   EXECUTE: latch+run command; resets buffer pointer
//   $C0s1 (r)   STATUS: b7 = busy, b0 = error
//   $C0s2 (r/w) COMMAND (0=status 1=read 2=write 3=format)
//   $C0s3 (r/w) UNIT NUMBER (b7 = drive select)
//   $C0s4 (r/w) MEMBLOCK low (stored only; used by the driver ROM)
//   $C0s5 (r/w) MEMBLOCK high
//   $C0s6 (r/w) BLOCK number low
//   $C0s7 (r/w) BLOCK number high
//   $C0s8 (r/w) NEXTBYTE: sector buffer, auto-incrementing pointer
//   $C0s9 (r)   unit size in blocks, low  (saturated to 16 bits)
//   $C0sA (r)   unit size in blocks, high
//   $C0sB (r)   ProDOS result code of last EXECUTE (0 = ok)
//

module HDD #(
    parameter bit [7:0] ID = 6,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,

    mem_port_if.client ram_hdd_if,

    drive_volume_if.drive volumes[2]
);

    // ProDOS result codes
    localparam [7:0] PRODOS_OK        = 8'h00;
    localparam [7:0] PRODOS_IO_ERROR  = 8'h27;
    localparam [7:0] PRODOS_NO_DEVICE = 8'h28;
    localparam [7:0] PRODOS_PROTECT   = 8'h2B;

    // -------------------------------------------------------------------
    // Card select (same conventions as DiskII in apple_disk.sv)
    // -------------------------------------------------------------------
    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0) begin
                card_enable <= 1'b0;
            end else if (slot_if.card_id == ID) begin
                card_enable <= slot_if.card_enable && ENABLE;
            end
        end
    end

    wire card_sel = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel = card_sel && !slot_if.dev_select_n;
    wire card_io_sel = card_sel && !slot_if.io_select_n;

    // Address-level device select (NOT phi0-gated). A 6502 STA abs,X performs
    // a false READ of the target address on the cycle before the write; the
    // address bus holds the same value across the pair, so this level stays
    // asserted through it. The sector-buffer auto-increment and the EXECUTE
    // trigger fire on THIS level's falling edge — once per instruction touch —
    // so the false read cannot double-step the pointer (MiSTer hdd semantics).
    wire card_dev_level = card_enable && (slot_if.card_id == ID) &&
                          !slot_if.dev_select_n;

    // -------------------------------------------------------------------
    // Interface registers
    // -------------------------------------------------------------------
    reg [7:0] command_r;
    reg [7:0] unitnum_r;
    reg [7:0] mem_l_r, mem_h_r;
    reg [7:0] block_l_r, block_h_r;

    reg       busy_r;
    reg       err_r;
    reg [7:0] result_r;

    reg [8:0] sec_addr_r;            // sector buffer pointer (0..511)
    reg       inc_sec_addr_r;        // pending auto-increment (applied when
                                     // the device access ends)
    reg       dev_sel_d_r;           // card_dev_sel delayed (edge detect)
    reg       exec_req_r;            // EXECUTE seen; trigger when access ends

    wire unit_w = unitnum_r[7];      // ProDOS unit: b7 = drive select

    // Selected unit's volume signals (interface arrays cannot be indexed
    // with a variable, so mux explicitly)
    wire        vol_mounted_w  = unit_w ? volumes[1].mounted  : volumes[0].mounted;
    wire        vol_readonly_w = unit_w ? volumes[1].readonly : volumes[0].readonly;
    wire        vol_ready_w    = unit_w ? volumes[1].ready    : volumes[0].ready;
    wire        vol_ack_w      = unit_w ? volumes[1].ack      : volumes[0].ack;
    wire [31:0] vol_size_w     = unit_w ? volumes[1].size     : volumes[0].size;
    // Size saturated to 16 bits (ProDOS volumes max out at 65535 blocks)
    wire [15:0] size16_w = (|vol_size_w[31:16]) ? 16'hFFFF : vol_size_w[15:0];

    reg vol_rd_r, vol_wr_r;          // request to the selected unit
    reg req_unit_r;                  // unit latched at EXECUTE time

    assign volumes[0].lba     = {16'b0, block_h_r, block_l_r};
    assign volumes[1].lba     = {16'b0, block_h_r, block_l_r};
    assign volumes[0].blk_cnt = 6'd0;   // always one 512-byte block
    assign volumes[1].blk_cnt = 6'd0;
    assign volumes[0].rd      = vol_rd_r & ~req_unit_r;
    assign volumes[1].rd      = vol_rd_r & req_unit_r;
    assign volumes[0].wr      = vol_wr_r & ~req_unit_r;
    assign volumes[1].wr      = vol_wr_r & req_unit_r;
    assign volumes[0].active  = busy_r & ~req_unit_r;
    assign volumes[1].active  = busy_r & req_unit_r;

    wire req_ack_w = req_unit_r ? volumes[1].ack : volumes[0].ack;

    // -------------------------------------------------------------------
    // 512-byte dual-port sector buffer
    //   port A: CPU (NEXTBYTE reads continuously, writes on $C0s8 stores)
    //   port B: FSM (fill on READ, drain on WRITE) -- only while busy
    // -------------------------------------------------------------------
    reg [7:0] buf_mem[0:511];
    reg [7:0] buf_cpu_q_r;
    reg [7:0] buf_fsm_q_r;

    wire       cpu_buf_wr_w = card_dev_sel && !a2bus_if.rw_n &&
                              (a2bus_if.addr[3:0] == 4'h8) && !busy_r;

    reg  [8:0] fsm_addr_r;
    reg  [7:0] fsm_wdata_r;
    reg        fsm_we_r;

    // NORMAL write mode (q holds during a write): Gowin DPB does not support
    // read-before-write (WRITE_MODE 2'b10), and neither port ever needs the
    // read value on a cycle it writes.
    always @(posedge a2bus_if.clk_logic) begin : buf_port_cpu
        if (cpu_buf_wr_w)
            buf_mem[sec_addr_r] <= a2bus_if.data;
        else
            buf_cpu_q_r <= buf_mem[sec_addr_r];
    end

    always @(posedge a2bus_if.clk_logic) begin : buf_port_fsm
        if (fsm_we_r)
            buf_mem[fsm_addr_r] <= fsm_wdata_r;
        else
            buf_fsm_q_r <= buf_mem[fsm_addr_r];
    end

    // -------------------------------------------------------------------
    // CPU register interface
    // -------------------------------------------------------------------
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : cpu_regs
        if (!a2bus_if.system_reset_n) begin
            command_r <= 8'h00;
            unitnum_r <= 8'h00;
            mem_l_r   <= 8'h00;
            mem_h_r   <= 8'h00;
            block_l_r <= 8'h00;
            block_h_r <= 8'h00;
            sec_addr_r <= 9'd0;
            inc_sec_addr_r <= 1'b0;
            exec_req_r <= 1'b0;
            dev_sel_d_r <= 1'b0;
        end else begin
            dev_sel_d_r <= card_dev_level;

            // Value/flag capture during the phi0 window of an access (data bus
            // valid). Repeated capture across the window is idempotent.
            if (card_dev_sel) begin
                if (!a2bus_if.rw_n) begin
                    case (a2bus_if.addr[3:0])
                        4'h2: begin
                            command_r  <= a2bus_if.data;
                            sec_addr_r <= 9'd0;
                        end
                        4'h3: unitnum_r <= a2bus_if.data;
                        4'h4: mem_l_r   <= a2bus_if.data;
                        4'h5: mem_h_r   <= a2bus_if.data;
                        4'h6: block_l_r <= a2bus_if.data;
                        4'h7: block_h_r <= a2bus_if.data;
                        4'h8: inc_sec_addr_r <= 1'b1;   // data written above
                        default: ;
                    endcase
                end else begin
                    case (a2bus_if.addr[3:0])
                        4'h0: exec_req_r <= 1'b1;       // trigger when touch ends
                        4'h8: inc_sec_addr_r <= 1'b1;
                        default: ;
                    endcase
                end
            end

            // Apply increment/trigger once, when the address-level select
            // falls (end of the instruction's touch, incl. false-read pairs)
            if (dev_sel_d_r && !card_dev_level) begin
                if (inc_sec_addr_r) begin
                    sec_addr_r <= 9'(sec_addr_r + 1'b1);
                    inc_sec_addr_r <= 1'b0;
                end
                if (exec_req_r) begin
                    exec_req_r <= 1'b0;
                    sec_addr_r <= 9'd0;
                end
            end
        end
    end

    // EXECUTE trigger, one clk_logic pulse after the CPU touch ends
    wire exec_pulse_w = ~card_dev_level & dev_sel_d_r & exec_req_r;

    // -------------------------------------------------------------------
    // Data out (valid through phi0 for CPU reads)
    // -------------------------------------------------------------------
    wire [7:0] rom_dout_w;
    reg  [7:0] dev_dout_w;

    always_comb begin
        case (a2bus_if.addr[3:0])
            4'h0: dev_dout_w = 8'h00;
            4'h1: dev_dout_w = {busy_r, 6'b0, err_r};
            4'h2: dev_dout_w = command_r;
            4'h3: dev_dout_w = unitnum_r;
            4'h4: dev_dout_w = mem_l_r;
            4'h5: dev_dout_w = mem_h_r;
            4'h6: dev_dout_w = block_l_r;
            4'h7: dev_dout_w = block_h_r;
            4'h8: dev_dout_w = buf_cpu_q_r;
            4'h9: dev_dout_w = size16_w[7:0];
            4'hA: dev_dout_w = size16_w[15:8];
            4'hB: dev_dout_w = result_r;
            default: dev_dout_w = 8'hFF;
        endcase
    end

    assign data_o  = card_io_sel ? rom_dout_w : dev_dout_w;
    assign rd_en_o = (card_io_sel | card_dev_sel) & a2bus_if.rw_n;

    // -------------------------------------------------------------------
    // Block service FSM (clk_logic)
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_RD_ACK,      // volume rd raised, wait for BL616 ack
        ST_FILL_ISSUE,  // issue SDRAM word read
        ST_FILL_WAIT,   // wait for word, store 4 bytes
        ST_DRAIN_PRIME, // 1 cycle: buffer BRAM read latency
        ST_DRAIN_READ,  // gather 4 buffer bytes into a word
        ST_DRAIN_ISSUE, // issue SDRAM word write
        ST_WR_ACK       // volume wr raised, wait for BL616 ack
    } state_t;

    state_t state_r;

    reg [6:0]  word_cnt_r;      // 128 words = 512 bytes
    reg [31:0] word_r;
    reg [1:0]  byte_cnt_r;
    reg [26:0] timeout_r;       // ~2.5s @ 54MHz: BL616 gone -> I/O error

    // SDRAM window: 128 words per unit at HDD_WORD_BASE (added by the arbiter)
    assign ram_hdd_if.addr    = {13'b0, req_unit_r, word_cnt_r};
    assign ram_hdd_if.data    = word_r;
    assign ram_hdd_if.byte_en = 4'b1111;
    assign ram_hdd_if.burst   = 1'b0;

    reg ram_rd_r, ram_wr_r;
    assign ram_hdd_if.rd = ram_rd_r;
    assign ram_hdd_if.wr = ram_wr_r;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : service
        if (!a2bus_if.system_reset_n) begin
            state_r    <= ST_IDLE;
            busy_r     <= 1'b0;
            err_r      <= 1'b0;
            result_r   <= 8'h00;
            vol_rd_r   <= 1'b0;
            vol_wr_r   <= 1'b0;
            req_unit_r <= 1'b0;
            ram_rd_r   <= 1'b0;
            ram_wr_r   <= 1'b0;
            fsm_we_r   <= 1'b0;
            word_cnt_r <= 7'd0;
            byte_cnt_r <= 2'd0;
            word_r     <= 32'b0;
            fsm_addr_r <= 9'd0;
            fsm_wdata_r <= 8'h00;
            timeout_r  <= 27'd0;
        end else begin
            ram_rd_r <= 1'b0;
            ram_wr_r <= 1'b0;
            fsm_we_r <= 1'b0;

            case (state_r)

                ST_IDLE: begin
                    if (exec_pulse_w) begin
                        req_unit_r <= unit_w;
                        timeout_r  <= 27'd0;
                        word_cnt_r <= 7'd0;
                        byte_cnt_r <= 2'd0;
                        case (command_r)
                            8'h00: begin   // STATUS: immediate
                                err_r    <= ~(vol_mounted_w & vol_ready_w);
                                result_r <= (vol_mounted_w & vol_ready_w) ?
                                            PRODOS_OK : PRODOS_NO_DEVICE;
                            end
                            8'h01: begin   // READ
                                if (!(vol_mounted_w & vol_ready_w)) begin
                                    err_r <= 1'b1; result_r <= PRODOS_NO_DEVICE;
                                end else begin
                                    busy_r   <= 1'b1;
                                    vol_rd_r <= 1'b1;
                                    state_r  <= ST_RD_ACK;
                                end
                            end
                            8'h02: begin   // WRITE (buffer already CPU-filled)
                                if (!(vol_mounted_w & vol_ready_w)) begin
                                    err_r <= 1'b1; result_r <= PRODOS_NO_DEVICE;
                                end else if (vol_readonly_w) begin
                                    err_r <= 1'b1; result_r <= PRODOS_PROTECT;
                                end else begin
                                    busy_r     <= 1'b1;
                                    fsm_addr_r <= 9'd0;
                                    state_r    <= ST_DRAIN_PRIME;
                                end
                            end
                            8'h03: begin   // FORMAT: accept as a no-op
                                if (!(vol_mounted_w & vol_ready_w)) begin
                                    err_r <= 1'b1; result_r <= PRODOS_NO_DEVICE;
                                end else if (vol_readonly_w) begin
                                    err_r <= 1'b1; result_r <= PRODOS_PROTECT;
                                end else begin
                                    err_r <= 1'b0; result_r <= PRODOS_OK;
                                end
                            end
                            default: begin
                                err_r <= 1'b1; result_r <= PRODOS_IO_ERROR;
                            end
                        endcase
                    end
                end

                // ---- READ: wait for the BL616 to load the block ----
                ST_RD_ACK: begin
                    timeout_r <= 27'(timeout_r + 1'b1);
                    if (req_ack_w) begin
                        vol_rd_r   <= 1'b0;
                        word_cnt_r <= 7'd0;
                        state_r    <= ST_FILL_ISSUE;
                    end else if (&timeout_r) begin
                        vol_rd_r <= 1'b0;
                        busy_r   <= 1'b0;
                        err_r    <= 1'b1;
                        result_r <= PRODOS_IO_ERROR;
                        state_r  <= ST_IDLE;
                    end
                end

                // ---- READ: prefetch SDRAM window -> sector buffer ----
                ST_FILL_ISSUE: begin
                    ram_rd_r <= 1'b1;
                    state_r  <= ST_FILL_WAIT;
                    byte_cnt_r <= 2'd0;
                end

                ST_FILL_WAIT: begin
                    if (ram_hdd_if.ready)
                        word_r <= ram_hdd_if.q[31:0];
                    // store the captured word one byte per cycle
                    if (ram_hdd_if.ready || byte_cnt_r != 2'd0) begin
                        fsm_addr_r  <= {word_cnt_r, byte_cnt_r};
                        fsm_wdata_r <= ram_hdd_if.ready ? ram_hdd_if.q[7:0]
                                       : word_r[{byte_cnt_r, 3'b0}+:8];
                        fsm_we_r    <= 1'b1;
                        byte_cnt_r  <= 2'(byte_cnt_r + 1'b1);
                        if (byte_cnt_r == 2'd3) begin
                            if (word_cnt_r == 7'd127) begin
                                busy_r   <= 1'b0;
                                err_r    <= 1'b0;
                                result_r <= PRODOS_OK;
                                state_r  <= ST_IDLE;
                            end else begin
                                word_cnt_r <= 7'(word_cnt_r + 1'b1);
                                state_r    <= ST_FILL_ISSUE;
                            end
                        end
                    end
                end

                // ---- WRITE: drain sector buffer -> SDRAM window ----
                // buf_fsm_q_r lags fsm_addr_r by one cycle: prime once, then
                // free-run the address one ahead of the byte being captured.
                ST_DRAIN_PRIME: begin
                    fsm_addr_r <= 9'(fsm_addr_r + 1'b1);
                    byte_cnt_r <= 2'd0;
                    state_r    <= ST_DRAIN_READ;
                end

                ST_DRAIN_READ: begin
                    // capture buf[{word_cnt, byte_cnt}] (addressed last cycle);
                    // hold the address through ISSUE on the last byte of a word
                    // so the next word's first byte is being read meanwhile
                    if (byte_cnt_r != 2'd3)
                        fsm_addr_r <= 9'(fsm_addr_r + 1'b1);
                    if (byte_cnt_r == 2'd0)
                        word_r[7:0]   <= buf_fsm_q_r;
                    else if (byte_cnt_r == 2'd1)
                        word_r[15:8]  <= buf_fsm_q_r;
                    else if (byte_cnt_r == 2'd2)
                        word_r[23:16] <= buf_fsm_q_r;
                    else
                        word_r[31:24] <= buf_fsm_q_r;
                    byte_cnt_r <= 2'(byte_cnt_r + 1'b1);
                    if (byte_cnt_r == 2'd3)
                        state_r <= ST_DRAIN_ISSUE;
                end

                ST_DRAIN_ISSUE: begin
                    ram_wr_r   <= 1'b1;
                    // step past the next word's byte 0 (being read this cycle)
                    // so q stays one byte ahead of the capture in DRAIN_READ
                    fsm_addr_r <= 9'(fsm_addr_r + 1'b1);
                    byte_cnt_r <= 2'd0;
                    if (word_cnt_r == 7'd127) begin
                        vol_wr_r  <= 1'b1;
                        timeout_r <= 27'd0;
                        state_r   <= ST_WR_ACK;
                    end else begin
                        word_cnt_r <= 7'(word_cnt_r + 1'b1);
                        state_r    <= ST_DRAIN_READ;
                    end
                end

                // ---- WRITE: wait for the BL616 to flush the block ----
                ST_WR_ACK: begin
                    timeout_r <= 27'(timeout_r + 1'b1);
                    if (req_ack_w) begin
                        vol_wr_r <= 1'b0;
                        busy_r   <= 1'b0;
                        err_r    <= 1'b0;
                        result_r <= PRODOS_OK;
                        state_r  <= ST_IDLE;
                    end else if (&timeout_r) begin
                        vol_wr_r <= 1'b0;
                        busy_r   <= 1'b0;
                        err_r    <= 1'b1;
                        result_r <= PRODOS_IO_ERROR;
                        state_r  <= ST_IDLE;
                    end
                end

                default: state_r <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // Driver/boot ROM at $Cn00 (assembled from hdd_rom.a65)
    // -------------------------------------------------------------------
    rom #(8, 8, "hdd_rom.hex") hddrom (
        .clock(a2bus_if.clk_logic),
        .ce(1'b1),
        .a(a2bus_if.addr[7:0]),
        .data_out(rom_dout_w)
    );

endmodule
