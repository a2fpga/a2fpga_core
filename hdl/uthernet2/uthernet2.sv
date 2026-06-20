//
// Uthernet II (WIZnet W5100) virtual card for the A2FPGA multicard bus
//
// (c) 2026 Ed Anuff <ed@a2fpga.com>
//
// Emulates the register/memory front-end of an a2RetroSystems Uthernet II:
// the W5100 in INDIRECT bus mode, presented to the Apple II through four
// device-select ($C0nX) registers, backed by an on-chip dual-port copy of the
// W5100 address space. The "smart" half (socket engine / network bridge) runs
// on the BL616 MCU, which reaches the backing store through the SPI connector's
// memory SPACE 3 (port B below) and is notified of socket commands via the
// per-socket command-pending doorbell.
//
// W5100 indirect-mode interface (mirrored every 4 bytes across $C0n0-$C0nF,
// matching the real card / AppleWin's U2_C0X_MASK = 0x03):
//   offset[1:0] 0 -> MR        Mode Register (indirect/auto-inc/reset control)
//               1 -> IDM_AR0   indirect address, high byte
//               2 -> IDM_AR1   indirect address, low  byte
//               3 -> IDM_DR    data register (R/W @ current address; auto-inc)
// IP65 uses the $C0n4-$C0n7 mirror; both work.
//
// Backing store is the W5100 space compressed to 18 KB of BSRAM:
//   0x0000-0x07FF  registers (common + 4 socket register blocks)  -> phys 0x0000..
//   0x4000-0x7FFF  TX (0x4000-0x5FFF) + RX (0x6000-0x7FFF) buffers -> phys 0x0800..
//

module Uthernet2 #(
    parameter bit [7:0] ID = 5,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,

    // Host (BL616) side: port B of the W5100 backing store (SPI SPACE 3),
    // synchronous to a2bus_if.clk_logic (same domain as the SPI connector).
    // Addressed in natural W5100 address space (0x0000-0x7FFF); the card applies
    // the same phys() compression internally, so firmware uses W5100 addresses.
    input  wire        w5100_host_wr,
    input  wire [15:0] w5100_host_addr,    // W5100 address (0x0000-0x7FFF)
    input  wire [7:0]  w5100_host_wdata,
    output wire [7:0]  w5100_host_rdata,

    // Per-socket command-pending doorbell (set on Apple II write to Sn_CR)
    output reg  [3:0]  cmd_pending_o,
    input  wire [3:0]  cmd_pending_clr,

    // DEBUG instrumentation: port-B (BL616/SPI SPACE 3) write activity, so the
    // MCU can see whether its SPACE 3 writes actually reach the card and with
    // what address/data (read back via SPI regs 0x7B-0x7E).
    output reg  [15:0] dbg_portb_wr_count,
    output reg  [15:0] dbg_portb_last_addr,
    output reg  [7:0]  dbg_portb_last_wdata
);

    // -------------------------------------------------------
    // W5100 constants
    // -------------------------------------------------------
    localparam [7:0]  W5100_MR_AI   = 8'h02;   // mode reg: address auto-increment
    localparam [7:0]  W5100_MR_RST  = 8'h80;   // mode reg: software reset
    localparam [15:0] W5100_RX_BASE = 16'h6000;
    localparam [15:0] W5100_MEM_END = 16'h8000;

    localparam [1:0] SUB_MR      = 2'd0;
    localparam [1:0] SUB_ADDR_HI = 2'd1;
    localparam [1:0] SUB_ADDR_LO = 2'd2;
    localparam [1:0] SUB_DATA    = 2'd3;

    // -------------------------------------------------------
    // Card enable / selection (same idiom as Mockingboard / SSC)
    // -------------------------------------------------------
    reg card_enable;
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0)
                card_enable <= 1'b0;
            else if (slot_if.card_id == ID)
                card_enable <= slot_if.card_enable && ENABLE;
        end
    end

    wire card_sel     = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel = card_sel && !slot_if.dev_select_n;
    wire [1:0] subreg = a2bus_if.addr[1:0];

    // One access pulse per Apple II data cycle (read or write)
    wire access      = card_dev_sel && a2bus_if.data_in_strobe;
    wire wr_access   = access && !a2bus_if.rw_n;
    wire data_access = access && (subreg == SUB_DATA);

    // -------------------------------------------------------
    // Indirect-interface registers
    // -------------------------------------------------------
    reg [7:0]  mode_r;        // W5100 MR (indirect control)
    reg [15:0] data_addr_r;   // IDM address pointer

    // Auto-increment with W5100 8 KB-window wrap
    wire [15:0] addr_inc  = data_addr_r + 16'd1;
    wire [15:0] addr_next = (addr_inc == W5100_RX_BASE) ? (W5100_RX_BASE - 16'h2000) :  // 0x6000 -> 0x4000
                            (addr_inc == W5100_MEM_END) ? (W5100_MEM_END - 16'h2000) :  // 0x8000 -> 0x6000
                            addr_inc;

    // -------------------------------------------------------
    // Dual-port backing store, split into two POWER-OF-TWO arrays so Gowin packs
    // them efficiently (a single odd-sized 18 KB array wastes ~4 BSRAM blocks):
    //   reg_mem  2 KB  -> W5100 0x0000-0x07FF   (1 BSRAM block)
    //   buf_mem 16 KB  -> W5100 0x4000-0x7FFF   (8 BSRAM blocks)
    // Port A = Apple II, port B = BL616 host; both on clk_logic. NO_CHANGE write
    // mode (read output holds during a write) -- the supported Gowin DPB mode; a
    // data-port access is read XOR write, so holding the read output is fine.
    // -------------------------------------------------------
    (* syn_ramstyle="block_ram" *) reg [7:0] reg_mem [0:2047];    // 0x0000-0x07FF
    (* syn_ramstyle="block_ram" *) reg [7:0] buf_mem [0:16383];   // 0x4000-0x7FFF

    // Port A (Apple II) region decode
    wire        a_reg  = (data_addr_r[15:11] == 5'd0);     // 0x0000-0x07FF
    wire        a_buf  = (data_addr_r[15:14] == 2'b01);    // 0x4000-0x7FFF
    wire [10:0] a_reg_i = data_addr_r[10:0];
    wire [13:0] a_buf_i = data_addr_r[13:0];
    wire        a_we   = data_access && !a2bus_if.rw_n;

    reg [7:0] a_reg_q, a_buf_q;
    reg       a_reg_sel_q, a_buf_sel_q;
    always @(posedge a2bus_if.clk_logic) begin
        if (a_we && a_reg) reg_mem[a_reg_i] <= a2bus_if.data; else a_reg_q <= reg_mem[a_reg_i];
        if (a_we && a_buf) buf_mem[a_buf_i] <= a2bus_if.data; else a_buf_q <= buf_mem[a_buf_i];
        a_reg_sel_q <= a_reg;
        a_buf_sel_q <= a_buf;
    end
    wire [7:0] a_q = a_reg_sel_q ? a_reg_q : a_buf_sel_q ? a_buf_q : 8'h00;

    // Port B (BL616 host, SPI SPACE 3) region decode -- W5100 addresses
    wire        b_reg  = (w5100_host_addr[15:11] == 5'd0);
    wire        b_buf  = (w5100_host_addr[15:14] == 2'b01);
    wire [10:0] b_reg_i = w5100_host_addr[10:0];
    wire [13:0] b_buf_i = w5100_host_addr[13:0];

    reg [7:0] b_reg_q, b_buf_q;
    reg       b_reg_sel_q, b_buf_sel_q;
    always @(posedge a2bus_if.clk_logic) begin
        if (w5100_host_wr && b_reg) reg_mem[b_reg_i] <= w5100_host_wdata; else b_reg_q <= reg_mem[b_reg_i];
        if (w5100_host_wr && b_buf) buf_mem[b_buf_i] <= w5100_host_wdata; else b_buf_q <= buf_mem[b_buf_i];
        b_reg_sel_q <= b_reg;
        b_buf_sel_q <= b_buf;
    end
    assign w5100_host_rdata = b_reg_sel_q ? b_reg_q : b_buf_sel_q ? b_buf_q : 8'h00;

    // DEBUG: count port-B writes and latch the last addr/data the card actually
    // received, independent of whether they land where expected.
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            dbg_portb_wr_count  <= 16'd0;
            dbg_portb_last_addr <= 16'd0;
            dbg_portb_last_wdata <= 8'd0;
        end else if (w5100_host_wr) begin
            dbg_portb_wr_count   <= dbg_portb_wr_count + 16'd1;
            dbg_portb_last_addr  <= w5100_host_addr;
            dbg_portb_last_wdata <= w5100_host_wdata;
        end
    end

    // -------------------------------------------------------
    // Indirect register writes + auto-increment
    // -------------------------------------------------------
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            mode_r      <= 8'h00;
            data_addr_r <= 16'h0000;
        end else if (wr_access) begin
            case (subreg)
                SUB_MR: begin
                    if (a2bus_if.data & W5100_MR_RST) begin
                        mode_r      <= 8'h00;       // software reset: clear control
                        data_addr_r <= 16'h0000;
                    end else begin
                        mode_r <= a2bus_if.data;
                    end
                end
                SUB_ADDR_HI: data_addr_r[15:8] <= a2bus_if.data;
                SUB_ADDR_LO: data_addr_r[7:0]  <= a2bus_if.data;
                default: ;                          // SUB_DATA handled below
            endcase
        end

        // Auto-increment after any data-port access (read or write) when MR.AI set
        if (data_access && (mode_r & W5100_MR_AI))
            data_addr_r <= addr_next;
    end

    // -------------------------------------------------------
    // Command-pending doorbell
    //   Sn_CR lives at W5100 0x0401 / 0x0501 / 0x0601 / 0x0701
    //   (socket block 0x0400-0x07FF, register offset 0x01)
    // -------------------------------------------------------
    wire sncr_write = data_access && !a2bus_if.rw_n
                      && (data_addr_r[15:10] == 6'b000001)   // 0x0400-0x07FF
                      && (data_addr_r[7:0]   == 8'h01);      // Sn_CR offset
    wire [1:0] sncr_socket = data_addr_r[9:8];

    integer s;
    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            cmd_pending_o <= 4'b0000;
        end else begin
            for (s = 0; s < 4; s = s + 1) begin
                if (sncr_write && (sncr_socket == s[1:0]))
                    cmd_pending_o[s] <= 1'b1;       // set wins over clear
                else if (cmd_pending_clr[s])
                    cmd_pending_o[s] <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------
    // Apple II read data
    // -------------------------------------------------------
    reg [7:0] dout;
    always @(*) begin
        case (subreg)
            SUB_MR:      dout = mode_r;
            SUB_ADDR_HI: dout = data_addr_r[15:8];
            SUB_ADDR_LO: dout = data_addr_r[7:0];
            default:     dout = a_q;                // SUB_DATA
        endcase
    end

    assign data_o   = dout;
    assign rd_en_o  = card_dev_sel && a2bus_if.rw_n;
    assign irq_n_o  = 1'b1;                          // polled in MVP

endmodule
