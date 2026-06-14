module i2s_receiver
(
	input        reset,
	input        clk,

	input i2s_bclk,
	input i2s_lrclk,
	input i2s_data,
    input i2s_data_shift_strobe,
    input i2s_data_load_strobe,
	output signed [15:0] i2s_sample_l,
	output signed [15:0] i2s_sample_r
);

	reg [15:0] data_shift  = 16'h0000;
    reg [15:0] i2s_word_l = 16'h0000;
    reg [15:0] i2s_word_r = 16'h0000;

    always @(posedge clk) begin
        if (i2s_data_shift_strobe) begin
            data_shift <= {data_shift[14:0], i2s_data};
        end
    end

    always @(posedge clk) begin
        if (i2s_data_load_strobe) begin
			// lrclk has already toggled at this point, so use opposite of i2s_lrclk
			if (i2s_lrclk) i2s_word_l <= data_shift;
			else i2s_word_r <= data_shift;
        end
    end

	assign i2s_sample_l = i2s_word_l;
	assign i2s_sample_r = i2s_word_r;

endmodule