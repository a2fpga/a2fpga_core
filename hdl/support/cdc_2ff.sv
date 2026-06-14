
module cdc_2ff (
  input  logic clk,
  input  logic i,
  output logic o
);

  logic ff1 /* synthesis syn_keep=1 */;
  logic ff2 /* synthesis syn_keep=1 */;

  always_ff @(posedge clk) begin
    ff1 <= i;
    ff2 <= ff1;
  end

  assign o = ff2;

endmodule