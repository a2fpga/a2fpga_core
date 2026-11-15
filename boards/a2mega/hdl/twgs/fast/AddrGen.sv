//============================================================================
//  65C816 CPU core
//
//  SystemVerilog conversion of the VHDL 65C816 core written by srg320 for
//  SNES_MiSTer (https://github.com/MiSTer-devel/SNES_MiSTer), with
//  modifications for the Apple IIgs. See README.md in this directory.
//
//  Copyright (c) srg320 -- original VHDL implementation
//  Copyright (c) 2026 Alan Steremberg -- Verilog conversion and IIgs changes
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of version 3 of the GNU General Public License as
//  published by the Free Software Foundation.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program. If not, see <https://www.gnu.org/licenses/>.
//============================================================================
module F65C816_AddrGen
  (
   input               CLK,
   input               RST_N,
   input               EN,
   input [2:0]         LOAD_PC,
   input               PCDec,
   input               GotInterrupt,
   input [7:0]         ADDR_CTRL,
   input [1:0]         IND_CTRL,
   input [7:0]         D_IN,
   input [15:0]        X,
   input [15:0]        Y,
   input [15:0]        D,
   input [15:0]        S,
   input [15:0]        T,
   input [7:0]         DR,
   input [7:0]         DBR,
   input               e6502,
   output logic [15:0] PC,
   output logic [16:0] AA,
   output logic [7:0]  AB,
   output logic [15:0] DX,
   output logic        AALCarry,
   output logic        JumpNoOfl,
   // S7 data-late: the values PC / AA / AB / DX take after this step (EN assumed)
   output logic [15:0] PC_n,
   output logic [16:0] AA_n,
   output logic [7:0]  AB_n,
   output logic [15:0] DX_n
   );

  logic [7:0]          AAL;
  logic [7:0]          AAH;
  logic [7:0]          DL;
  logic [7:0]          DH;
  logic                SavedCarry;
  logic                AAHCarry;

  logic [8:0]          NewAAL;
  logic [8:0]          NewAAHWithCarry;
  logic [8:0]          NewDL;
  logic [15:0]         InnerDS;

  logic [15:0]         PCr;
  logic [15:0]         NextPC;
  logic [15:0]         NewPCWithOffset;
  logic [15:0]         NewPCWithOffset16;
  logic [15:0]         PCOffset;

  logic [2:0]          AALCtrl;
  logic [2:0]          AAHCtrl;
  logic [1:0]          ABSCtrl;

   assign NewPCWithOffset16 = (PCr + PCOffset);
   assign NewPCWithOffset = PCr + { {8{DR[7]}}, DR };

  always_comb begin
    case (LOAD_PC)
      3'b000 :
        NextPC = PCr;
      3'b001 :
        if (GotInterrupt == 1'b0)
          NextPC = (PCr + 16'd1);
        else
          NextPC = PCr;
      3'b010 :
        NextPC = {D_IN, DR};
      3'b011 :
        NextPC = NewPCWithOffset16;
      3'b100 :
        NextPC = NewPCWithOffset;
      3'b101 :
        NextPC = NewPCWithOffset16;
      3'b110 :
        NextPC = {AAH, AAL};
      3'b111 :   // rung 2c: PCr - 3 or PCr as one masked add, so the ALU carry
                 // (PCDec, MVN/MVP repeat) reaches the PC through the data path,
                 // not through a register-enable with the whole decode in front
        NextPC = PCr + ({16{PCDec}} & 16'hFFFD);
      default :
        NextPC = PCr;
    endcase
  end

   always @(posedge CLK, negedge RST_N)
   begin
      if (RST_N == 1'b0)
      begin
         PCr <= 16'b0;
         PCOffset <= 16'b0;
      end
      else
      begin
         if (EN == 1'b1)
         begin
            PCOffset <= ({D_IN, DR});
            PCr <= NextPC;
         end
      end
   end

   assign JumpNoOfl = ((~(PCr[8] ^ NewPCWithOffset[8]))) & ((~LOAD_PC[0])) & ((~LOAD_PC[1])) & LOAD_PC[2];

   assign AALCtrl = ADDR_CTRL[7:5];
   assign AAHCtrl = ADDR_CTRL[4:2];
   assign ABSCtrl = ADDR_CTRL[1:0];


   always @*
   begin
      case (IND_CTRL)
         2'b00 :
            if (AALCtrl[2] == 1'b0)
               NewAAL = (({1'b0, AAL}) + ({1'b0, X[7:0]}));
            else
               NewAAL = (({1'b0, DL}) + ({1'b0, X[7:0]}));
         2'b01 :
            if (AALCtrl[2] == 1'b0)
               NewAAL = (({1'b0, AAL}) + ({1'b0, Y[7:0]}));
            else
               NewAAL = (({1'b0, DL}) + ({1'b0, Y[7:0]}));
         2'b10 :
            NewAAL = {1'b0, X[7:0]};
         2'b11 :
            NewAAL = {1'b0, Y[7:0]};
         default :
            ;
      endcase

   end

   // S7: the high byte.  The stock block forms one NewAAH from AAH or DH by AAHCtrl[2]
   // and adds the low byte's carry to the DH form, so everything behind NewAAH hung
   // off that carry.  Each use is formed on its own here (the uses are disjoint in
   // the microcode: gen_fast_mcode.py asserts it):
   //   NewAAHa   AAH + index, registers only            (AAHCtrl 000 with IND_CTRL[1], 001)
   //   DHIdx     DH + index for both values of the carry, the carry selects   (AAHCtrl 100)
   wire [7:0] IdxH     = IND_CTRL[0] ? Y[15:8] : X[15:8];
   wire [8:0] NewAAHa  = IND_CTRL[1] ? {1'b0, IdxH} : ({1'b0, AAH} + {1'b0, IdxH});
   wire [7:0] DHIdx0   = DH + IdxH;
   wire [7:0] DHIdx1   = DH + IdxH + 8'd1;
   // (emulation mode with DL = 0 wraps at the page boundary: no carry)
   wire       DHCarry  = NewAAL[8] & ~(e6502 == 1'b1 && D[7:0] == 8'h00);
   wire [7:0] NewDHIdx = IND_CTRL[1] ? IdxH : DHCarry ? DHIdx1 : DHIdx0;

   assign InnerDS = (ABSCtrl == 2'b11 & (AALCtrl[2] == 1'b1 | AAHCtrl[2] == 1'b1)) ?
                    (e6502 == 1'b1 ? {8'h01, S[7:0]} : S) : D;

   assign NewDL = (({1'b0, InnerDS[7:0]}) + ({1'b0, D_IN}));
   assign NewAAHWithCarry = (NewAAHa + ({8'b00000000, SavedCarry}));


   // S7 data-late: next values as logic (EN assumed), registered below.
   logic [7:0]  AAL_n;
   logic [7:0]  AAH_n;
   logic [7:0]  AB_nx;
   logic [7:0]  DL_n;
   logic [7:0]  DH_n;
   logic        AAHCarry_n;
   logic        SavedCarry_n;
   always @* begin
      AAL_n = AAL;
      AAH_n = AAH;
      AB_nx = AB;
      DL_n = DL;
      DH_n = DH;
      AAHCarry_n = AAHCarry;
      SavedCarry_n = SavedCarry;

            case (AALCtrl)
               3'b000 :
                  begin
                     if (IND_CTRL[1] == 1'b1)
                        AAL_n = NewAAL[7:0];
                     SavedCarry_n = 1'b0;
                  end
               3'b001 :
                  begin
                     AAL_n = NewAAL[7:0];
                     SavedCarry_n = NewAAL[8];
                  end
               3'b010 :
                  begin
                     AAL_n = D_IN;
                     SavedCarry_n = 1'b0;
                  end
               3'b011 :
                  begin
                     AAL_n = NewPCWithOffset16[7:0];
                     SavedCarry_n = 1'b0;
                  end
               3'b100 :
                  begin
                     DL_n = NewAAL[7:0];
                     SavedCarry_n = NewAAL[8];
                  end
               3'b101 :
                  begin
                     DL_n = NewDL[7:0];
                     SavedCarry_n = NewDL[8];
                  end
               3'b111 :
                  ;
               default :
                  ;
            endcase

            case (AAHCtrl)
               3'b000 :
                  if (IND_CTRL[1] == 1'b1)
                  begin
                     AAH_n = NewAAHa[7:0];
                     AAHCarry_n = 1'b0;
                  end
               3'b001 :
                  begin
                     AAH_n = NewAAHWithCarry[7:0];
                     AAHCarry_n = NewAAHWithCarry[8];
                  end
               3'b010 :
                  begin
                     AAH_n = D_IN;
                     AAHCarry_n = 1'b0;
                  end
               3'b011 :
                  begin
                     AAH_n = NewPCWithOffset16[15:8];
                     AAHCarry_n = 1'b0;
                  end
               3'b100 :
                  begin
                     DH_n = NewDHIdx;
                     AAHCarry_n = 1'b0;
                  end
               3'b101 :
                  begin
                     DH_n = InnerDS[15:8];
                     AAHCarry_n = 1'b0;
                  end
               3'b110 :
                  begin
                     DH_n = (DH + ({7'b0000000, SavedCarry}));
                     AAHCarry_n = 1'b0;
                  end
               3'b111 :
                  ;
               default :
                  ;
            endcase

            case (ABSCtrl)
               2'b00 :
                  ;
               2'b01 :
                  AB_nx = D_IN;
               2'b10 :   // (not in the microcode: the stock AB = D_IN + the high byte's carry)
                  ;
               2'b11 :
                  if (AALCtrl[2] == 1'b0 & AAHCtrl[2] == 1'b0)
                     AB_nx = DBR;
               default :
                  ;
            endcase
   end

   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         AAL <= 8'd0;
         AAH <= 8'd0;
         AB <= 8'd0;
         DL <= 8'd0;
         DH <= 8'd0;
         AAHCarry <= 1'b0;
         SavedCarry <= 1'b0;
      end
      else if (EN == 1'b1)
      begin
         AAL <= AAL_n;
         AAH <= AAH_n;
         AB <= AB_nx;
         DL <= DL_n;
         DH <= DH_n;
         AAHCarry <= AAHCarry_n;
         SavedCarry <= SavedCarry_n;
      end

   assign PC_n = NextPC;
   assign AA_n = {AAHCarry_n, AAH_n, AAL_n};
   assign AB_n = AB_nx;
   assign DX_n = {DH_n, DL_n};

   assign AALCarry = NewAAL[8];
   assign AA = {AAHCarry, AAH, AAL};
   assign DX = {DH, DL};
   assign PC = PCr;

endmodule
