// audio_timing.sv
// Fractional-N timing generator using $clog2-sized accumulators.
// Generates exact-average AUDIO fs, I2S BCLK, and LRCLK from fast clk.
// Bounded jitter: ±1 clk tick. No long-term drift.

module audio_timing #(
  parameter int unsigned CLK_RATE        = 24_576_000, // Hz of input clk
  parameter int unsigned AUDIO_RATE      = 48_000,     // fs
  parameter int unsigned BITS_PER_SAMPLE = 16,         // bits per channel
  // Typically 2*BITS_PER_SAMPLE (stereo, left+right)
  parameter int unsigned BCLK_PER_LRCLK  = (2 * BITS_PER_SAMPLE),
  parameter bit          I2S_STANDARD    = 1'b1        // 0=left-justified, 1=standard I2S (1-bit delay)
)(
  input  logic reset,
  input  logic clk,

  output logic audio_clk,               // 1-cycle pulse at fs
  output logic i2s_bclk,                // I2S bit clock
  output logic i2s_lrclk,               // I2S left/right select (fs, ~50%)
  output logic i2s_data_shift_strobe,   // pulse on BCLK falling edge
  output logic i2s_data_load_strobe     // pulse one BCLK edge after LR edge
);

  // ----------------------------
  // Derived frequencies
  // ----------------------------
  localparam int unsigned FS_HZ         = AUDIO_RATE;
  localparam int unsigned LR_EDGE_HZ    = 2 * FS_HZ;                    // LR toggles each half-frame
  localparam int unsigned BCLK_HZ       = FS_HZ * BCLK_PER_LRCLK;       // bit clock
  localparam int unsigned BCLK_EDGE_HZ  = 2 * BCLK_HZ;                  // square wave edges

  // ----------------------------
  // Accumulator width
  // ----------------------------
  localparam int unsigned ACC_WIDTH = $clog2(CLK_RATE);
  typedef logic [ACC_WIDTH:0] acc_t; // +1 for overflow compare

  // Accumulators
  acc_t acc_fs, acc_lr, acc_bedge;
  acc_t acc_next;

  // State
  logic fs_pulse_r;
  logic lrclk_r, lrclk_prev;
  logic bclk_r,  bclk_prev;

  // Edge flags
  logic lr_edge_pulse;
  logic b_edge_pulse;
  logic b_fall_pulse;

  // Load-strobe delay
  logic load_pending_std;      // For standard I2S delay counting
  logic [1:0] delay_counter;   // For standard I2S 1-bit delay
  logic load_pending_lj;       // For left-justified immediate load  
  logic load_strobe_r;

  // ----------------------------
  // Main sequential process
  // ----------------------------
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      acc_fs        <= '0;
      acc_lr        <= '0;
      acc_bedge     <= '0;
      fs_pulse_r    <= 1'b0;
      lrclk_r       <= 1'b0;
      lrclk_prev    <= 1'b0;
      bclk_r        <= 1'b0;
      bclk_prev     <= 1'b0;
      lr_edge_pulse <= 1'b0;
      b_edge_pulse  <= 1'b0;
      b_fall_pulse  <= 1'b0;
      load_pending_std <= 1'b0;
      delay_counter <= 2'b00;
      load_pending_lj <= 1'b0;
      load_strobe_r <= 1'b0;
    end else begin
      // -------- fs pulse (sample_ce) --------
      fs_pulse_r <= 1'b0;
      acc_next   = acc_fs + FS_HZ;
      if (acc_next >= CLK_RATE) begin
        acc_fs     <= acc_next - CLK_RATE;
        fs_pulse_r <= 1'b1;
      end else begin
        acc_fs <= acc_next;
      end

      // -------- LRCLK toggle edges --------
      lr_edge_pulse <= 1'b0;
      acc_next = acc_lr + LR_EDGE_HZ;
      if (acc_next >= CLK_RATE) begin
        acc_lr        <= acc_next - CLK_RATE;
        lrclk_r       <= ~lrclk_r;
        lr_edge_pulse <= 1'b1;
      end else begin
        acc_lr <= acc_next;
      end

      // -------- BCLK toggle edges --------
      b_edge_pulse <= 1'b0;
      acc_next = acc_bedge + BCLK_EDGE_HZ;
      if (acc_next >= CLK_RATE) begin
        acc_bedge     <= acc_next - CLK_RATE;
        bclk_r        <= ~bclk_r;
        b_edge_pulse  <= 1'b1;
      end else begin
        acc_bedge <= acc_next;
      end

      // Register previous values for edge detection
      lrclk_prev <= lrclk_r;
      bclk_prev  <= bclk_r;

      // Falling edge of BCLK (for shift strobe)
      b_fall_pulse <= (bclk_prev == 1'b1) && (bclk_r == 1'b0) && b_edge_pulse;

      // Load strobe: format-dependent timing
      if (I2S_STANDARD) begin
        // Standard I2S: load after 1-bit delay (one extra BCLK cycle)
        if (lr_edge_pulse) begin
          load_pending_std <= 1'b1;
          delay_counter <= 2'b00;
          load_strobe_r <= 1'b0;
        end else if (load_pending_std && b_edge_pulse) begin
          delay_counter <= delay_counter + 1;
          if (delay_counter == 2'b10) begin  // After 2 BCLK edges (1-bit delay)
            load_strobe_r <= 1'b1;   // Fire after delay
            load_pending_std <= 1'b0;
            delay_counter <= 2'b00;
          end else begin
            load_strobe_r <= 1'b0;
          end
        end else begin
          load_strobe_r <= 1'b0;
        end
      end else begin
        // Left-justified: load immediately after LR edge (original behavior)
        if (lr_edge_pulse) begin
          load_pending_lj <= 1'b1;
          load_strobe_r <= 1'b0;
        end else if (load_pending_lj && b_edge_pulse) begin
          load_strobe_r <= 1'b1;   // one-cycle pulse
          load_pending_lj <= 1'b0;
        end else begin
          load_strobe_r <= 1'b0;
        end
      end
    end
  end

  // ----------------------------
  // Outputs
  // ----------------------------
  assign audio_clk             = fs_pulse_r;
  assign i2s_bclk              = bclk_r;
  assign i2s_lrclk             = lrclk_r;
  assign i2s_data_shift_strobe = b_fall_pulse; // change to rising if preferred
  assign i2s_data_load_strobe  = load_strobe_r;

endmodule
