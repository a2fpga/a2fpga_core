module tb_addsub_eq;
  logic [15:0] A, B; logic CI, ADD, BCD, w16;
  logic [15:0] S0, S1; logic CO0, CO1, VO0, VO1;
  P65C816_AddSubBCD u0(.A(A),.B(B),.CI(CI),.ADD(ADD),.BCD(BCD),.w16(w16),.S(S0),.CO(CO0),.VO(VO0));
  F65C816_AddSubBCD u1(.A(A),.B(B),.CI(CI),.ADD(ADD),.BCD(BCD),.w16(w16),.S(S1),.CO(CO1),.VO(VO1));
  int errs = 0, n = 0;
  task check();
    #1;
    n++;
    if (S0 !== S1 || CO0 !== CO1 || VO0 !== VO1) begin
      errs++;
      if (errs < 20) $display("MISMATCH A=%04h B=%04h CI=%b ADD=%b BCD=%b w16=%b : ref S=%04h CO=%b VO=%b  fast S=%04h CO=%b VO=%b",
                              A,B,CI,ADD,BCD,w16,S0,CO0,VO0,S1,CO1,VO1);
    end
  endtask
  initial begin
    // exhaustive 8-bit operand space, both widths (upper bytes zero), all mode bits
    for (int m = 0; m < 16; m++) begin
      {w16, CI, ADD, BCD} = m[3:0];
      for (int a = 0; a < 256; a++) for (int b = 0; b < 256; b++) begin
        A = a[15:0]; B = b[15:0]; check();
      end
    end
    // exhaustive upper-byte space with random lower bytes, 16-bit, all modes
    for (int m = 0; m < 8; m++) begin
      w16 = 1; {CI, ADD, BCD} = m[2:0];
      for (int a = 0; a < 256; a++) for (int b = 0; b < 256; b++) begin
        A = {a[7:0], $urandom_range(0,255)}; B = {b[7:0], $urandom_range(0,255)}; check();
      end
    end
    // random 16-bit
    for (int r = 0; r < 2000000; r++) begin
      A = $urandom; B = $urandom; {w16, CI, ADD, BCD} = $urandom; check();
    end
    $display("%0d vectors, %0d mismatches — %s", n, errs, errs ? "FAIL" : "PASS");
    $finish;
  end
endmodule
