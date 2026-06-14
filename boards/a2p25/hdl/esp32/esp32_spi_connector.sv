// Re-implementation per boards/a2p25/docs/ESP32_SPI_PROTOCOL.md
module esp32_spi_connector #(
  parameter USE_SYNC    = 1,
  parameter USE_CRC     = 0,
  parameter IDLE_TO_CYC = 5_400_000
)(
  input  wire clk,
  input  wire rst_n,
  input  wire sclk,
  input  wire mosi,
  output wire miso,
  // I2S debug inputs (directly exposed via registers)
  input  wire signed [15:0] i2s_sample_l,
  input  wire signed [15:0] i2s_sample_r,
  // FPGA diagnostic counters (read-only via reg11-reg15)
  input  wire [15:0] es5503_access_counter,  // All ES5503 bus events detected
  input  wire [15:0] es5503_tx_counter,      // ES5503 packets transmitted
  input  wire        cam_overwrite_flag       // Sticky: serializer overwrite detected
);

  // Registers (16 x 8-bit)
  reg [7:0] reg0,reg1,reg2,reg3,reg4,reg5,reg6,reg7,reg8,reg9,reg10,reg11,reg12,reg13,reg14,reg15;
  localparam [7:0] DEVICE_ID0="A", DEVICE_ID1="2", DEVICE_ID2="F", DEVICE_ID3="P";
  localparam [7:0] PROTO_VER=8'h01;
  wire [7:0] CAP0 = {6'b0, USE_CRC[0], 1'b1};

  // I2S debug: pattern detection for 0xCAFE (left) / 0xBABE (right)
  localparam [15:0] I2S_TEST_PATTERN_L = 16'hCAFE;
  localparam [15:0] I2S_TEST_PATTERN_R = 16'hBABE;
  reg [7:0] i2s_match_count;
  reg i2s_locked;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i2s_match_count <= 8'd0;
      i2s_locked <= 1'b0;
    end else begin
      // Check for pattern match
      if (i2s_sample_l == $signed(I2S_TEST_PATTERN_L) &&
          i2s_sample_r == $signed(I2S_TEST_PATTERN_R)) begin
        if (i2s_match_count < 8'd255) i2s_match_count <= i2s_match_count + 1;
        if (i2s_match_count >= 8'd16) i2s_locked <= 1'b1;  // Lock after 16 consecutive matches
      end else begin
        i2s_match_count <= 8'd0;
        i2s_locked <= 1'b0;
      end
    end
  end

  // I2S debug registers (directly mapped, no writes allowed)
  // reg6: I2S_L high byte, reg7: I2S_L low byte
  // reg8: I2S_R high byte, reg9: I2S_R low byte
  // reg10: I2S status (bit0=locked, bit1-7=match_count[6:0])
  wire [7:0] i2s_reg6 = i2s_sample_l[15:8];
  wire [7:0] i2s_reg7 = i2s_sample_l[7:0];
  wire [7:0] i2s_reg8 = i2s_sample_r[15:8];
  wire [7:0] i2s_reg9 = i2s_sample_r[7:0];
  wire [7:0] i2s_reg10 = {i2s_match_count[6:0], i2s_locked};

  // FPGA diagnostic registers (read-only)
  // reg11: es5503_access_counter high byte (all bus events detected)
  // reg12: es5503_access_counter low byte
  // reg13: es5503_tx_counter high byte (packets transmitted)
  // reg14: es5503_tx_counter low byte
  // reg15: {7'b0, cam_overwrite_flag}
  wire [7:0] diag_reg11 = es5503_access_counter[15:8];
  wire [7:0] diag_reg12 = es5503_access_counter[7:0];
  wire [7:0] diag_reg13 = es5503_tx_counter[15:8];
  wire [7:0] diag_reg14 = es5503_tx_counter[7:0];
  wire [7:0] diag_reg15 = {7'b0, cam_overwrite_flag};

  // 256B memory (SPACE 0), synchronous read (1-cycle latency)
  reg [7:0] mem [0:255];
  reg [7:0] mem_rd_data_q; reg mem_rd_valid_q;

  // Wires to proto
  wire        reg_wr_req; wire [6:0] reg_idx; wire [7:0] reg_wdata; reg [7:0] reg_rdata;
  wire        mem_wr_en; wire [2:0] mem_space; wire [23:0] mem_wr_addr; wire [7:0] mem_wr_data;
  wire        mem_rd_req; wire [2:0] mem_rd_space; wire [23:0] mem_rd_addr; wire mem_rd_valid; wire [7:0] mem_rd_data;

  // Register read mux (regs 6-10 are I2S debug, regs 11-15 are FPGA diagnostics, all read-only)
  always @* begin
    case (reg_idx[3:0])
      4'h0: reg_rdata = reg0;  4'h1: reg_rdata = reg1;   4'h2: reg_rdata = reg2;   4'h3: reg_rdata = reg3;
      4'h4: reg_rdata = reg4;  4'h5: reg_rdata = reg5;   4'h6: reg_rdata = i2s_reg6;  4'h7: reg_rdata = i2s_reg7;
      4'h8: reg_rdata = i2s_reg8;  4'h9: reg_rdata = i2s_reg9;   4'hA: reg_rdata = i2s_reg10;  4'hB: reg_rdata = diag_reg11;
      4'hC: reg_rdata = diag_reg12; 4'hD: reg_rdata = diag_reg13;  4'hE: reg_rdata = diag_reg14;  default: reg_rdata = diag_reg15;
    endcase
  end

  // Register writes and reset defaults
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg0<=DEVICE_ID0; reg1<=DEVICE_ID1; reg2<=DEVICE_ID2; reg3<=DEVICE_ID3; reg4<=PROTO_VER; reg5<=CAP0;
      reg6<=8'h00; reg7<=8'h00; reg8<=8'h00; reg9<=8'h00; reg10<=8'h00; reg11<=8'h00; reg12<=8'h00; reg13<=8'h00; reg14<=8'h00; reg15<=8'h00;
    end else if (reg_wr_req) begin
      case (reg_idx[3:0])
        4'h0: reg0  <= reg_wdata; 4'h1: reg1  <= reg_wdata; 4'h2: reg2  <= reg_wdata; 4'h3: reg3  <= reg_wdata;
        4'h4: reg4  <= reg_wdata; 4'h5: reg5  <= reg_wdata; 4'h6: reg6  <= reg_wdata; 4'h7: reg7  <= reg_wdata;
        4'h8: reg8  <= reg_wdata; 4'h9: reg9  <= reg_wdata; 4'hA: reg10 <= reg_wdata; 4'hB: reg11 <= reg_wdata;
        4'hC: reg12 <= reg_wdata; 4'hD: reg13 <= reg_wdata; 4'hE: reg14 <= reg_wdata; default: reg15 <= reg_wdata;
      endcase
    end
  end

  // Memory write (SPACE 0)
  always @(posedge clk) begin
    if (mem_wr_en && (mem_space==3'd0)) begin mem[mem_wr_addr[7:0]] <= mem_wr_data; end
  end

  // Memory read (1-cycle latency)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin mem_rd_valid_q<=0; mem_rd_data_q<=8'h00; end
    else begin
      mem_rd_valid_q<=0;
      if (mem_rd_req) begin mem_rd_data_q <= (mem_rd_space==3'd0) ? mem[mem_rd_addr[7:0]] : 8'hFF; mem_rd_valid_q<=1; end
    end
  end
  assign mem_rd_data  = mem_rd_data_q;
  assign mem_rd_valid = mem_rd_valid_q;

  // Instantiate proto
  esp32_spi_proto_proc #(
    .USE_SYNC(USE_SYNC), .USE_CRC(USE_CRC), .IDLE_TO_CYC(IDLE_TO_CYC)
  ) proto (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .miso(miso),
    .reg_wr_req(reg_wr_req), .reg_idx(reg_idx), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .mem_wr_en(mem_wr_en), .mem_space(mem_space), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
    .mem_rd_req(mem_rd_req), .mem_rd_space(mem_rd_space), .mem_rd_addr(mem_rd_addr), .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data)
  );

endmodule
