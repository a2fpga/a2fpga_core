// Stock P65C816_ALU vs fast F65C816_ALU (one-hot control): every control
// word (fstOp x secOp x fc x w16 = 256) x random L/R/CI/VI/SI/BCD, except the
// words that shift R and then use the adder (fstOp 0-3 with secOp 3, 6, 7):
// the fast ALU takes the adder's carry in from the carry flag alone, and
// gen_fast_mcode.py asserts the microcode has no such word.
module tb_alu_eq;
  import P65C816_pkg::ALUCtrl_r;
  import F65C816_pkg::FALUCtrl_r;
  logic [15:0] L, R; logic w16, BCD, CI, VI, SI;
  ALUCtrl_r  c0; FALUCtrl_r c1;
  logic CO0, VO0, SO0, ZO0, CO1, VO1, SO1, ZO1; logic [15:0] RES0, RES1, INT0, INT1;
  P65C816_ALU u0(.L(L),.R(R),.CTRL(c0),.w16(w16),.BCD(BCD),.CI(CI),.VI(VI),.SI(SI),.CO(CO0),.VO(VO0),.SO(SO0),.ZO(ZO0),.RES(RES0),.IntR(INT0));
  F65C816_ALU u1(.L(L),.R(R),.CTRL(c1),.w16(w16),.BCD(BCD),.CI(CI),.VI(VI),.SI(SI),.CO(CO1),.VO(VO1),.SO(SO1),.ZO(ZO1),.RES(RES1),.IntR(INT1));
  int errs = 0, n = 0;
  initial begin
    for (int cw = 0; cw < 256; cw++) begin
      c0 = cw[7:0];
      if (c0.fstOp < 3'd4 && (c0.secOp == 3'd3 || c0.secOp == 3'd6 || c0.secOp == 3'd7)) continue;
      c1.fstOp = c0.fstOp; c1.secOp = c0.secOp; c1.fc = c0.fc; c1.w16 = c0.w16;
      c1.FST = 8'd1 << c0.fstOp; c1.SEC = 8'd1 << c0.secOp;
      c1.SEL_ADD = (c0.secOp == 3'd3) | (c0.secOp == 3'd6) | (c0.secOp == 3'd7);
      for (int k = 0; k < 20000; k++) begin
        L = $urandom; R = $urandom; {w16, BCD, CI, VI, SI} = $urandom;
        if (k < 1024) begin L = {8'h00, k[7:0]}; R = {8'h00, k[9:8], 6'd0} ^ {k[7:0], 8'h00}; end
        #1; n++;
        if (CO0 !== CO1 || VO0 !== VO1 || SO0 !== SO1 || ZO0 !== ZO1 || RES0 !== RES1 || INT0 !== INT1) begin
          errs++;
          if (errs < 15) $display("MISMATCH ctrl f%0d s%0d fc%b w%b L=%04h R=%04h w16=%b BCD=%b CI=%b VI=%b SI=%b | ref CO%b VO%b SO%b ZO%b RES=%04h INT=%04h | fast CO%b VO%b SO%b ZO%b RES=%04h INT=%04h",
            c0.fstOp, c0.secOp, c0.fc, c0.w16, L, R, w16, BCD, CI, VI, SI, CO0, VO0, SO0, ZO0, RES0, INT0, CO1, VO1, SO1, ZO1, RES1, INT1);
        end
      end
    end
    $display("%0d vectors, %0d mismatches — %s", n, errs, errs ? "FAIL" : "PASS");
    $finish;
  end
endmodule
