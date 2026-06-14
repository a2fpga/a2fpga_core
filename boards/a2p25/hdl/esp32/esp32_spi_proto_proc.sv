// Re-implementation per boards/a2p25/docs/ESP32_SPI_PROTOCOL.md
module esp32_spi_proto_proc #(
  parameter USE_SYNC    = 1,
  parameter USE_CRC     = 0,
  parameter IDLE_TO_CYC = 54_000
)(
  input  wire        clk,
  input  wire        rst_n,
  input  wire        sclk,
  input  wire        mosi,
  output wire        miso,

  // Register file interface
  output reg         reg_wr_req,
  output reg  [6:0]  reg_idx,
  output reg  [7:0]  reg_wdata,
  input  wire [7:0]  reg_rdata,

  // Memory/XFER interface
  output reg         mem_wr_en,
  output reg  [2:0]  mem_space,
  output reg  [23:0] mem_wr_addr,
  output reg  [7:0]  mem_wr_data,

  output reg         mem_rd_req,
  output reg  [2:0]  mem_rd_space,
  output reg  [23:0] mem_rd_addr,
  input  wire        mem_rd_valid,
  input  wire [7:0]  mem_rd_data
);

  // Sync SCLK/MOSI to clk
  reg sclk_q1, sclk_q2, mosi_q1, mosi_q2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin sclk_q1<=0; sclk_q2<=0; mosi_q1<=0; mosi_q2<=0; end
    else begin sclk_q1<=sclk; sclk_q2<=sclk_q1; mosi_q1<=mosi; mosi_q2<=mosi_q1; end
  end
  wire sclk_rise = (sclk_q2==0) && (sclk_q1==1);
  wire sclk_fall = (sclk_q2==1) && (sclk_q1==0);

  // Idle reframing
  reg [31:0] idle_ctr;
  wire idle_expired = (idle_ctr==IDLE_TO_CYC);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) idle_ctr <= 0;
    else if (sclk_rise || sclk_fall) idle_ctr <= 0;
    else if (!idle_expired) idle_ctr <= idle_ctr + 1'b1;
  end

  // Bit/byte shifters
  reg [2:0] bit_cnt;
  reg [7:0] rx_shift, tx_shift;
  reg       byte_rx_stb;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin bit_cnt<=0; rx_shift<=8'h00; byte_rx_stb<=0; end
    else begin
      byte_rx_stb <= 0;
      if (sclk_rise) begin
                rx_shift[7-bit_cnt] <= mosi_q2; // positional load;
        bit_cnt  <= bit_cnt + 3'd1;
        if (bit_cnt==3'd7) begin bit_cnt<=0; byte_rx_stb<=1; end
      end
      if (idle_expired) bit_cnt<=0;
    end
  end

  // TX next-byte preparation and loading (MSB-first)
  localparam [1:0] TX_STAT=2'd0, TX_REG=2'd1, TX_DATA=2'd2;
  reg [1:0] tx_next_mode;
  reg [7:0] tx_latch;
  reg       tx_load_pending, tx_load_armed;
  reg       tx_immediate_load;
  // Dedicated first-byte loader: 2'b01 = REG, 2'b10 = DATA
  reg [1:0] pending_first_load;

  // Status bits
  localparam [7:0] PROTO_VER = 8'h01;
  reg [3:0] status_ver; reg status_align, status_crcerr, status_busy, status_ok;
  wire [7:0] status_byte = {status_ver, status_align, status_crcerr, status_busy, status_ok};

  // FSM states
  localparam [4:0]
    ST_IDLE=0, ST_SYNC0=1, ST_SYNC1=2, ST_OPCODE=3, ST_HDRCRC=4,
    ST_REG_RW=5, ST_X0=6, ST_XA0=7, ST_XA1=8, ST_XA2=9, ST_XL0=10,
    ST_XL1=11, ST_XHDRC=12, ST_XPAY_WR=13, ST_XPAY_RD_DMY=14,
    ST_XPAY_RD=15, ST_XPLCRC=16, ST_DONE=17, ST_ERR=18;
  reg [4:0] st;

  // Header fields
  reg op_is_read; reg [6:0] op_reg;
  reg [7:0] sub0; reg [23:0] addr; reg [15:0] len, len_cnt;
  reg sub_dir, sub_crc, sub_inc; reg [2:0] sub_space;
  reg [7:0] crc_hdr, crc_pl; // CRC reserved

  // Read pipeline buffer
  reg [7:0] rd_buf; reg rd_buf_valid;
  // One-shot to request that the very next byte be the just-addressed register value
  reg [7:0] reg_read_value; reg load_reg_read_next;

  // Shift out data on SCLK falling edge
  assign miso = tx_shift[7];
  // Load the next transmit byte exactly on SCLK falling edges at byte boundaries
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift <= 8'hFF;
    end else if (sclk_fall) begin
      if (bit_cnt==3'd0) begin
        // Decide the next byte: first, honor any explicit one-shot flags
        reg [7:0] nxt;
        // Priority 1: if we are in the reg read return byte, serve reg_rdata
        if (st==ST_REG_RW && op_is_read && (op_reg!=7'd127)) begin
          nxt = reg_rdata;
        end else if (load_reg_read_next) begin
          nxt = reg_read_value;
          `ifdef TB_DEBUG
            $display("[DBG] LOAD REG nxt=0x%02h at fall t=%0t", nxt, $time);
          `endif
        end else begin
          nxt = status_byte; // default during headers
          case (st)
            ST_XPAY_RD_DMY: nxt = 8'hFF; // one dummy byte
            ST_XPAY_RD:     nxt = (rd_buf_valid ? rd_buf : 8'hFF);
            default:        nxt = status_byte;
          endcase
        end
        tx_shift <= nxt;
        `ifdef TB_DEBUG
          $display("[DBG] LOAD st=%0d nxt=0x%02h op_rd=%0d op_reg=%0d bit_cnt=%0d t=%0t", st, nxt, op_is_read, op_reg, bit_cnt, $time);
        `endif
      end else begin
        // shift MSB-first between falls
        tx_shift <= {tx_shift[6:0], 1'b1};
      end
    end
  end

  // Main sequential
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= ST_IDLE;
      status_ver<=PROTO_VER[3:0]; status_align<=0; status_crcerr<=0; status_busy<=0; status_ok<=1;
      op_is_read<=0; op_reg<=0; sub0<=0; addr<=0; len<=0; len_cnt<=0; sub_dir<=0; sub_crc<=0; sub_inc<=0; sub_space<=0;
      crc_hdr<=0; crc_pl<=0; rd_buf<=8'h00; rd_buf_valid<=0; tx_next_mode<=TX_STAT; load_reg_read_next<=1'b0;
      reg_wr_req<=0; reg_idx<=0; reg_wdata<=0; mem_wr_en<=0; mem_space<=0; mem_wr_addr<=0; mem_wr_data<=0; mem_rd_req<=0; mem_rd_space<=0; mem_rd_addr<=0;
    end else begin
      // one-shots
      reg_wr_req<=0; mem_wr_en<=0; mem_rd_req<=0; status_align<=0;

      if (idle_expired) begin
        st <= ST_IDLE; rd_buf_valid<=0; tx_next_mode<=TX_STAT; tx_load_pending<=0; tx_load_armed<=0;
      end

      // latch mem read data
      if (mem_rd_valid) begin rd_buf<=mem_rd_data; rd_buf_valid<=1; end

      if (byte_rx_stb) begin
        `ifdef TB_DEBUG
          $display("[DBG] RX_BYTE st=%0d rx_shift=0x%02h t=%0t", st, rx_shift, $time);
        `endif
        load_reg_read_next <= 1'b0;
        // Default: serve STATUS next during header unless overridden below
        tx_next_mode <= TX_STAT;
        tx_load_pending <= 1'b1;
        tx_load_armed <= 1'b1;
        case (st)
          ST_IDLE: begin
            status_ok<=1; status_crcerr<=0; status_busy<=0; crc_hdr<=0; rd_buf_valid<=0;
            if (USE_SYNC) begin
              // Expect first sync byte 0xA5 while in IDLE
              st <= (rx_shift==8'hA5) ? ST_SYNC1 : ST_IDLE;
            end else begin
              st <= ST_OPCODE;
            end
          end
          ST_SYNC0: begin
            // Unused in this simplified sync flow; stay in IDLE unless 0xA5 is seen in IDLE
            st <= ST_IDLE;
          end
          ST_SYNC1: begin
            // Expect second sync byte 0x5A, then proceed to opcode
            if (rx_shift==8'h5A) begin status_align<=1; st<=ST_OPCODE; crc_hdr<=0; end else st<=ST_IDLE;
          end

          ST_OPCODE: begin
            op_is_read <= rx_shift[7]; op_reg <= rx_shift[6:0]; rd_buf_valid<=0;
            if (rx_shift[6:0] != 7'd127) begin
              reg_idx <= rx_shift[6:0];
              if (rx_shift[7]) begin // READ
                // Latch register value now for next-byte transmit at fall edge
                reg_read_value <= reg_rdata;
                load_reg_read_next <= 1'b1;
                `ifdef TB_DEBUG
                  $display("[DBG] OPCODE read reg=%0d val=0x%02h t=%0t", rx_shift[6:0], reg_rdata, $time);
                `endif
                st <= ST_REG_RW;
              end else begin // WRITE
                st <= ST_REG_RW;
              end
            end else begin
              st <= ST_X0;
            end
          end

          ST_REG_RW: begin
            if (op_reg!=7'd127) begin
              if (op_is_read) begin st <= ST_DONE; end
              else begin
                reg_wdata<=rx_shift;
                reg_wr_req<=1;
                `ifdef TB_DEBUG
                  $display("[DBG] REG WRITE idx=%0d data=0x%02h t=%0t", op_reg, rx_shift, $time);
                `endif
                st<=ST_DONE;
              end
            end else st<=ST_ERR;
          end
          ST_DONE: begin
            // Treat like IDLE for next transaction
            if (USE_SYNC) begin
              st <= (rx_shift==8'hA5) ? ST_SYNC1 : ST_IDLE;
            end else begin
              st <= ST_OPCODE;
            end
          end
          ST_ERR: begin
            // Recover like IDLE
            if (USE_SYNC) begin
              st <= (rx_shift==8'hA5) ? ST_SYNC1 : ST_IDLE;
            end else begin
              st <= ST_OPCODE;
            end
          end

          // XFER header
          ST_X0:  begin sub0<=rx_shift; sub_dir<=rx_shift[0]; sub_space<=rx_shift[3:1]; sub_inc<=rx_shift[4]; sub_crc<=rx_shift[5]; addr<=0; len<=0; st<=ST_XA0; end
          ST_XA0: begin addr[7:0]  <= rx_shift; st<=ST_XA1; end
          ST_XA1: begin addr[15:8] <= rx_shift; st<=ST_XA2; end
          ST_XA2: begin addr[23:16]<= rx_shift; st<=ST_XL0; end
          ST_XL0: begin len[7:0]   <= rx_shift; st<=ST_XL1; end
          ST_XL1: begin len[15:8]  <= rx_shift; len_cnt<={rx_shift,len[7:0]}; mem_space<=sub_space; mem_rd_space<=sub_space; st <= (sub_dir?ST_XPAY_RD_DMY:ST_XPAY_WR); end

          // WRITE payload
          ST_XPAY_WR: begin
            if (len_cnt==0) begin st<=ST_DONE; end
            else begin
              if (mem_space==3'd0) begin mem_wr_addr<=addr; mem_wr_data<=rx_shift; mem_wr_en<=1; end
              len_cnt <= len_cnt - 16'd1; if (sub_inc) addr<=addr+24'd1; if (len_cnt==16'd1) st<=ST_DONE; end
          end

          // READ payload with dummy
          ST_XPAY_RD_DMY: begin mem_rd_addr<=addr; mem_rd_req<=1; st<=ST_XPAY_RD; end
          ST_XPAY_RD: begin
            // At each next byte boundary, the fall-edge loader outputs data or 0xFF.
            // Here we only manage the read pipeline counters and prefetch.
            if (len_cnt==0) begin st<=ST_DONE; end
            else begin
              if (rd_buf_valid) begin // consume one
                len_cnt <= len_cnt - 16'd1; rd_buf_valid<=0;
                // prefetch next if more
                if (len_cnt>16'd1) begin mem_rd_addr <= (sub_inc? (addr+24'd1):addr); mem_rd_req<=1; if (sub_inc) addr<=addr+24'd1; end
              end
            end
          end

          ST_DONE: begin st<=ST_IDLE; tx_next_mode<=TX_STAT; rd_buf_valid<=0; end
          ST_ERR : begin st<=ST_IDLE; tx_next_mode<=TX_STAT; rd_buf_valid<=0; status_ok<=0; end
        endcase
      end
    end
  end

endmodule
