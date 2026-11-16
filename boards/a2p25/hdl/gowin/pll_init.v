`timescale  1ns/1ns


module PLL_INIT #
(   parameter       CLK_PERIOD  = 20       
,   parameter       MULTI_FAC   = 24
)
(   input           I_RST
,   input           I_MD_CLK

,   output          O_RST

,   output          O_MD_INC
,   output [1:0]    O_MD_OPC
,   output [7:0]    O_MD_WR_DATA
,   input  [7:0]    I_MD_RD_DATA

,   input           I_LOCK
,   output          O_LOCK

,   input PLL_INIT_BYPASS
,   output [7:0] MDRDO
,   input [1:0] MDOPC
,   input MDAINC
,   input [7:0] MDWDI


);

`ifdef SIM
`define     DL     #1
`else
`define     DL
`endif

`ifdef  SIM
localparam  WAIT_TIME   = 'd8_000;
localparam  LOCK_TIME   = 'd2_000;
`else
localparam  WAIT_TIME   = 'd800_000;
localparam  LOCK_TIME   = 'd200_000;
`endif
localparam  WAIT_CNT    = (WAIT_TIME + CLK_PERIOD - 1) / CLK_PERIOD;    //! 1ms
localparam  LOCK_CNT    = (LOCK_TIME + CLK_PERIOD - 1) / CLK_PERIOD;
localparam  WW          = $clog2(WAIT_CNT + 1);
localparam  LW          = $clog2(LOCK_CNT + 1);

localparam  INIT_STEP_0 = 4'd0
,           INIT_STEP_1 = 4'd1
,           INIT_STEP_2 = 4'd2
,           INIT_STEP_3 = 4'd3
,           INIT_STEP_4 = 4'd4
,           INIT_STEP_5 = 4'd5
,           INIT_STEP_6 = 4'd6
,           INIT_STEP_7 = 4'd7
,           INIT_STEP_8 = 4'd8
,           INIT_STEP_9 = 4'd9
;

reg  [   1:0]   rEnable     = 'b0;

reg             rRomRd      = 'b0;
reg  [   7:0]   rRomAddr    = 'b0;
reg  [  24:0]   rRomData    = 'b0;

reg  [   2:0]   rReqCnt     = 'b0;
reg  [   4:0]   rLoopCnt    = 'b0;

reg  [   3:0]   rChkOkCnt   = 'b0;
reg  [   5:0]   rChkStart   = 'b0;

reg  [   3:0]   rInitFsmC   = INIT_STEP_0   ;
reg  [   3:0]   rInitFsmN   = INIT_STEP_1   ;

reg  [   7:0]   rMdAddr     = 'b0;

reg             rMdInc      = 'b0;
reg  [   1:0]   rMdOpc      = 'b0;
reg  [   7:0]   rMdDOut     = 'b0;

reg  [   7:0]   rChkFlag    = 'b0;

reg             rLockReg    = 'b0;
reg  [LW-1:0]   rLockCnt    = 'b0;
reg             rLocked     = 'b0;
reg  [WW-1:0]   rWaitCnt    = 'b0;

reg             rLastStep   = 'b0;

reg             rLockOut    = 'b0;

reg             rChkVld     = 'b0;
reg  [   7:0]   rRomAddrVld = 'b0;

reg             rRstOut     = 1'b1;

wire            wEnable     = rEnable[1];
wire [   7:0]   wMdAddrNext = rMdAddr + 2'd1;
wire            wLocked     = (rLockCnt >= LOCK_CNT);

wire            wIsStep0    = (rInitFsmC == INIT_STEP_0);
wire            wIsStep1    = (rInitFsmC == INIT_STEP_1);
wire            wIsStep2    = (rInitFsmC == INIT_STEP_2);
wire            wIsStep3    = (rInitFsmC == INIT_STEP_3);
wire            wIsStep4    = (rInitFsmC == INIT_STEP_4);
wire            wIsStep5    = (rInitFsmC == INIT_STEP_5);
wire            wIsStep6    = (rInitFsmC == INIT_STEP_6);
wire            wIsStep7    = (rInitFsmC == INIT_STEP_7);
wire            wIsStep8    = (rInitFsmC == INIT_STEP_8);
wire            wIsStep9    = (rInitFsmC == INIT_STEP_9);

wire            wReqOver    = ~rRomData[24];
wire            wMdrpReq    = rRomData[24];
wire            wWaitLock   = rReqCnt[2];//(rReqCnt == 4);


wire [   7:0]   wReqAddr    = rRomData[16+:8];
wire [   7:0]   wReqMask    = rRomData[ 8+:8];
wire [   7:0]   wReqData    = rRomData[ 0+:8];


localparam  ROM_FILE = "";

reg  [  27:0]   rRomDReg    = 'b0;


reg    [27:0]  rRom    [63:0];   // ROM_FILE branch only; see ram_init below


always @ (posedge PLL_INIT_BYPASS or posedge I_MD_CLK or posedge I_RST) begin
    if (PLL_INIT_BYPASS || I_RST)  rEnable <=`DL 2'b00;
    else        rEnable <=`DL {rEnable[0], 1'b1};
end

generate
if (ROM_FILE != "") begin: ram_init_file
    initial begin
        $readmemh (ROM_FILE, rRom);
    end

    always @ (posedge I_MD_CLK) begin
        rRomDReg    <=`DL rRom[rRomAddr[5:0]];
    end
end else begin : ram_init
    // RESOURCE_AUDIT B7 (2026-11-15): the 64 x 28 init table used to be a
    // register array loaded with constants under ~rEnable[1]; GowinSynthesis
    // inferred a pROM from it and spent one 18 Kb BSRAM block per PLL_INIT
    // instance (two on the a2p25), and syn_romstyle did not move it. As a
    // case lookup it is plain LUT logic. Same contents, same registered
    // read timing (rRomDReg valid the cycle after rRomAddr), zero while
    // ~rEnable[1] as before.
    function automatic [27:0] rom_val (input [5:0] a);
        case (a)
        6'd00: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F03 :    (MULTI_FAC > 16)  ? 28'h10B_3F01 :                        28'h10B_3F00;
        6'd01: rom_val = 28'h10C_E080;
        6'd02: rom_val = 28'h111_0701;
        6'd03: rom_val = 28'h112_0C08;
        6'd04: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F03 :    (MULTI_FAC > 16)  ? 28'h10B_3F01 :                        28'h10B_3F00;
        6'd05: rom_val = 28'h10C_E080;
        6'd06: rom_val = 28'h111_0703;
        6'd07: rom_val = 28'h112_0C08;
        6'd08: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F03 :    (MULTI_FAC > 16)  ? 28'h10B_3F01 :                        28'h10B_3F00;
        6'd09: rom_val = 28'h10C_E0A0;
        6'd10: rom_val = 28'h111_0703;
        6'd11: rom_val = 28'h112_0C08;
        6'd12: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F03 :    (MULTI_FAC > 16)  ? 28'h10B_3F01 :                        28'h10B_3F00;
        6'd13: rom_val = 28'h10C_E0A0;
        6'd14: rom_val = 28'h111_0707;
        6'd15: rom_val = 28'h112_0C08;
        6'd16: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F07 :    (MULTI_FAC > 16)  ? 28'h10B_3F03 :                        28'h10B_3F01;
        6'd17: rom_val = 28'h10C_E0A0;
        6'd18: rom_val = 28'h111_0707;
        6'd19: rom_val = 28'h112_0C08;
        6'd20: rom_val = (MULTI_FAC > 34)  ? 28'h10B_3F05 :    (MULTI_FAC > 16)  ? 28'h10B_3F02 :                        28'h10B_3F01;
        6'd21: rom_val = 28'h10C_E0C0;
        6'd22: rom_val = 28'h111_0707;
        6'd23: rom_val = 28'h112_0C08;
        6'd24: rom_val = 28'h000_0000;
        6'd25: rom_val = 28'h000_0000;
        6'd26: rom_val = 28'h000_0000;
        6'd27: rom_val = 28'h000_0000;
        6'd28: rom_val = (MULTI_FAC > 34)  ? 28'h10B3F03 :    (MULTI_FAC > 16)  ? 28'h10B3F01 :                        28'h10B3F00;
        6'd29: rom_val = 28'h10CE080;
        6'd30: rom_val = 28'h1110702;
        6'd31: rom_val = 28'h1120C08;
        6'd32: rom_val = (MULTI_FAC > 34)  ? 28'h10B3F05 :    (MULTI_FAC > 16)  ? 28'h10B3F02 :                        28'h10B3F00;
        6'd33: rom_val = 28'h10CE080;
        6'd34: rom_val = 28'h1110703;
        6'd35: rom_val = 28'h1120C08;
        6'd36: rom_val = (MULTI_FAC > 34)  ? 28'h10B3F03 :    (MULTI_FAC > 16)  ? 28'h10B3F01 :                        28'h10B3F00;
        6'd37: rom_val = 28'h10CE0A0;
        6'd38: rom_val = 28'h1110704;
        6'd39: rom_val = 28'h112_0C08;
        6'd40: rom_val = (MULTI_FAC > 34)  ? 28'h10B3F04 :    (MULTI_FAC > 16)  ? 28'h10B3F02 :                        28'h10B3F00;
        6'd41: rom_val = 28'h10CE0A0;
        6'd42: rom_val = 28'h1110707;
        6'd43: rom_val = 28'h1120C08;
        6'd44: rom_val = (MULTI_FAC > 34)  ? 28'h10B3F03 :    (MULTI_FAC > 16)  ? 28'h10B3F01 :                        28'h10B3F00;
        6'd45: rom_val = 28'h10CE0C0;
        6'd46: rom_val = 28'h1110707;
        6'd47: rom_val = 28'h1120C08;
        6'd48: rom_val = 28'h000_0000;
        6'd49: rom_val = 28'h000_0000;
        6'd50: rom_val = 28'h000_0000;
        6'd51: rom_val = 28'h000_0000;
        6'd52: rom_val = 28'h000_0000;
        6'd53: rom_val = 28'h000_0000;
        6'd54: rom_val = 28'h000_0000;
        6'd55: rom_val = 28'h000_0000;
        6'd56: rom_val = 28'h000_0000;
        6'd57: rom_val = 28'h000_0000;
        6'd58: rom_val = 28'h000_0000;
        6'd59: rom_val = 28'h000_0000;
        6'd60: rom_val = 28'h000_0000;
        6'd61: rom_val = 28'h000_0000;
        6'd62: rom_val = 28'h000_0000;
        6'd63: rom_val = 28'h000_0000;
        default: rom_val = 28'h000_0000;
        endcase
    endfunction

    always @ (posedge I_MD_CLK) begin
        if (~rEnable[1])
            rRomDReg    <=`DL 28'h000_0000;
        else
            rRomDReg    <=`DL rom_val(rRomAddr[5:0]);
    end
end
endgenerate


always @ (*) begin
    casex (rChkFlag[5:0])
        6'b111_111  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1000;
        6'b011_111  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1000;
        6'b111_110  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1100;
        6'b111_10x  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1100;
        6'bx01_111  :   {rChkVld, rRomAddrVld} = 9'b1_0000_0100;
        6'b011_110  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1000;
        6'bxx0_111  :   {rChkVld, rRomAddrVld} = 9'b1_0000_0100;
        6'bx01_110  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1000;
        6'b011_10x  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1100;
        6'b111_0xx  :   {rChkVld, rRomAddrVld} = 9'b1_0001_0000;

        6'bxxx_011  :   {rChkVld, rRomAddrVld} = 9'b1_0001_1100;
        6'bxx0_110  :   {rChkVld, rRomAddrVld} = 9'b1_0010_0000;
        6'bx01_100  :   {rChkVld, rRomAddrVld} = 9'b1_0010_0100;
        6'b011_000  :   {rChkVld, rRomAddrVld} = 9'b1_0010_1000;
        6'b110_000  :   {rChkVld, rRomAddrVld} = 9'b1_0010_1100;
        6'bxxx_x01  :   {rChkVld, rRomAddrVld} = 9'b1_0000_0000;
        6'bxxx_010  :   {rChkVld, rRomAddrVld} = 9'b1_0000_0100;
        6'bxx0_100  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1000;
        6'bx01_000  :   {rChkVld, rRomAddrVld} = 9'b1_0000_1100;
        6'b010_000  :   {rChkVld, rRomAddrVld} = 9'b1_0001_0000;
        6'b100_000  :   {rChkVld, rRomAddrVld} = 9'b1_0001_0100;

        6'b000_000  :   {rChkVld, rRomAddrVld} = 9'b0_0000_0000;

        default     :   {rChkVld, rRomAddrVld} = 9'b0_0000_0000;
    endcase
end

always @ (posedge I_MD_CLK) begin
    rInitFsmC   <=`DL wEnable   ? rInitFsmN : INIT_STEP_0;
//!_____________________________________________________________________________
    rRomRd      <=`DL wEnable & (wIsStep1 | wIsStep6 & ~wWaitLock);
//!_____________________________________________________________________________
    rRomData    <=`DL rRomRd    ? rRomDReg[24:0] : rRomData;
//!_____________________________________________________________________________
    rRomAddr    <=`DL ~wEnable              ? 8'd0
                 :    (wIsStep3 & wReqOver) ? rRomAddrVld
                 :    rRomRd                ? rRomAddr + 1'd1
                 :                            rRomAddr;
//!_____________________________________________________________________________
    rLastStep   <=`DL wEnable & (wIsStep3 & wReqOver | rLastStep);
//!_____________________________________________________________________________
    rReqCnt     <=`DL ~wEnable              ? 3'd0
                 :    wIsStep7              ? 3'd0
                 :    wIsStep5              ? rReqCnt + 1'd1
                 :                            rReqCnt;
//!_____________________________________________________________________________
    rLoopCnt    <=`DL ~wEnable              ? 3'd0
                 :    wIsStep8              ? rLoopCnt + 1'd1
                 :                            rLoopCnt;
//!_____________________________________________________________________________
    rLockReg    <=`DL wEnable & I_LOCK;
//!_____________________________________________________________________________
    rLockCnt    <=`DL (~wEnable)            ? {LW{1'b0}}
                 :    (~wIsStep7&~wIsStep9) ? {LW{1'b0}}
                 :    (~rLockReg)           ? {LW{1'b0}}
                 :    (rLockCnt<LOCK_CNT)   ? rLockCnt + 1'd1
                 :                            rLockCnt;
//!_____________________________________________________________________________
    rLocked     <=`DL wLocked;
//!_____________________________________________________________________________
    rWaitCnt    <=`DL wIsStep3              ? WAIT_CNT[0+:WW]
                :     ~wIsStep7             ? rWaitCnt
                :     (|rWaitCnt)           ? rWaitCnt - 1'd1
                :                             {WW{1'b0}};
//!_____________________________________________________________________________
    if (~wEnable)                   rChkFlag                <=`DL 8'h00;
    else if (wIsStep7 & rLocked)    rChkFlag[rLoopCnt[2:0]] <=`DL 1'b1;
//!_____________________________________________________________________________
    rChkOkCnt   <=`DL ~wEnable              ? 4'd0
                 :    ~wIsStep7             ? rChkOkCnt
                 :    (rWaitCnt==0)         ? 4'd0
                 :    rLocked               ? rChkOkCnt + 1'd1
                 :                            rChkOkCnt;
end

always @(*) begin
    if (~wEnable)   rInitFsmN   =`DL INIT_STEP_1;
    else case (rInitFsmC) /* synthesis full_case */
        INIT_STEP_0 : rInitFsmN =`DL INIT_STEP_1;
        INIT_STEP_1 : rInitFsmN =`DL INIT_STEP_2;
        INIT_STEP_2 : rInitFsmN =`DL INIT_STEP_3;
        INIT_STEP_3 : rInitFsmN =`DL wWaitLock             ? INIT_STEP_7
                                : wReqOver & rLastStep  ? INIT_STEP_9
                                : wReqOver &~rLastStep  ? INIT_STEP_1
                                : (rMdAddr >= wReqAddr) ? INIT_STEP_4
                                :                         INIT_STEP_3;
        INIT_STEP_4 : rInitFsmN =`DL INIT_STEP_5;
        INIT_STEP_5 : rInitFsmN =`DL INIT_STEP_6;
        INIT_STEP_6 : rInitFsmN =`DL INIT_STEP_2;
        INIT_STEP_7 : rInitFsmN =`DL (rWaitCnt==0)         ? INIT_STEP_8
                                : ~rLocked              ? INIT_STEP_7
                                : rLastStep             ? INIT_STEP_9
                                :                         INIT_STEP_8;
        INIT_STEP_8 : rInitFsmN =`DL ~rLastStep            ? INIT_STEP_1
                                : rChkVld               ? INIT_STEP_1
                                :                         INIT_STEP_9;
        INIT_STEP_9 : rInitFsmN =`DL INIT_STEP_9;
        default     : rInitFsmN =`DL INIT_STEP_9;
    endcase
end

always @ (posedge I_MD_CLK) begin
    rMdOpc      <=`DL ~wEnable  ? 2'b00
                 :    wIsStep7  ? 2'b00
                 :    wIsStep5  ? 2'b01
                 :                2'b10;
//!_____________________________________________________________________________
    rMdInc      <=`DL wIsStep3 & (~rMdInc ? (rMdAddr<wReqAddr)
                                 :          (wMdAddrNext < wReqAddr)); 
//!_____________________________________________________________________________
    rMdAddr     <=`DL ~wEnable  ? 8'd0
                 :    wIsStep7  ? 8'd0
                 :    rMdInc    ? wMdAddrNext
                 :                rMdAddr;
//!_____________________________________________________________________________
    rMdDOut     <=`DL wIsStep5  ? (I_MD_RD_DATA&~wReqMask|wReqData) : rMdDOut;
//!_____________________________________________________________________________
     rRstOut     <=`DL ~wEnable | (~wIsStep7 & ~wIsStep9);
//!_____________________________________________________________________________
    rLockOut    <=`DL rLocked & wIsStep9 & rChkVld;
end


/////////////mdrp switch//////////////////////////
assign  O_LOCK      = (PLL_INIT_BYPASS == 1'b1) ? I_LOCK : rLockOut;
assign  O_RST       = (PLL_INIT_BYPASS == 1'b1) ? I_RST : rRstOut;
assign  O_MD_INC    = (PLL_INIT_BYPASS == 1'b1) ? MDAINC : rMdInc;
assign  O_MD_OPC    = (PLL_INIT_BYPASS == 1'b1) ? MDOPC : rMdOpc;
assign  O_MD_WR_DATA= (PLL_INIT_BYPASS == 1'b1) ? MDWDI : rMdDOut;
assign  MDRDO       = (PLL_INIT_BYPASS == 1'b1) ? I_MD_RD_DATA : 8'b0000_0000;


/////////////////////////////////////

endmodule//: PLL_INIT


