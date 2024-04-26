
module audio_out
#(
	parameter CLK_RATE = 24576000,
	parameter AUDIO_RATE = 48000
)
(
	input        reset,
	input        clk,

	input  [31:0] flt_rate,
	input  [39:0] cx,
	input   [7:0] cx0,
	input   [7:0] cx1,
	input   [7:0] cx2,
	input  [23:0] cy0,
	input  [23:0] cy1,
	input  [23:0] cy2,

	input        is_signed,
	input [15:0] core_l,
	input [15:0] core_r,

	output audio_clk,
	output [15:0] audio_l,
	output [15:0] audio_r
);
    localparam AUDIO_CLK_COUNT = CLK_RATE / AUDIO_RATE;
    logic [$clog2(AUDIO_CLK_COUNT)-1:0] audio_counter_r;
	reg sample_ce;
	always_ff @(posedge clk)
    begin
        audio_counter_r <= (audio_counter_r == AUDIO_CLK_COUNT) ? 1'd0 : audio_counter_r + 1'd1;
        sample_ce <= audio_counter_r == AUDIO_CLK_COUNT;
    end
	assign audio_clk = sample_ce;

	reg flt_ce;
	reg [31:0] cnt = 0;
	always @(posedge clk, posedge reset) begin
		if(reset) begin
			cnt <= 0;
			flt_ce <= 0;
		end
		else begin
			flt_ce <= 0;
			cnt <= cnt + {flt_rate[30:0],1'b0};
			if(cnt >= CLK_RATE) begin
				cnt <= cnt - CLK_RATE;
				flt_ce <= 1;
			end
		end
	end

	reg [15:0] cl,cr;
	reg [15:0] cl1,cl2;
	reg [15:0] cr1,cr2;
	always @(posedge clk) begin
		cl1 <= core_l; cl2 <= cl1;
		if(cl2 == cl1) cl <= cl2;

		cr1 <= core_r; cr2 <= cr1;
		if(cr2 == cr1) cr <= cr2;
	end

	reg a_en1 = 0, a_en2 = 0;
	reg  [1:0] dly1 = 0;
	reg [14:0] dly2 = 0;
	always @(posedge clk, posedge reset) begin

		if(reset) begin
			dly1 <= 0;
			dly2 <= 0;
			a_en1 <= 0;
			a_en2 <= 0;
		end
		else begin
			if(flt_ce) begin
				if(~&dly1) dly1 <= dly1 + 1'd1;
				else a_en1 <= 1;
			end

			if(sample_ce) begin
				if(!dly2[13]) dly2 <= dly2 + 1'd1;
				else a_en2 <= 1;
			end
		end
	end

	wire [15:0] acl, acr;
	IIR_filter #(.use_params(0)) IIR_filter
	(
		.clk(clk),
		.reset(reset),

		.ce(flt_ce & a_en1),
		.sample_ce(sample_ce),

		.cx(cx),
		.cx0(cx0),
		.cx1(cx1),
		.cx2(cx2),
		.cy0(cy0),
		.cy1(cy1),
		.cy2(cy2),

		.input_l({~is_signed ^ cl[15], cl[14:0]}),
		.input_r({~is_signed ^ cr[15], cr[14:0]}),
		.output_l(acl),
		.output_r(acr)
	);

	wire [15:0] adl;
	DC_blocker dcb_l
	(
		.clk(clk),
		.ce(sample_ce),
		.mute(~a_en2),
		.din(acl),
		.dout(adl)
	);

	wire [15:0] adr;
	DC_blocker dcb_r
	(
		.clk(clk),
		.ce(sample_ce),
		.mute(~a_en2),
		.din(acr),
		.dout(adr)
	);

	assign audio_l = adl;
	assign audio_r = adr;


endmodule
