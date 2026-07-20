// BL616 SPI Connector -- 128-register file with SDRAM bridge and PicoSOC peripherals
// Adapted from esp32_spi_connector.sv
//
// Replaces PicoSOC by exposing all peripheral control via SPI registers
// and providing SDRAM access via the XFER portal.
module bl616_spi_connector #(
    parameter USE_CRC        = 0,
    parameter CLOCK_SPEED_HZ = 54_000_000,
    // Standalone fallback: if no BL616 is detected (mcu_ready never latches)
    // within STANDALONE_TIMEOUT cycles after reset, release the Apple bus
    // anyway so the card works without the MCU firmware running.
    parameter bit STANDALONE_FALLBACK_ENABLE = 1,
    // 14-char build timestamp (YYYYMMDDHHMMSS), readable via reg 0x3F:
    // write 0x3F = digit index (0-13), read 0x3F = ASCII digit.
    // (0x7F is OFF-LIMITS: it is the XFER opcode in the SPI protocol.)
    parameter [8*14-1:0] VERSION_STR = "00000000000000"
)(
    input  wire clk,
    input  wire rst_n,

    // 6551 control reg (baud in [3:0]) for reg 0x2F (SSC bridge)
    input  wire [7:0] ssc_ctl_i,

    // SPI pins
    input  wire spi_cs_n,
    input  wire spi_sclk,
    input  wire spi_mosi,
    output wire spi_miso,

    // A2 bus interfaces
    a2bus_if.slave          a2bus_if,
    a2mem_if.slave          a2mem_if,
    a2bus_control_if.control a2bus_control_if,
    video_control_if.control video_control_if,
    slotmaker_config_if.controller slotmaker_config_if,

    // Drive volumes (Disk II floppies)
    drive_volume_if.volume  volumes[2],

    // ProDOS HDD block-device volumes (compact regs 0x26-0x2D)
    drive_volume_if.volume  hdd_volumes[2],

    // SDRAM port
    mem_port_if.client      mem_if,

    // System status
    input  wire        sdram_init_complete_i,
    output wire        mcu_ready_o,
    output wire        standalone_o,   // high once standalone fallback engages (no BL616)
    output wire        mcu_access_stb_o, // pulses on any MCU register transaction (liveness watchdog feed)
    output wire [39:0] scratch_o,      // 5 MCU scratch regs packed {s4,s3,s2,s1,s0} (0x07,0x0C-0x0F)

    // CardROM
    input  wire        cardrom_active_i,
    output wire        cardrom_release_o,

    // GPIO
    input  wire        button_i,
    output reg  [4:0]  led_o,
    output reg         ws2812_o,

    // SD card pins
    output wire        sd_clk_o,
    output wire        sd_cmd_o,      // MOSI
    input  wire        sd_dat0_i,     // MISO
    output wire        sd_dat3_o,     // CS#

    // Bus event FIFO interface
    input  wire        fifo_empty,
    input  wire        fifo_full,
    input  wire [8:0]  fifo_count,
    input  wire [31:0] fifo_rdata,
    output wire        fifo_pop,
    output reg  [2:0]  capture_mode_o,
    output reg         capture_enable_o,
    output reg         oneshot_o,
    output reg         trig_enable_o,
    output reg  [15:0] trig_addr_o,
    output reg  [15:0] trig_mask_o,
    input  wire        trig_matched_i,

    // Uthernet2 (W5100) backing store -- SPI memory SPACE 3 (port B of the card)
    output wire        w5100_host_wr,
    output wire [15:0] w5100_host_addr,    // W5100 address (0x0000-0x7FFF)
    output wire [7:0]  w5100_host_wdata,
    input  wire [7:0]  w5100_host_rdata,
    input  wire [3:0]  w5100_cmd_pending,  // doorbell bits from the card (reg 0x7A)
    output wire [3:0]  w5100_cmd_clr,      // write-1-to-clear (reg 0x7A write)

    // DEBUG: port-B (SPACE 3) write instrumentation from the card (regs 0x7B-0x7E)
    input  wire [15:0] w5100_dbg_wr_count,
    input  wire [15:0] w5100_dbg_last_addr,
    input  wire [7:0]  w5100_dbg_last_wdata
);

    // -------------------------------------------------------
    // Proto processor wires
    // -------------------------------------------------------
    wire        reg_rd_req;
    wire        reg_wr_req;
    wire [6:0]  reg_idx;
    wire [7:0]  reg_wdata;
    reg  [7:0]  reg_rdata;
    reg  [3:0]  ver_idx_r = 4'd0;   // reg 0x7F: version digit index

    wire        mem_wr_en;
    wire [2:0]  mem_space;
    wire [23:0] mem_wr_addr;
    wire [7:0]  mem_wr_data;

    wire        mem_rd_req;
    wire [2:0]  mem_rd_space;
    wire [23:0] mem_rd_addr;
    reg         mem_rd_valid;
    reg  [7:0]  mem_rd_data;

    // -------------------------------------------------------
    // Instantiate proto processor
    // -------------------------------------------------------
    bl616_spi_proto_proc #(
        .USE_CRC(USE_CRC)
    ) proto (
        .clk(clk),
        .rst_n(rst_n),
        .spi_cs_n(spi_cs_n),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .reg_rd_req(reg_rd_req),
        .reg_wr_req(reg_wr_req),
        .reg_idx(reg_idx),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .mem_wr_en(mem_wr_en),
        .mem_space(mem_space),
        .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data),
        .mem_rd_req(mem_rd_req),
        .mem_rd_space(mem_rd_space),
        .mem_rd_addr(mem_rd_addr),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_data(mem_rd_data)
    );

    // -------------------------------------------------------
    // MCU ready detection -- latches on first STATUS register read
    // -------------------------------------------------------
    // MCU-alive latch. Historically this required a read of STATUS (0x06),
    // but the protocol processor answers status reads from its internal
    // fast path without pulsing reg_rd_req — so the latch never fired, the
    // standalone fallback engaged on every boot, and (critically) the
    // "MCU absent" reset escape released the Apple II at 3 s regardless of
    // whether storage was mounted — the cold-boot half-booted-garbage bug.
    // Any register transaction proves the MCU is alive (the firmware
    // writes debug scratch registers within milliseconds of boot).
    reg mcu_ready_r;
    assign mcu_ready_o = mcu_ready_r;
    // Same "any transaction proves the MCU is alive" signal, but continuous:
    // feeds the FPGA-side liveness watchdog (mcu_status_led) that turns the
    // WS2812 blinking red when the firmware goes silent (wedged update, dead
    // app region). Status fast-path reads don't pulse these (see above), but
    // disk_poll's data-register reads every ~2 ms do.
    assign mcu_access_stb_o = reg_rd_req || reg_wr_req;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mcu_ready_r <= 1'b0;
        else if (reg_rd_req || reg_wr_req)
            mcu_ready_r <= 1'b1;
    end

    // -------------------------------------------------------
    // Standalone fallback -- engage the Apple bus without the MCU
    //
    // On some Tang Nano 20K boards our BL616 firmware only loads as a
    // 2nd-stage bootloader when no PC is attached to the BL616 USB port, so it
    // may never run. A present BL616 is ready long before FPGA configuration
    // completes and reads the STATUS register (mcu_ready_r) almost immediately.
    // So if we have not seen the MCU within STANDALONE_TIMEOUT cycles after
    // reset, assume there is none and release the Apple bus ourselves. If the
    // MCU shows up first, we defer to it (standalone never engages).
    // -------------------------------------------------------
    localparam STANDALONE_TIMEOUT = CLOCK_SPEED_HZ / 10;  // ~100 ms
    localparam SA_CW = $clog2(STANDALONE_TIMEOUT + 1);
    reg standalone_r;
    reg [SA_CW-1:0] standalone_cnt_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            standalone_r <= 1'b0;
            standalone_cnt_r <= '0;
        end else if (STANDALONE_FALLBACK_ENABLE && !standalone_r && !mcu_ready_r) begin
            if (standalone_cnt_r >= STANDALONE_TIMEOUT[SA_CW-1:0])
                standalone_r <= 1'b1;
            else
                standalone_cnt_r <= standalone_cnt_r + 1'b1;
        end
    end
    assign standalone_o = standalone_r;

    // -------------------------------------------------------
    // Apple II reset hold/release policy
    // -------------------------------------------------------
    // Hold the Apple II in RESET from power-on so the MCU can bring up USB
    // storage before the autoboot slot scan runs (otherwise the HDD/floppy
    // volumes are not mounted yet and the scan races past them). Release when:
    //   - the MCU writes A2_RST_RELEASE (0x2E) after its mounts complete, or
    //   - no MCU shows up on SPI within MCU_ALIVE_WAIT (standalone Apple), or
    //   - the absolute backstop expires (MCU alive but never released).
    localparam RST_MCU_ALIVE_WAIT = CLOCK_SPEED_HZ * 3;   // MCU first SPI contact
    localparam RST_HOLD_BACKSTOP  = CLOCK_SPEED_HZ * 15;  // never hold forever
    localparam RST_CW = $clog2(RST_HOLD_BACKSTOP + 1);
    reg               a2_rst_release_r;   // set by reg 0x2E write
    reg [RST_CW-1:0]  rst_hold_cnt_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_hold_cnt_r <= '0;
        else if (rst_hold_cnt_r < RST_HOLD_BACKSTOP[RST_CW-1:0])
            rst_hold_cnt_r <= rst_hold_cnt_r + 1'b1;
    end
    wire rst_mcu_absent_w = !mcu_ready_r &&
                            (rst_hold_cnt_r >= RST_MCU_ALIVE_WAIT[RST_CW-1:0]);
    assign a2bus_control_if.reset_hold =
        !(a2_rst_release_r || rst_mcu_absent_w ||
          rst_hold_cnt_r >= RST_HOLD_BACKSTOP[RST_CW-1:0]);

    // -------------------------------------------------------
    // Constants
    // -------------------------------------------------------
    localparam [7:0] DEVICE_ID0 = "A";
    localparam [7:0] DEVICE_ID1 = "2";
    localparam [7:0] DEVICE_ID2 = "F";
    localparam [7:0] DEVICE_ID3 = "P";
    localparam [7:0] PROTO_VER  = 8'h01;
    wire [7:0] CAP0 = {6'b0, USE_CRC[0], 1'b1};

    // -------------------------------------------------------
    // System timer
    // -------------------------------------------------------
    reg [31:0] sys_time_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sys_time_r <= 32'd0;
        else sys_time_r <= sys_time_r + 32'd1;
    end

    // -------------------------------------------------------
    // Peripheral registers
    // -------------------------------------------------------

    // Scratch registers
    reg [7:0] scratch_r [0:4]; // scratch0..scratch4
    // Packed export so top-level (e.g. DebugOverlay) can read MCU-written status.
    assign scratch_o = {scratch_r[4], scratch_r[3], scratch_r[2], scratch_r[1], scratch_r[0]};

    // Video control
    reg video_enable_r;
    reg text_mode_r;
    reg mixed_mode_r;
    reg hires_mode_r;
    reg page2_r;
    reg an3_r;
    reg store80_r;
    reg col80_r;
    reg altchar_r;
    reg shrg_mode_r;
    reg [3:0] text_color_r;
    reg [3:0] bg_color_r;
    reg [3:0] border_color_r;
    reg mono_mode_r;
    reg mono_dhires_r;

    // Keyboard
    reg [7:0] keycode_r;

    // A2 bus control
    reg a2bus_ready_r;
    reg cardrom_release_r;
    reg a2_reset_r;
    reg [7:0] a2_cmd_r;
    reg [31:0] a2_data_r;

    // Drive volumes
    reg volume_ready_r    [0:1];
    reg volume_mounted_r  [0:1];
    reg volume_readonly_r [0:1];
    reg [31:0] volume_size_r [0:1];
    reg volume_ack_r      [0:1];

    // ProDOS HDD volumes: compact register bank (7-bit reg space is full, so
    // read and write meanings overlap per address — see decode below).
    // ProDOS blocks are 16-bit, so LBA and SIZE are exposed as 2 bytes each.
    reg        hdd_ready_r    [0:1];
    reg        hdd_mounted_r  [0:1];
    reg        hdd_readonly_r [0:1];
    reg [15:0] hdd_size_r     [0:1];
    reg        hdd_ack_r      [0:1];

    // Slot config
    reg [7:0] slot_card_r [0:7];
    reg slot_reconfig_r;

    // -------------------------------------------------------
    // Interface assignments -- Video
    // -------------------------------------------------------
    assign video_control_if.enable                = video_enable_r;
    assign video_control_if.TEXT_MODE             = text_mode_r;
    assign video_control_if.MIXED_MODE            = mixed_mode_r;
    assign video_control_if.PAGE2                 = page2_r;
    assign video_control_if.HIRES_MODE            = hires_mode_r;
    assign video_control_if.AN3                   = an3_r;
    assign video_control_if.STORE80               = store80_r;
    assign video_control_if.COL80                 = col80_r;
    assign video_control_if.ALTCHAR               = altchar_r;
    assign video_control_if.TEXT_COLOR             = text_color_r;
    assign video_control_if.BACKGROUND_COLOR      = bg_color_r;
    assign video_control_if.BORDER_COLOR          = border_color_r;
    assign video_control_if.MONOCHROME_MODE       = mono_mode_r;
    assign video_control_if.MONOCHROME_DHIRES_MODE = mono_dhires_r;
    assign video_control_if.SHRG_MODE             = shrg_mode_r;

    // -------------------------------------------------------
    // Interface assignments -- A2 bus control
    // -------------------------------------------------------
    // Bus-ready: normally the firmware's explicit reg 0x30 write (or the
    // standalone fallback when no MCU exists). The reset-hold backstop also
    // forces it so a crashed MCU that latched mcu_ready can never leave the
    // Apple bus interface parked in IO_INIT forever.
    assign a2bus_control_if.ready = a2bus_ready_r || standalone_r ||
                                    (rst_hold_cnt_r >= RST_HOLD_BACKSTOP[RST_CW-1:0]);
    assign cardrom_release_o = cardrom_release_r;

    // -------------------------------------------------------
    // Interface assignments -- Drive volumes
    // -------------------------------------------------------
    assign volumes[0].ready    = volume_ready_r[0];
    assign volumes[0].mounted  = volume_mounted_r[0];
    assign volumes[0].readonly = volume_readonly_r[0];
    assign volumes[0].size     = volume_size_r[0];
    assign volumes[0].ack      = volume_ack_r[0];

    assign volumes[1].ready    = volume_ready_r[1];
    assign volumes[1].mounted  = volume_mounted_r[1];
    assign volumes[1].readonly = volume_readonly_r[1];
    assign volumes[1].size     = volume_size_r[1];
    assign volumes[1].ack      = volume_ack_r[1];

    assign hdd_volumes[0].ready    = hdd_ready_r[0];
    assign hdd_volumes[0].mounted  = hdd_mounted_r[0];
    assign hdd_volumes[0].readonly = hdd_readonly_r[0];
    assign hdd_volumes[0].size     = {16'b0, hdd_size_r[0]};
    assign hdd_volumes[0].ack      = hdd_ack_r[0];

    assign hdd_volumes[1].ready    = hdd_ready_r[1];
    assign hdd_volumes[1].mounted  = hdd_mounted_r[1];
    assign hdd_volumes[1].readonly = hdd_readonly_r[1];
    assign hdd_volumes[1].size     = {16'b0, hdd_size_r[1]};
    assign hdd_volumes[1].ack      = hdd_ack_r[1];

    // -------------------------------------------------------
    // Interface assignments -- Slotmaker
    // -------------------------------------------------------
    // Slot writes are triggered via register writes to 0x60-0x67
    // Reconfig is triggered via register 0x6B
    reg [2:0] slot_wr_slot_r;
    reg [7:0] slot_wr_card_r;
    reg       slot_wr_r;

    assign slotmaker_config_if.slot   = slot_wr_slot_r;
    assign slotmaker_config_if.card_i = slot_wr_card_r;
    assign slotmaker_config_if.wr     = slot_wr_r;
    assign slotmaker_config_if.reconfig = slot_reconfig_r;

    // -------------------------------------------------------
    // SPACE 0: Local 256B RAM
    // -------------------------------------------------------
    reg [7:0] local_mem [0:255];
    reg [7:0] local_rd_data_q;
    reg       local_rd_valid_q;

    always @(posedge clk) begin
        if (mem_wr_en && (mem_space == 3'd0))
            local_mem[mem_wr_addr[7:0]] <= mem_wr_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            local_rd_valid_q <= 1'b0;
            local_rd_data_q  <= 8'h00;
        end else begin
            local_rd_valid_q <= 1'b0;
            if (mem_rd_req && (mem_rd_space == 3'd0)) begin
                local_rd_data_q  <= local_mem[mem_rd_addr[7:0]];
                local_rd_valid_q <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------
    // SPACE 1: SDRAM byte access via mem_port_if
    // -------------------------------------------------------
    // Write accumulator: coalesce consecutive bytes into 32-bit words
    reg [31:0] acc_word_r;
    reg [3:0]  acc_be_r;            // byte enables
    reg [20:0] acc_waddr_r;         // word address held in the accumulator
    reg        acc_valid_r;
    reg [7:0]  acc_idle_r;          // cycles since last write (end-of-burst flush)
    localparam [7:0] ACC_IDLE_FLUSH = 8'd200;  // ~3.7us @54MHz; >> inter-byte gap

    // Write FIFO (word-granular) drained to SDRAM whenever the port is free.
    // Decouples XFER byte acceptance (which has no backpressure to the SPI master
    // and must never stall) from SDRAM availability, so framebuffer contention can
    // no longer drop bytes -- the original single-word accumulator overwrote a
    // not-yet-flushed word when mem_if.available was low.
    localparam WF_DEPTH = 32;
    localparam WF_AW    = 5;            // log2(WF_DEPTH)
    reg [20:0] wf_addr_m [0:WF_DEPTH-1];
    reg [31:0] wf_data_m [0:WF_DEPTH-1];
    reg [3:0]  wf_be_m   [0:WF_DEPTH-1];
    reg [WF_AW:0] wf_wptr_r, wf_rptr_r; // extra MSB distinguishes full vs empty
    wire          wf_empty = (wf_wptr_r == wf_rptr_r);

    // Read cache, two slots: slot 0 = current word, slot 1 = prefetched
    // next word. XFER reads stream sequential bytes against a hard SPI
    // byte deadline (~2us at 4 MHz); a single-word cache made byte 0 of
    // every word a full SDRAM round trip against that deadline, and under
    // port contention (framebuffer line fetches, storage arbitration) a
    // late response made the protocol FSM emit a stale byte and shift the
    // rest of the stream — seen on hardware as corrupted HDD write-backs.
    // Prefetching word+1 while bytes 1-3 of the current word stream out
    // turns the deadline into ~6us and makes sequential reads all-hit.
    reg [31:0] rdc_word_r  [1:0];
    reg [20:0] rdc_waddr_r [1:0];
    reg        rdc_valid_r [1:0];

    // Pending / in-flight demand read (held until served, never dropped)
    reg        rd_pending_r;
    reg [20:0] rd_waddr_r;
    reg [1:0]  rd_bsel_r;
    reg        rd_inflight_r;       // SDRAM read issued, awaiting mem_if.ready
    reg [1:0]  rd_inflight_bsel_r;
    reg        rd_inflight_pf_r;    // in-flight read is a prefetch (no SPI response)
    reg        rd_inflight_slot_r;  // cache slot the completion fills

    // Prefetch request (speculative next word for sequential XFER streams)
    reg        pf_pending_r;
    reg [20:0] pf_waddr_r;
    reg        pf_slot_r;

    // SDRAM read response byte (to the read mux)
    reg        sdram_rd_resp_valid_r;
    reg [7:0]  sdram_rd_resp_data_r;

    // Status bits consumed by register 0x06 (kept under their original names)
    wire sdram_wr_pending_r = acc_valid_r | ~wf_empty;
    wire sdram_rd_pending_r = rd_pending_r | rd_inflight_r;

    // SDRAM port driving
    reg        mem_if_wr_r;
    reg        mem_if_rd_r;
    reg [20:0] mem_if_addr_r;
    reg [31:0] mem_if_data_r;
    reg [3:0]  mem_if_be_r;

    assign mem_if.addr    = mem_if_addr_r;
    assign mem_if.data    = mem_if_data_r;
    assign mem_if.byte_en = mem_if_be_r;
    assign mem_if.wr      = mem_if_wr_r;
    assign mem_if.rd      = mem_if_rd_r;
    assign mem_if.burst   = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_word_r  <= 32'd0;
            acc_be_r    <= 4'b0000;
            acc_waddr_r <= 21'd0;
            acc_valid_r <= 1'b0;
            acc_idle_r  <= 8'd0;
            wf_wptr_r   <= '0;
            wf_rptr_r   <= '0;
            rdc_word_r[0]  <= 32'd0;
            rdc_word_r[1]  <= 32'd0;
            rdc_waddr_r[0] <= 21'd0;
            rdc_waddr_r[1] <= 21'd0;
            rdc_valid_r[0] <= 1'b0;
            rdc_valid_r[1] <= 1'b0;
            rd_pending_r  <= 1'b0;
            rd_waddr_r    <= 21'd0;
            rd_bsel_r     <= 2'd0;
            rd_inflight_r <= 1'b0;
            rd_inflight_bsel_r <= 2'd0;
            rd_inflight_pf_r   <= 1'b0;
            rd_inflight_slot_r <= 1'b0;
            pf_pending_r <= 1'b0;
            pf_waddr_r   <= 21'd0;
            pf_slot_r    <= 1'b0;
            sdram_rd_resp_valid_r <= 1'b0;
            sdram_rd_resp_data_r  <= 8'h00;
            mem_if_wr_r <= 1'b0;
            mem_if_rd_r <= 1'b0;
            mem_if_addr_r <= 21'd0;
            mem_if_data_r <= 32'd0;
            mem_if_be_r   <= 4'b0000;
        end else begin
            // One-shot strobes
            mem_if_wr_r <= 1'b0;
            mem_if_rd_r <= 1'b0;
            sdram_rd_resp_valid_r <= 1'b0;

            // ---- 1) Capture SDRAM read completion (demand or prefetch) ----
            if (mem_if.ready && rd_inflight_r) begin
                rdc_word_r[rd_inflight_slot_r]  <= mem_if.q[31:0];
                rdc_waddr_r[rd_inflight_slot_r] <= mem_if_addr_r;
                rdc_valid_r[rd_inflight_slot_r] <= 1'b1;
                rd_inflight_r <= 1'b0;
                if (!rd_inflight_pf_r) begin
                    case (rd_inflight_bsel_r)
                        2'd0: sdram_rd_resp_data_r <= mem_if.q[7:0];
                        2'd1: sdram_rd_resp_data_r <= mem_if.q[15:8];
                        2'd2: sdram_rd_resp_data_r <= mem_if.q[23:16];
                        2'd3: sdram_rd_resp_data_r <= mem_if.q[31:24];
                    endcase
                    sdram_rd_resp_valid_r <= 1'b1;
                end
            end

            // ---- 2) Accept XFER writes (never stalls: accumulator + FIFO) ----
            // addr[23:2] = word address, addr[1:0] = byte offset
            if (mem_wr_en && (mem_space == 3'd1)) begin
                acc_idle_r <= 8'd0;
                if (acc_valid_r && (mem_wr_addr[23:2] != acc_waddr_r)) begin
                    // Different word: evict current accumulator to FIFO, start new
                    wf_addr_m[wf_wptr_r[WF_AW-1:0]] <= acc_waddr_r;
                    wf_data_m[wf_wptr_r[WF_AW-1:0]] <= acc_word_r;
                    wf_be_m  [wf_wptr_r[WF_AW-1:0]] <= acc_be_r;
                    wf_wptr_r   <= wf_wptr_r + 1'b1;
                    acc_waddr_r <= mem_wr_addr[23:2];
                    acc_word_r  <= 32'd0;
                    case (mem_wr_addr[1:0])
                        2'd0: begin acc_word_r[7:0]   <= mem_wr_data; acc_be_r <= 4'b0001; end
                        2'd1: begin acc_word_r[15:8]  <= mem_wr_data; acc_be_r <= 4'b0010; end
                        2'd2: begin acc_word_r[23:16] <= mem_wr_data; acc_be_r <= 4'b0100; end
                        2'd3: begin acc_word_r[31:24] <= mem_wr_data; acc_be_r <= 4'b1000; end
                    endcase
                    acc_valid_r <= 1'b1;
                end else begin
                    // Same word (or first byte): merge into accumulator
                    acc_waddr_r <= mem_wr_addr[23:2];
                    case (mem_wr_addr[1:0])
                        2'd0: begin acc_word_r[7:0]   <= mem_wr_data; acc_be_r[0] <= 1'b1; end
                        2'd1: begin acc_word_r[15:8]  <= mem_wr_data; acc_be_r[1] <= 1'b1; end
                        2'd2: begin acc_word_r[23:16] <= mem_wr_data; acc_be_r[2] <= 1'b1; end
                        2'd3: begin acc_word_r[31:24] <= mem_wr_data; acc_be_r[3] <= 1'b1; end
                    endcase
                    acc_valid_r <= 1'b1;
                    if (mem_wr_addr[1:0] == 2'd3) begin
                        // Word complete: push merged word to FIFO
                        wf_addr_m[wf_wptr_r[WF_AW-1:0]] <= mem_wr_addr[23:2];
                        wf_data_m[wf_wptr_r[WF_AW-1:0]] <= {mem_wr_data, acc_word_r[23:0]};
                        wf_be_m  [wf_wptr_r[WF_AW-1:0]] <= acc_be_r | 4'b1000;
                        wf_wptr_r   <= wf_wptr_r + 1'b1;
                        acc_valid_r <= 1'b0;
                        acc_be_r    <= 4'b0000;
                        acc_word_r  <= 32'd0;
                    end
                end
                // Invalidate read cache on write to a cached word
                if (rdc_valid_r[0] && (mem_wr_addr[23:2] == rdc_waddr_r[0]))
                    rdc_valid_r[0] <= 1'b0;
                if (rdc_valid_r[1] && (mem_wr_addr[23:2] == rdc_waddr_r[1]))
                    rdc_valid_r[1] <= 1'b0;
            end else if (acc_valid_r && (acc_idle_r >= ACC_IDLE_FLUSH || rd_pending_r)) begin
                // Flush the final partial word: end-of-burst, or to order before a
                // pending read (write-before-read). Single accumulator-flush site,
                // and only when !mem_wr_en, so it never collides with a write push.
                wf_addr_m[wf_wptr_r[WF_AW-1:0]] <= acc_waddr_r;
                wf_data_m[wf_wptr_r[WF_AW-1:0]] <= acc_word_r;
                wf_be_m  [wf_wptr_r[WF_AW-1:0]] <= acc_be_r;
                wf_wptr_r   <= wf_wptr_r + 1'b1;
                acc_valid_r <= 1'b0;
                acc_be_r    <= 4'b0000;
                acc_word_r  <= 32'd0;
            end else if (acc_valid_r) begin
                acc_idle_r <= acc_idle_r + 8'd1;
            end

            // ---- 3) Accept a read request: cache hit serves now, else mark pending.
            //         Sequential streams also trigger a speculative prefetch of the
            //         next word into the other slot. ----
            if (mem_rd_req && (mem_rd_space == 3'd1)) begin
                if (rdc_valid_r[0] && (mem_rd_addr[23:2] == rdc_waddr_r[0])) begin
                    case (mem_rd_addr[1:0])
                        2'd0: sdram_rd_resp_data_r <= rdc_word_r[0][7:0];
                        2'd1: sdram_rd_resp_data_r <= rdc_word_r[0][15:8];
                        2'd2: sdram_rd_resp_data_r <= rdc_word_r[0][23:16];
                        2'd3: sdram_rd_resp_data_r <= rdc_word_r[0][31:24];
                    endcase
                    sdram_rd_resp_valid_r <= 1'b1;
                    // Past the first byte of this word and the next word is not
                    // cached: prefetch it into the other slot.
                    if (mem_rd_addr[1:0] != 2'd0 &&
                        !(rdc_valid_r[1] && rdc_waddr_r[1] == (mem_rd_addr[23:2] + 21'd1)))
                    begin
                        pf_pending_r <= 1'b1;
                        pf_waddr_r   <= mem_rd_addr[23:2] + 21'd1;
                        pf_slot_r    <= 1'b1;
                    end
                end else if (rdc_valid_r[1] && (mem_rd_addr[23:2] == rdc_waddr_r[1])) begin
                    case (mem_rd_addr[1:0])
                        2'd0: sdram_rd_resp_data_r <= rdc_word_r[1][7:0];
                        2'd1: sdram_rd_resp_data_r <= rdc_word_r[1][15:8];
                        2'd2: sdram_rd_resp_data_r <= rdc_word_r[1][23:16];
                        2'd3: sdram_rd_resp_data_r <= rdc_word_r[1][31:24];
                    endcase
                    sdram_rd_resp_valid_r <= 1'b1;
                    if (mem_rd_addr[1:0] != 2'd0 &&
                        !(rdc_valid_r[0] && rdc_waddr_r[0] == (mem_rd_addr[23:2] + 21'd1)))
                    begin
                        pf_pending_r <= 1'b1;
                        pf_waddr_r   <= mem_rd_addr[23:2] + 21'd1;
                        pf_slot_r    <= 1'b0;
                    end
                end else begin
                    rd_pending_r <= 1'b1;
                    rd_waddr_r   <= mem_rd_addr[23:2];
                    rd_bsel_r    <= mem_rd_addr[1:0];
                    pf_pending_r <= 1'b0;   // demand read supersedes any stale prefetch
                end
            end

            // ---- 4) SDRAM arbiter: writes drain before reads (preserves
            //         ordering); demand reads before prefetches ----
            if (mem_if.available && !mem_if_wr_r && !mem_if_rd_r && !rd_inflight_r) begin
                if (!wf_empty) begin
                    // Pop one queued word -> SDRAM write
                    mem_if_addr_r <= wf_addr_m[wf_rptr_r[WF_AW-1:0]];
                    mem_if_data_r <= wf_data_m[wf_rptr_r[WF_AW-1:0]];
                    mem_if_be_r   <= wf_be_m  [wf_rptr_r[WF_AW-1:0]];
                    mem_if_wr_r   <= 1'b1;
                    wf_rptr_r     <= wf_rptr_r + 1'b1;
                end else if (rd_pending_r && !acc_valid_r) begin
                    // All writes drained -> issue the pending SDRAM read
                    mem_if_addr_r <= rd_waddr_r;
                    mem_if_rd_r   <= 1'b1;
                    rd_inflight_r <= 1'b1;
                    rd_inflight_bsel_r <= rd_bsel_r;
                    rd_inflight_pf_r   <= 1'b0;
                    rd_inflight_slot_r <= 1'b0;
                    rd_pending_r  <= 1'b0;
                end else if (pf_pending_r && !acc_valid_r) begin
                    // Idle -> speculative prefetch of the next stream word
                    mem_if_addr_r <= pf_waddr_r;
                    mem_if_rd_r   <= 1'b1;
                    rd_inflight_r <= 1'b1;
                    rd_inflight_pf_r   <= 1'b1;
                    rd_inflight_slot_r <= pf_slot_r;
                    pf_pending_r  <= 1'b0;
                end
            end
        end
    end

    // -------------------------------------------------------
    // SPACE 2: Bus event FIFO read
    // -------------------------------------------------------
    reg [1:0]  fifo_byte_cnt_r;
    reg [31:0] fifo_word_r;
    reg        fifo_rd_valid_r;
    reg [7:0]  fifo_rd_data_r;
    reg        fifo_xfer_pop_r;   // Pop request from XFER SPACE 2 reads
    reg        fifo_reg_pop_r;    // Pop request from register 0x77 writes

    // Combine pop sources
    assign fifo_pop = fifo_xfer_pop_r | fifo_reg_pop_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_byte_cnt_r <= 2'd0;
            fifo_word_r     <= 32'd0;
            fifo_rd_valid_r <= 1'b0;
            fifo_rd_data_r  <= 8'h00;
            fifo_xfer_pop_r <= 1'b0;
        end else begin
            fifo_rd_valid_r <= 1'b0;
            fifo_xfer_pop_r <= 1'b0;

            if (mem_rd_req && (mem_rd_space == 3'd2)) begin
                if (fifo_byte_cnt_r == 2'd0) begin
                    // Latch new word from FIFO
                    if (!fifo_empty) begin
                        fifo_word_r <= fifo_rdata;
                        fifo_rd_data_r <= fifo_rdata[7:0];
                        fifo_rd_valid_r <= 1'b1;
                        fifo_byte_cnt_r <= 2'd1;
                    end else begin
                        fifo_rd_data_r  <= 8'hFF;
                        fifo_rd_valid_r <= 1'b1;
                    end
                end else begin
                    // Serve next byte from latched word
                    case (fifo_byte_cnt_r)
                        2'd1: fifo_rd_data_r <= fifo_word_r[15:8];
                        2'd2: fifo_rd_data_r <= fifo_word_r[23:16];
                        2'd3: fifo_rd_data_r <= fifo_word_r[31:24];
                        default: fifo_rd_data_r <= 8'hFF;
                    endcase
                    fifo_rd_valid_r <= 1'b1;
                    if (fifo_byte_cnt_r == 2'd3) begin
                        fifo_xfer_pop_r <= 1'b1;  // Pop after all 4 bytes consumed
                        fifo_byte_cnt_r <= 2'd0;
                    end else begin
                        fifo_byte_cnt_r <= fifo_byte_cnt_r + 2'd1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------
    // SPACE 3: Uthernet2 (W5100) backing store -- card holds the memory (port B).
    // Drop-free by construction (no SDRAM/arbitration): combinational write/read
    // passthrough to the card, with a 1-cycle read pipeline matching the card's
    // registered read (req cycle T -> w5100_host_rdata valid at T+1).
    // -------------------------------------------------------
    assign w5100_host_wr    = mem_wr_en && (mem_space == 3'd3);
    assign w5100_host_wdata = mem_wr_data;
    assign w5100_host_addr  = (mem_wr_en && (mem_space == 3'd3)) ? mem_wr_addr[15:0]
                                                                 : mem_rd_addr[15:0];

    reg       w5100_rd_pending_q;
    reg       w5100_rd_valid_q;
    reg [7:0] w5100_rd_data_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w5100_rd_pending_q <= 1'b0;
            w5100_rd_valid_q   <= 1'b0;
            w5100_rd_data_q    <= 8'h00;
        end else begin
            w5100_rd_valid_q   <= 1'b0;
            w5100_rd_pending_q <= (mem_rd_req && (mem_rd_space == 3'd3));
            if (w5100_rd_pending_q) begin
                w5100_rd_data_q  <= w5100_host_rdata;
                w5100_rd_valid_q <= 1'b1;
            end
        end
    end

    // Doorbell clear strobe (register 0x7A write, write-1-to-clear)
    reg [3:0] w5100_cmd_clr_r;
    assign w5100_cmd_clr = w5100_cmd_clr_r;

    // -------------------------------------------------------
    // Memory read mux (combines all spaces)
    // -------------------------------------------------------
    always @(*) begin
        mem_rd_valid = 1'b0;
        mem_rd_data  = 8'hFF;
        if (local_rd_valid_q) begin
            mem_rd_valid = 1'b1;
            mem_rd_data  = local_rd_data_q;
        end else if (sdram_rd_resp_valid_r) begin
            mem_rd_valid = 1'b1;
            mem_rd_data  = sdram_rd_resp_data_r;
        end else if (fifo_rd_valid_r) begin
            mem_rd_valid = 1'b1;
            mem_rd_data  = fifo_rd_data_r;
        end else if (w5100_rd_valid_q) begin
            mem_rd_valid = 1'b1;
            mem_rd_data  = w5100_rd_data_q;
        end
    end

    // -------------------------------------------------------
    // SD card SPI master (regs 0x6C-0x6E)
    // -------------------------------------------------------
    reg        sd_cs_n_r;
    reg        sd_slow_clk_r;
    reg  [7:0] sd_tx_data_r;
    reg        sd_tx_start_r;
    wire [7:0] sd_rx_data_w;
    wire       sd_busy_w;

    fpga_sd_spi #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) fpga_sd_spi_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cs_n_i(sd_cs_n_r),
        .slow_clk_i(sd_slow_clk_r),
        .tx_start_i(sd_tx_start_r),
        .tx_data_i(sd_tx_data_r),
        .rx_data_o(sd_rx_data_w),
        .busy_o(sd_busy_w),
        .sd_clk_o(sd_clk_o),
        .sd_mosi_o(sd_cmd_o),
        .sd_miso_i(sd_dat0_i),
        .sd_cs_n_o(sd_dat3_o)
    );

    // A2 reset detection
    wire a2_reset_debounced_w;
    debounce #(
        .DEBOUNCE_TIME(10000)
    ) debounce_a2reset (
        .clk(clk),
        .rst(~a2bus_if.device_reset_n),
        .i(a2bus_if.system_reset_n),
        .o(a2_reset_debounced_w)
    );

    wire system_reset_release_w;
    rising_edge system_reset_release (
        .clk(clk),
        .i(a2_reset_debounced_w),
        .o(system_reset_release_w)
    );

    // -------------------------------------------------------
    // Register read mux (combinational)
    // -------------------------------------------------------
    always @(*) begin
        reg_rdata = 8'h00;
        case (reg_idx)
            // Page 0: System
            7'h00: reg_rdata = DEVICE_ID0;
            7'h01: reg_rdata = DEVICE_ID1;
            7'h02: reg_rdata = DEVICE_ID2;
            7'h03: reg_rdata = DEVICE_ID3;
            7'h04: reg_rdata = PROTO_VER;
            7'h05: reg_rdata = CAP0;
            // STATUS: [7]=FPGA_CONFIGURED (always 1), [6]=SDRAM_READY,
            //         [5]=A2BUS_RESET_N, [4:2]=reserved, [1]=WR_PENDING, [0]=RD_PENDING
            7'h06: reg_rdata = {1'b1, sdram_init_complete_i, a2bus_if.system_reset_n, 3'b0, sdram_wr_pending_r, sdram_rd_pending_r};
            7'h07: reg_rdata = scratch_r[0];
            7'h08: reg_rdata = sys_time_r[7:0];
            7'h09: reg_rdata = sys_time_r[15:8];
            7'h0A: reg_rdata = sys_time_r[23:16];
            7'h0B: reg_rdata = sys_time_r[31:24];
            7'h0C: reg_rdata = scratch_r[1];
            7'h0D: reg_rdata = scratch_r[2];
            7'h0E: reg_rdata = scratch_r[3];
            7'h0F: reg_rdata = scratch_r[4];

            // Page 1: Video control
            7'h10: reg_rdata = {7'b0, video_enable_r};
            7'h11: reg_rdata = {7'b0, text_mode_r};
            7'h12: reg_rdata = {7'b0, mixed_mode_r};
            7'h13: reg_rdata = {7'b0, hires_mode_r};
            7'h14: reg_rdata = {7'b0, page2_r};
            7'h15: reg_rdata = {7'b0, an3_r};
            7'h16: reg_rdata = {7'b0, store80_r};
            7'h17: reg_rdata = {7'b0, col80_r};
            7'h18: reg_rdata = {7'b0, altchar_r};
            7'h19: reg_rdata = {7'b0, shrg_mode_r};
            // bus-event FIFO trigger (freeze-on-match)
            7'h1A: reg_rdata = {6'b0, trig_matched_i, trig_enable_o};
            7'h1B: reg_rdata = trig_addr_o[7:0];
            7'h1C: reg_rdata = trig_addr_o[15:8];
            7'h1D: reg_rdata = trig_mask_o[7:0];
            7'h1E: reg_rdata = trig_mask_o[15:8];
            7'h1F: reg_rdata = {7'b0, oneshot_o};

            // Page 2: Video colors & keyboard
            7'h20: reg_rdata = {4'b0, text_color_r};
            7'h21: reg_rdata = {4'b0, bg_color_r};
            7'h22: reg_rdata = {4'b0, border_color_r};
            7'h23: reg_rdata = {7'b0, mono_mode_r};
            7'h24: reg_rdata = {7'b0, mono_dhires_r};
            7'h25: reg_rdata = keycode_r;

            // ProDOS HDD volumes (compact bank; reads = request state from the
            // HDD card, writes = control/size/ack — see the write decode)
            7'h26: reg_rdata = {6'b0, hdd_volumes[0].wr, hdd_volumes[0].rd};
            7'h27: reg_rdata = hdd_volumes[0].lba[7:0];
            7'h28: reg_rdata = hdd_volumes[0].lba[15:8];
            7'h2A: reg_rdata = {6'b0, hdd_volumes[1].wr, hdd_volumes[1].rd};
            7'h2B: reg_rdata = hdd_volumes[1].lba[7:0];
            7'h2C: reg_rdata = hdd_volumes[1].lba[15:8];
            7'h2E: reg_rdata = {7'b0, a2_rst_release_r};
            7'h2F: reg_rdata = ssc_ctl_i;   // SSC 6551 CTL (baud in [3:0])

            // Page 3: A2 bus control
            7'h30: reg_rdata = {7'b0, a2bus_ready_r};
            7'h31: reg_rdata = 8'h00; // CARDROM_RELEASE (write-only)
            7'h32: reg_rdata = {7'b0, cardrom_active_i};
            7'h33: reg_rdata = {7'b0, a2_reset_r};
            7'h34: reg_rdata = a2_cmd_r;
            7'h35: reg_rdata = a2_data_r[7:0];
            7'h36: reg_rdata = a2_data_r[15:8];
            7'h37: reg_rdata = a2_data_r[23:16];
            7'h38: reg_rdata = a2_data_r[31:24];
            7'h39: reg_rdata = {7'b0, a2bus_if.control_inh_n};
            7'h3A: reg_rdata = {7'b0, a2bus_if.control_irq_n};
            7'h3B: reg_rdata = {7'b0, a2bus_if.control_rdy_n};
            7'h3C: reg_rdata = {7'b0, a2bus_if.control_dma_n};
            7'h3D: reg_rdata = {7'b0, a2bus_if.control_nmi_n};
            7'h3E: reg_rdata = {7'b0, a2bus_if.control_reset_n};
            7'h3F: reg_rdata = VERSION_STR[8*(13-ver_idx_r) +: 8];

            // Page 4: Volume 0
            7'h40: reg_rdata = {7'b0, volume_ready_r[0]};
            7'h41: reg_rdata = {7'b0, volumes[0].active};
            7'h42: reg_rdata = {7'b0, volume_mounted_r[0]};
            7'h43: reg_rdata = {7'b0, volume_readonly_r[0]};
            7'h44: reg_rdata = volume_size_r[0][7:0];
            7'h45: reg_rdata = volume_size_r[0][15:8];
            7'h46: reg_rdata = volume_size_r[0][23:16];
            7'h47: reg_rdata = volume_size_r[0][31:24];
            7'h48: reg_rdata = volumes[0].lba[7:0];
            7'h49: reg_rdata = volumes[0].lba[15:8];
            7'h4A: reg_rdata = volumes[0].lba[23:16];
            7'h4B: reg_rdata = volumes[0].lba[31:24];
            7'h4C: reg_rdata = {2'b0, volumes[0].blk_cnt};
            7'h4D: reg_rdata = {7'b0, volumes[0].rd};
            7'h4E: reg_rdata = {7'b0, volumes[0].wr};

            // Page 5: Volume 1
            7'h50: reg_rdata = {7'b0, volume_ready_r[1]};
            7'h51: reg_rdata = {7'b0, volumes[1].active};
            7'h52: reg_rdata = {7'b0, volume_mounted_r[1]};
            7'h53: reg_rdata = {7'b0, volume_readonly_r[1]};
            7'h54: reg_rdata = volume_size_r[1][7:0];
            7'h55: reg_rdata = volume_size_r[1][15:8];
            7'h56: reg_rdata = volume_size_r[1][23:16];
            7'h57: reg_rdata = volume_size_r[1][31:24];
            7'h58: reg_rdata = volumes[1].lba[7:0];
            7'h59: reg_rdata = volumes[1].lba[15:8];
            7'h5A: reg_rdata = volumes[1].lba[23:16];
            7'h5B: reg_rdata = volumes[1].lba[31:24];
            7'h5C: reg_rdata = {2'b0, volumes[1].blk_cnt};
            7'h5D: reg_rdata = {7'b0, volumes[1].rd};
            7'h5E: reg_rdata = {7'b0, volumes[1].wr};

            // Page 6: Slot config & GPIO
            7'h60: reg_rdata = slot_card_r[0];
            7'h61: reg_rdata = slot_card_r[1];
            7'h62: reg_rdata = slot_card_r[2];
            7'h63: reg_rdata = slot_card_r[3];
            7'h64: reg_rdata = slot_card_r[4];
            7'h65: reg_rdata = slot_card_r[5];
            7'h66: reg_rdata = slot_card_r[6];
            7'h67: reg_rdata = slot_card_r[7];
            7'h68: reg_rdata = {3'b0, led_o};
            7'h69: reg_rdata = {7'b0, ws2812_o};
            7'h6A: reg_rdata = {7'b0, button_i};

            // SD card registers
            7'h6C: reg_rdata = {6'b0, sd_slow_clk_r, sd_cs_n_r};
            7'h6D: reg_rdata = sd_rx_data_w;
            7'h6E: reg_rdata = {7'b0, sd_busy_w};

            // Page 7: Bus event FIFO
            7'h70: reg_rdata = {fifo_empty, fifo_full, 6'b0};
            7'h71: reg_rdata = fifo_count[7:0];
            7'h72: reg_rdata = {7'b0, fifo_count[8]};
            7'h73: reg_rdata = fifo_rdata[7:0];
            7'h74: reg_rdata = fifo_rdata[15:8];
            7'h75: reg_rdata = fifo_rdata[23:16];
            7'h76: reg_rdata = fifo_rdata[31:24];
            7'h78: reg_rdata = {5'b0, capture_mode_o};
            7'h79: reg_rdata = {7'b0, capture_enable_o};

            // Uthernet2 command-pending doorbell (bits[3:0] = sockets 0-3)
            7'h7A: reg_rdata = {4'b0, w5100_cmd_pending};

            // Uthernet2 DEBUG: port-B (SPACE 3) write instrumentation
            7'h7B: reg_rdata = w5100_dbg_wr_count[7:0];
            7'h7C: reg_rdata = w5100_dbg_last_addr[7:0];
            7'h7D: reg_rdata = w5100_dbg_last_addr[15:8];
            7'h7E: reg_rdata = w5100_dbg_last_wdata;

            default: reg_rdata = 8'h00;
        endcase
    end

    // -------------------------------------------------------
    // Register write logic
    // -------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            video_enable_r    <= 1'b0;
            text_mode_r       <= 1'b1;
            mixed_mode_r      <= 1'b1;
            page2_r           <= 1'b0;
            hires_mode_r      <= 1'b0;
            an3_r             <= 1'b1;
            store80_r         <= 1'b0;
            col80_r           <= 1'b0;
            altchar_r         <= 1'b0;
            shrg_mode_r       <= 1'b0;
            text_color_r      <= 4'd15;
            bg_color_r        <= 4'd2;
            border_color_r    <= 4'd2;
            mono_mode_r       <= 1'b0;
            mono_dhires_r     <= 1'b0;
            keycode_r         <= 8'd0;
            a2bus_ready_r     <= 1'b0;
            a2_rst_release_r  <= 1'b0;
            cardrom_release_r <= 1'b0;
            a2_reset_r        <= 1'b0;
            a2_cmd_r          <= 8'd0;
            a2_data_r         <= 32'd0;
            for (i = 0; i < 2; i = i + 1) begin
                volume_ready_r[i]    <= 1'b0;
                volume_mounted_r[i]  <= 1'b0;
                volume_readonly_r[i] <= 1'b0;
                volume_size_r[i]     <= 32'd0;
                volume_ack_r[i]      <= 1'b0;
                hdd_ready_r[i]       <= 1'b0;
                hdd_mounted_r[i]     <= 1'b0;
                hdd_readonly_r[i]    <= 1'b0;
                hdd_size_r[i]        <= 16'd0;
                hdd_ack_r[i]         <= 1'b0;
            end
            for (i = 0; i < 8; i = i + 1)
                slot_card_r[i] <= 8'd0;
            for (i = 0; i < 5; i = i + 1)
                scratch_r[i] <= 8'd0;
            slot_wr_r        <= 1'b0;
            slot_wr_slot_r   <= 3'd0;
            slot_wr_card_r   <= 8'd0;
            slot_reconfig_r  <= 1'b0;
            led_o            <= 5'd0;
            ws2812_o         <= 1'b0;
            capture_mode_o   <= 3'd0;
            // Debug-friendly defaults: capture armed from config with oneshot
            // set, so the FIFO always holds the FIRST 512 bus cycles after
            // /RES release (reset-vector fetch + boot run-up) with no MCU
            // involvement -- free field boot-forensics. Firmware/telnet can
            // flip to rolling (0x1F=0) or disable capture (0x79=0) at will.
            capture_enable_o <= 1'b1;
            oneshot_o        <= 1'b1;
            trig_enable_o    <= 1'b0;
            trig_addr_o      <= 16'd0;
            trig_mask_o      <= 16'd0;
            fifo_reg_pop_r   <= 1'b0;
            sd_cs_n_r        <= 1'b1;
            sd_slow_clk_r    <= 1'b1;
            sd_tx_data_r     <= 8'hFF;
            sd_tx_start_r    <= 1'b0;
            w5100_cmd_clr_r  <= 4'd0;
        end else begin
            // One-shot clears
            cardrom_release_r <= 1'b0;
            volume_ack_r[0]   <= 1'b0;
            volume_ack_r[1]   <= 1'b0;
            hdd_ack_r[0]      <= 1'b0;
            hdd_ack_r[1]      <= 1'b0;
            slot_wr_r         <= 1'b0;
            slot_reconfig_r   <= 1'b0;
            fifo_reg_pop_r    <= 1'b0;
            sd_tx_start_r     <= 1'b0;
            w5100_cmd_clr_r   <= 4'd0;

            // A2 reset edge detection
            if (system_reset_release_w)
                a2_reset_r <= 1'b1;

            // Keycode capture from Apple II bus
            if (a2mem_if.keypress_strobe)
                keycode_r <= a2mem_if.keycode;

            // A2 command capture from bus writes to $C7FF
            if (!a2bus_if.rw_n && a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC7FF))
                a2_cmd_r <= a2bus_if.data;

            if (reg_wr_req) begin
                case (reg_idx)
                    // Page 0: Scratch
                    7'h07: scratch_r[0] <= reg_wdata;
                    7'h0C: scratch_r[1] <= reg_wdata;
                    7'h0D: scratch_r[2] <= reg_wdata;
                    7'h0E: scratch_r[3] <= reg_wdata;
                    7'h0F: scratch_r[4] <= reg_wdata;

                    // Page 1: Video control
                    7'h10: video_enable_r <= reg_wdata[0];
                    7'h11: text_mode_r    <= reg_wdata[0];
                    7'h12: mixed_mode_r   <= reg_wdata[0];
                    7'h13: hires_mode_r   <= reg_wdata[0];
                    7'h14: page2_r        <= reg_wdata[0];
                    7'h15: an3_r          <= reg_wdata[0];
                    7'h16: store80_r      <= reg_wdata[0];
                    7'h17: col80_r        <= reg_wdata[0];
                    7'h18: altchar_r      <= reg_wdata[0];
                    7'h19: shrg_mode_r    <= reg_wdata[0];

                    // Page 2: Video colors & keyboard
                    7'h20: text_color_r   <= reg_wdata[3:0];
                    7'h21: bg_color_r     <= reg_wdata[3:0];
                    7'h22: border_color_r <= reg_wdata[3:0];
                    7'h23: mono_mode_r    <= reg_wdata[0];
                    7'h24: mono_dhires_r  <= reg_wdata[0];
                    7'h25: keycode_r      <= reg_wdata;

                    // Page 3: A2 bus control
                    7'h30: a2bus_ready_r     <= reg_wdata[0];
                    7'h31: cardrom_release_r <= 1'b1;
                    7'h33: a2_reset_r        <= 1'b0; // Writing clears reset flag
                    7'h34: a2_cmd_r          <= reg_wdata;
                    7'h35: a2_data_r[7:0]    <= reg_wdata;
                    7'h36: a2_data_r[15:8]   <= reg_wdata;
                    7'h37: a2_data_r[23:16]  <= reg_wdata;
                    7'h38: a2_data_r[31:24]  <= reg_wdata;

                    // Page 4: Volume 0
                    7'h40: volume_ready_r[0]      <= reg_wdata[0];
                    7'h42: volume_mounted_r[0]    <= reg_wdata[0];
                    7'h43: volume_readonly_r[0]   <= reg_wdata[0];
                    7'h44: volume_size_r[0][7:0]  <= reg_wdata;
                    7'h45: volume_size_r[0][15:8] <= reg_wdata;
                    7'h46: volume_size_r[0][23:16] <= reg_wdata;
                    7'h47: volume_size_r[0][31:24] <= reg_wdata;
                    7'h4F: volume_ack_r[0]        <= 1'b1;

                    // Page 5: Volume 1
                    7'h50: volume_ready_r[1]      <= reg_wdata[0];
                    7'h52: volume_mounted_r[1]    <= reg_wdata[0];
                    7'h53: volume_readonly_r[1]   <= reg_wdata[0];
                    7'h54: volume_size_r[1][7:0]  <= reg_wdata;
                    7'h55: volume_size_r[1][15:8] <= reg_wdata;
                    7'h56: volume_size_r[1][23:16] <= reg_wdata;
                    7'h57: volume_size_r[1][31:24] <= reg_wdata;
                    7'h5F: volume_ack_r[1]        <= 1'b1;

                    // ProDOS HDD volumes (compact bank, write side)
                    7'h26: begin   // CTL: {readonly, mounted, ready}
                        hdd_readonly_r[0] <= reg_wdata[2];
                        hdd_mounted_r[0]  <= reg_wdata[1];
                        hdd_ready_r[0]    <= reg_wdata[0];
                    end
                    7'h27: hdd_size_r[0][7:0]  <= reg_wdata;
                    7'h28: hdd_size_r[0][15:8] <= reg_wdata;
                    7'h29: hdd_ack_r[0]        <= 1'b1;
                    7'h2A: begin
                        hdd_readonly_r[1] <= reg_wdata[2];
                        hdd_mounted_r[1]  <= reg_wdata[1];
                        hdd_ready_r[1]    <= reg_wdata[0];
                    end
                    7'h2B: hdd_size_r[1][7:0]  <= reg_wdata;
                    7'h2C: hdd_size_r[1][15:8] <= reg_wdata;
                    7'h2D: hdd_ack_r[1]        <= 1'b1;
                    7'h3F: ver_idx_r           <= reg_wdata[3:0];
                    7'h2E: a2_rst_release_r    <= reg_wdata[0];

                    // Page 6: Slot config & GPIO
                    7'h60, 7'h61, 7'h62, 7'h63,
                    7'h64, 7'h65, 7'h66, 7'h67: begin
                        slot_card_r[reg_idx[2:0]] <= reg_wdata;
                        slot_wr_slot_r <= reg_idx[2:0];
                        slot_wr_card_r <= reg_wdata;
                        slot_wr_r      <= 1'b1;
                    end
                    7'h68: led_o    <= reg_wdata[4:0];
                    7'h69: ws2812_o <= reg_wdata[0];
                    7'h6B: slot_reconfig_r <= 1'b1;

                    // SD card registers
                    7'h6C: begin
                        sd_cs_n_r     <= reg_wdata[0];
                        sd_slow_clk_r <= reg_wdata[1];
                    end
                    7'h6D: begin
                        sd_tx_data_r  <= reg_wdata;
                        sd_tx_start_r <= 1'b1;
                    end

                    // Page 7: Bus event FIFO control
                    7'h77: fifo_reg_pop_r  <= 1'b1;  // FIFO_POP
                    7'h78: capture_mode_o   <= reg_wdata[2:0];
                    7'h79: capture_enable_o <= reg_wdata[0];
                    7'h1A: trig_enable_o     <= reg_wdata[0];
                    7'h1B: trig_addr_o[7:0]  <= reg_wdata;
                    7'h1C: trig_addr_o[15:8] <= reg_wdata;
                    7'h1D: trig_mask_o[7:0]  <= reg_wdata;
                    7'h1E: trig_mask_o[15:8] <= reg_wdata;
                    7'h1F: oneshot_o         <= reg_wdata[0];

                    // Uthernet2 doorbell clear (write-1-to-clear sockets 0-3)
                    7'h7A: w5100_cmd_clr_r <= reg_wdata[3:0];

                    default: ;
                endcase
            end
        end
    end

endmodule
