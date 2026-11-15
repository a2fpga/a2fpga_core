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
`ifndef _F65C816_PKG
`define _F65C816_PKG

package F65C816_pkg;
  typedef struct packed {
    logic [2:0]  stateCtrl;
    logic [3:0]  addrBus;
    logic [1:0]  addrInc;
    logic [2:0]  loadP;
    logic [1:0]  loadT;
    logic [1:0]  muxCtrl;
    logic [7:0]  addrCtrl;
    logic [2:0]  loadPC;
    logic [2:0]  loadSP;
    logic [2:0]  regAXY;
    logic [1:0]  loadDKB;
    logic [5:0]  busCtrl;
    logic [4:0]  ALUCtrl;
    logic [1:0]  byteSel;
    logic [2:0]  outBus;
    logic [1:0]  va;
  } FMicroInst_r;

  // rung 2d: ALU control is pre-decoded in the microcode — one-hot first/second
  // operation selects and the "carry out comes from the adder" bit sit beside
  // the stock 3-bit fields, so the ALU's selects are single AND-OR levels.
  typedef struct packed {
    logic [7:0]  FST;        // one-hot of fstOp
    logic [7:0]  SEC;        // one-hot of secOp
    logic        SEL_ADD;    // secOp in {011, 110, 111}: result/carry from the adder
    logic [2:0]  fstOp;
    logic [2:0]  secOp;
    logic        fc;
    logic        w16;
  } FALUCtrl_r;

  typedef struct packed {
    // rung 2b pre-decoded columns (fast core only)
    logic [7:0]  SB_SEL;      // one-hot of BUS_CTRL[5:3]
    logic [5:0]  DB_SEL;      // one-hot of BUS_CTRL[2:0] (0..5)
    logic        W16_FORCE;   // w16 = FORCE | (M & ~MF & ~EF) | (X & ~XF & ~EF)
    logic        W16_M;
    logic        W16_X;
    // rung 2c: LOAD_P == 001 condition tree pre-decoded per microinstruction
    logic        PF_PLB, PF_PLD, PF_TSX, PF_FORCE, PF_M8, PF_X8, PF_M16, PF_X16;
    FALUCtrl_r    ALU_CTRL;
    logic [2:0]  STATE_CTRL;
    logic [3:0]  ADDR_BUS;
    logic [1:0]  ADDR_INC;
    logic [1:0]  IND_CTRL;
    logic [7:0]  ADDR_CTRL;
    logic [2:0]  LOAD_PC;
    logic [2:0]  LOAD_SP;
    logic [2:0]  LOAD_AXY;
    logic [2:0]  LOAD_P;
    logic [1:0]  LOAD_T;
    logic [1:0]  LOAD_DKB;
    logic [5:0]  BUS_CTRL;
    logic [1:0]  BYTE_SEL;
    logic [2:0]  OUT_BUS;
    logic [1:0]  VA;
  } FMCode_r;

endpackage // F65C816_pkg
`endif //  `ifndef _F65C816_PKG
