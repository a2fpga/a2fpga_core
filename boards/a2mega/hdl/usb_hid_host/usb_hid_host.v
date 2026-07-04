// ---------------------------------------------------------------------------
// Copyright 2023 nand2mario
// Copyright 2026 Mateusz Nalewajski
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0
// ---------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps
module usb_hid_host #(
  parameter FULL_SPEED = 1,
  parameter KEYBOARD_SUPPORT = 1,
  parameter MOUSE_SUPPORT = 1,
  parameter GAME_SUPPORT = 1
) (
  input wire clk,    // 60MHz clock when FULL_SPEED=1, otherwise 12MHz
  input wire reset,  // reset
  input wire cs,     // chip select

  input  wire usb_dm_i, usb_dp_i,  // USB D- and D+
  output wire usb_dm_o, usb_dp_o,  // USB D- and D+
  output wire usb_oe,              // USB OE

  // key_*, mouse_*, game_* valid depending on typ
  output reg  [1:0] typ,    // device type. 0: no device, 1: keyboard, 2: mouse, 3: gamepad
  output reg  full_report,  // pulse after full report received from device
  output wire connerr,      // connection or protocol error
  output wire busy,

  // keyboard
  output reg [7:0] key_modifiers,
  output reg [7:0] key_0, key_1, key_2, key_3, key_4, key_5,

  // mouse
  output reg [2:0] mouse_btn,        // middle, right, left
  output reg signed [7:0] mouse_dx,  // signed 8-bit, valid during full_report pulse
  output reg signed [7:0] mouse_dy,  // signed 8-bit, valid during full_report pulse

  // gamepad
  output reg       game_l, game_r, game_u, game_d,                      // left right up down
  output reg       game_a, game_b, game_x, game_y, game_sel, game_sta,  // buttons
  output reg [3:0] game_extra,                                          // extra buttons

  // debug
  output wire [63:0] dbg_hid_report,  // last HID report
  output wire [63:0] dbg_hid_regs,    // internal regs

  // rom
  output wire [9:0] rom_addr,
  input  wire [3:0] rom_dout,
  output wire       rom_en
);

wire       ukprdy;
wire       ukpstb;
wire       ukpstart;
wire [7:0] ukpdat;
wire [3:0] addra;
wire [3:0] addrb;
wire       save;
wire       load;
wire       connected;
wire       full_speed;

reg [7:0] load_data;

ukp #(
  .FULL_SPEED(FULL_SPEED)
) ukp (
  .reset(reset),
  .clk(clk),
  .cs(cs),
  .usb_dp_i(usb_dp_i),
  .usb_dm_i(usb_dm_i),
  .usb_dp_o(usb_dp_o),
  .usb_dm_o(usb_dm_o),
  .usb_oe(usb_oe),
  .ukprdy(ukprdy),
  .ukpstb(ukpstb),
  .ukpstart(ukpstart),
  .ukpdat(ukpdat),
  .addra(addra),
  .addrb(addrb),
  .save(save),
  .load(load),
  .load_data(load_data),
  .connected(connected),
  .full_speed(full_speed),
  .connerr(connerr),
  .busy(busy),
  .rom_addr(rom_addr),
  .rom_dout(rom_dout),
  .rom_en(rom_en)
);

reg [7:0] in_payload  [0:1];  // USB IN request payload data for endpoint specific to a given VID, PID
reg [7:0] out_payload [0:1];  // USB OUT request payload data for endpoint specific to a given VID, PID
reg       x_input;            // indicates if pad should be polled in X-Input mode
reg [7:0] polling_interval;   // polling interval in ms

reg [7:0] dat  [0:7];         // data in last response (up to 8 bytes, wraps-around)
reg [7:0] regs [0:7];         // 0 (VID_L), 1 (VID_H), 2 (PID_L), 3 (PID_H), 4 (INTERFACE_CLASS), 5 (INTERFACE_SUBCLASS), 6 (INTERFACE_PROTOCOL), 7 (UNUSED)
reg [2:0] rcvct;
reg [1:0] typ_next;
reg       ukprdy_r;
reg       connected_r;

wire [15:0] vid = {regs[1], regs[0]};
wire [15:0] pid = {regs[3], regs[2]};

assign dbg_hid_report = {dat[7], dat[6], dat[5], dat[4], dat[3], dat[2], dat[1], dat[0]};
assign dbg_hid_regs   = {regs[7], regs[6], regs[5], regs[4], regs[3], regs[2], regs[1], regs[0]};

integer i;

// handle save and load instructions
always @(posedge clk) begin
  if (reset || connerr) begin
    for (i = 0; i < 8; i = i + 1)
      regs[i] <= 8'b0;

  end else if (save) begin
    regs[addra[2:0]] <= dat[addrb[2:0]];

  end else if (load) begin
    if (addra < 8)
      load_data <= regs[addra[2:0]];
    else if (addra == 8)   // IN payload
      load_data <= in_payload[0];
    else if (addra == 9)   // IN payload
      load_data <= in_payload[1];
    else if (addra == 10)  // OUT payload
      load_data <= out_payload[0];
    else if (addra == 11)  // OUT payload
      load_data <= out_payload[1];
    else if (addra == 12)  // X-Input
      load_data <= x_input ? 8'b1 : 8'b0;
    else if (addra == 13)  // polling interval
      load_data <= polling_interval;
  end
end

integer j;

// handle ukp data from packets
always @(posedge clk) begin
  if (reset || connerr) begin
    for (j = 0; j < 8; j = j + 1)
      dat[j] <= 8'b0;

    ukprdy_r    <= 0;
    connected_r <= 0;
    typ         <= 0;
    full_report <= connerr;  // send empty report on connection error
    rcvct       <= 0;

  end else if (ukpstart) begin
    rcvct       <= 0;  // mark start of read transaction
    full_report <= 0;

  end else if (ukprdy) begin
    ukprdy_r    <= ukprdy;
    full_report <= 0;

    if (ukpstb) begin
      rcvct      <= rcvct + 1;
      dat[rcvct] <= ukpdat;  // record byte from a packet
    end
  end else begin
    ukprdy_r    <= ukprdy;
    connected_r <= connected;
    full_report <= 0;

    if (ukprdy_r) begin     // individual packet received, ukprdy is not asserted
      rcvct <= rcvct - 2;   // ignore CRC16, important when packets are split

      if (connected) begin  // change typ after a first valid report
        typ         <= typ_next;
        full_report <= 1;
      end
    end

    // send empty report on connection state change
    if (connected && !connected_r) begin
      for (j = 0; j < 8; j = j + 1)
        dat[j] <= 8'b0;

      full_report <= 1;
    end
  end
end

// set typ depending on INTERFACE_CLASS, INTERFACE_SUBCLASS, INTERFACE_PROTOCOL, VID, PID
always @(*) begin
  typ_next = 0;
  x_input  = 0;

  casez ({regs[4], regs[5], regs[6], vid, pid})  // INTERFACE_CLASS, INTERFACE_SUBCLASS, INTERFACE_PROTOCOL, VID, PID
    {8'h03, 8'h01, 8'h01, 16'hzzzz, 16'hzzzz}: if (KEYBOARD_SUPPORT) typ_next = 1;  // keyboard
    {8'h03, 8'h01, 8'hzz, 16'hzzzz, 16'hzzzz}: if (MOUSE_SUPPORT)    typ_next = 2;  // mouse
    {8'h03, 8'hzz, 8'hzz, 16'hzzzz, 16'hzzzz}: if (GAME_SUPPORT)     typ_next = 3;  // other (incl. 8BitDo, D-Input)
    {8'hff, 8'h5d, 8'h01, 16'hzzzz, 16'hzzzz},
    {8'hff, 8'h5d, 8'h81, 16'hzzzz, 16'hzzzz}: begin
      if (GAME_SUPPORT) typ_next = 3;
      x_input  = 1;
    end  // Xbox 360 (incl. 8BitDo, X-Input); wired - protocol 1, wireless - protocol 129
  endcase
end

// set in_payload and out_payload payload depending on VID, PID
// ref: https://rayslogic.com/Propeller/USB.htm#USB%20Token
always @(*) begin
  casez ({vid, pid})
    {16'h2dc8, 16'h301c},
    {16'h2dc8, 16'h310a}: begin
      in_payload[0] = 8'h01;   // IN endpoint 4 (01 ba)
      in_payload[1] = 8'hba;

      out_payload[0] = 8'h81;  // OUT endpoint 5 (81 0a)
      out_payload[1] = 8'h0a;
    end  // 8BitDo Ultimate 2C
    default: begin
      in_payload[0] = 8'h81;   // IN endpoint 1 (81 58) - default
      in_payload[1] = 8'h58;

      out_payload[0] = 8'h01;  // OUT endpoint 2 (01 c1) - default
      out_payload[1] = 8'hc1;
    end
  endcase
end

// set polling interval depending on typ_next, full_speed, x_input, VID, PID
always @(*) begin
  casez ({typ_next, full_speed, x_input, vid, pid})
    {2'bzz, 1'b0, 1'bz, 16'hzzzz, 16'hzzzz}: begin
      polling_interval = 8'd10;  // 10ms for low-speed devices
    end
    {2'b10, 1'b1, 1'b0, 16'hzzzz, 16'hzzzz}: begin
      polling_interval = 8'd2;   // 2ms for full-speed mouse
    end
    {2'b01, 1'b1, 1'b0, 16'hzzzz, 16'hzzzz}: begin
      polling_interval = 8'd1;   // 1ms for full-speed keyboard
    end
    {2'b11, 1'b1, 1'bz, 16'h2dc8, 16'hzzzz}: begin
      polling_interval = 8'd2;   // 2ms for 8BitDo
    end
    {2'b11, 1'b1, 1'b1, 16'hzzzz, 16'hzzzz}: begin
      polling_interval = 8'd4;   // 4ms for other Xbox-compatible controllers
    end
    default: begin
      polling_interval = 8'd8;   // 8ms by default
    end
  endcase
end

reg [2:0] hat;

always @(*) begin
  {key_modifiers, key_0, key_1, key_2, key_3, key_4, key_5} = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
  {mouse_btn, mouse_dx, mouse_dy} = {3'b000, 8'h00, 8'h00};
  {game_l, game_r, game_u, game_d} = {1'b0, 1'b0, 1'b0, 1'b0};
  {game_y, game_x, game_b, game_a} = {1'b0, 1'b0, 1'b0, 1'b0};
  {game_sel, game_sta} = {1'b0, 1'b0};
  game_extra = 4'b0;

  if (KEYBOARD_SUPPORT && typ == 1) begin
    {key_modifiers, key_0, key_1, key_2, key_3, key_4, key_5} = {dat[0], dat[2], dat[3], dat[4], dat[5], dat[6], dat[7]};

  end else if (MOUSE_SUPPORT && typ == 2) begin
    {mouse_btn, mouse_dx, mouse_dy} = {dat[0][2:0], dat[1], dat[2]};

  end else if (GAME_SUPPORT && typ == 3) begin
    casez ({x_input, vid, pid})
      {1'b0, 16'h2dc8, 16'hzzzz}: begin  // 8BitDo, assume generic D-Input
        {game_y, game_x, game_b, game_a} = {dat[1][4:3], dat[1][1:0]};  // buttons
        {game_sel, game_sta} = {dat[2][2], dat[2][3]};                  // - +

        if (dat[3][3:0] != 4'hf) begin
          hat = dat[3][2:0];  // circular pattern
          game_u = (hat == 3'd0 || hat == 3'd1 || hat == 3'd7);
          game_d = (hat == 3'd3 || hat == 3'd4 || hat == 3'd5);
          game_l = (hat == 3'd5 || hat == 3'd6 || hat == 3'd7);
          game_r = (hat == 3'd1 || hat == 3'd2 || hat == 3'd3);
        end

        // lt, lb, rt, rb
        game_extra = {dat[2][0], dat[1][6], dat[2][1], dat[1][7]};
      end
      {1'b1, 16'hzzzz, 16'hzzzz}: begin  // Xbox 360 - compatible (X-Input)
        if (dat[0] == 8'h00) begin  // valid pad data
          {game_y, game_x, game_b, game_a} = dat[3][7:4];  // buttons
          {game_sel, game_sta} = {dat[2][5], dat[2][4]};   // - +

          {game_r, game_l, game_d, game_u} = {dat[2][3:0]};  // d-pad

          // l2, l1, r2, r1
          game_extra = {(|dat[4]), dat[3][0], (|dat[5]), dat[3][1]};
        end
      end
      {1'b0, 16'h0738, 16'h2217}: begin  // SpeedLink COMPETITION PRO Extra
        {game_y, game_x, game_b, game_a} = {dat[0][2], dat[0][0], dat[0][3], dat[0][1]};

        {game_l, game_r} = {dat[1][7:6] == 2'b00, dat[1][7:6] == 2'b11};
        {game_u, game_d} = {dat[2][7:6] == 2'b00, dat[2][7:6] == 2'b11};
      end
      default: begin
        // A typical report layout:
        // - d[3] is X axis (0: left, 255: right)
        // - d[4] is Y axis
        // - d[5][7:4] is buttons YBAX
        // - d[6][5:4] is buttons START, SELECT

        {game_l, game_r} = {dat[3][7:6] == 2'b00, dat[3][7:6] == 2'b11};
        {game_u, game_d} = {dat[4][7:6] == 2'b00, dat[4][7:6] == 2'b11};

        {game_a, game_b} = {dat[5][5], dat[5][6]};
        {game_x, game_y} = {dat[5][4], dat[5][7]};

        {game_sel, game_sta} = {dat[6][4], dat[6][5]};
      end
    endcase
  end
end

endmodule

module ukp #(
  parameter FULL_SPEED = 1
) (
  input wire clk,
  input wire reset,
  input wire cs,

  input  wire usb_dm_i, usb_dp_i, // USB D- and D+
  output wire usb_dm_o, usb_dp_o, // USB D- and D+
  output wire usb_oe,             // USB OE

  output reg        ukprdy,   // data frame is outputing
  output reg        ukpstb,   // strobe for a byte within the frame
  output reg        ukpstart, // marks start of read transaction
  output reg  [7:0] ukpdat,   // output data when ukpstb = 1

  output reg  [3:0] addra,
  output reg  [3:0] addrb,
  output reg        save,
  output reg        load,
  input  wire [7:0] load_data,

  output wire [9:0] rom_addr,
  input  wire [3:0] rom_dout,
  output wire       rom_en,

  output reg  connected,
  output reg  full_speed,
  output wire connerr,
  output wire busy
);

// input filter parameters
localparam RX_FILTER  = 3;  // last 3 samples
localparam EOP_FILTER = 3;
localparam SUM_WIDTH  = $clog2(RX_FILTER + 1) + 1;  // +/- 3 range

wire [3:0] inst;
wire       polarity;
wire       sample;
wire       transmission;
wire       data01;
wire       payload;
wire       di;
wire       dbit;
wire       timing_0, timing_1, timing_rx;

reg  [3:0] insth;  // current instruction
reg  [7:0] wk;  // W register
reg  [7:0] sb;  // out value
reg  [2:0] sadr;  // out4 / outb write ptr
reg  [3:0] lb4;  // instruction operand
reg  [7:0] data;  // received data
reg  [2:0] nrztxct, nrzrxct;  // NRZI trans/recv count for bit stuffing
reg  [8:0] bitaddr;  // 0~512
reg  [2:0] timing;  // T register (0~7)
reg  [2:0] prescaler;  // clock prescaler for low-speed
reg [15:0] interval = 1;  // frame interval counter
reg  [7:0] delay    = 1;  // inter-packet delay counter
reg  [9:0] conct;  // watchdog counter

reg eop, ug, up, um, did, dis, cond, eot, nak, stall;

reg [RX_FILTER-1:0] dpi, dmi;

reg signed [SUM_WIDTH-1:0] dsum, sum;

reg [4:0] state, state_next;
reg [9:0] pc, pc_next;
reg [9:0] wpc [0:1];

`ifdef VERILATOR
wire interval_frame = interval == 30;
`else
wire interval_frame = interval == (FULL_SPEED ? 60000 : 12000);
`endif

`ifdef VERILATOR
wire timeout = 0;
`else
wire timeout = delay >= (FULL_SPEED && full_speed ? 90 : 144);  // 18 x bit time
`endif

assign polarity = full_speed;

assign usb_dp_o = up;
assign usb_dm_o = um;
assign usb_oe   = ug;

assign connerr = (&conct) && (di || connected);

integer i;

always @(*) begin
  sum = 0;

  for (i = 0; i < RX_FILTER; i = i + 1)
    sum = sum
      + {{(SUM_WIDTH-1){1'b0}}, dpi[i]}
      - {{(SUM_WIDTH-1){1'b0}}, dmi[i]};
end

always @(posedge clk) begin
  dpi <= {dpi[RX_FILTER-2:0], usb_dp_i};
  dmi <= {dmi[RX_FILTER-2:0], usb_dm_i};

  dsum <= sum;
  eop  <= dpi[EOP_FILTER-1:0] == dmi[EOP_FILTER-1:0];
end

assign di   = (dsum < 0) ^ polarity;
assign dbit = sb[7 - sadr[2:0]];

// state machine
localparam S_OPCODE = 0;
localparam S_SYNC   = 1;
localparam S_WAIT   = 2;
localparam S_LDI0   = 3;
localparam S_LDI1   = 4;
localparam S_BX     = 5;
localparam S_B0     = 6;
localparam S_B1     = 7;
localparam S_B2     = 8;
localparam S_HIZ    = 9;
localparam S_RX0    = 10;
localparam S_RX1    = 11;
localparam S_TX0    = 12;
localparam S_TX1    = 13;
localparam S_TX2    = 14;
localparam S_SAVE0  = 15;
localparam S_SAVE1  = 16;
localparam S_LOAD0  = 17;
localparam S_LOAD1  = 18;
localparam S_LOAD2  = 19;

assign inst     = rom_dout;
assign rom_addr = pc_next;
assign rom_en   = state_next != S_SYNC &&
                  state_next != S_WAIT &&
                  state_next != S_HIZ &&
                  state_next != S_RX0 &&
                  state_next != S_RX1 &&
                  state_next != S_TX2 &&
                  state_next != S_LOAD1 &&
                  state_next != S_LOAD2;

assign timing_0  = timing == 0 && prescaler == 0;
assign timing_1  = timing == 1 && prescaler == 0;
assign timing_rx = timing == 2 && prescaler == 0;

assign sample       = state == S_RX1 && timing_rx;
assign transmission = state == S_TX2 && timing_0;

// following flags have to be combined with sample
assign data01  = bitaddr == 16 && (data[3:0] == 4'b0011 || data[3:0] == 4'b1011);
assign payload = nrzrxct != 6 && bitaddr > 15 && !eop;

assign busy = insth != 14;  // op!=WAIT

// branch condition
always @(*) begin
  case (inst)
    0: cond = eop || (connected && !di) || (!FULL_SPEED && (|dpi));  // op=BE
    1: cond = connected;  // op=BC
    2: cond = nak;  // op=BNAK
    3: cond = stall;  // op=BSTALL
    4: cond = wk > 0;  // op=BNZ
    5: cond = wk == 0;  // op=BZ
    6: cond = !FULL_SPEED || !full_speed;  // op=BNF
    7: cond = 1;  // op=BJMP
    default: cond = 0;
  endcase
end

// state machine sequential
always @(posedge clk) begin
  state <= state_next;
  pc    <= pc_next;
end

// state machine combinational
always @(*) begin
  if (reset || (&conct)) begin
    state_next = S_OPCODE;
    pc_next    = 0;

  end else begin
    state_next = state;
    pc_next    = pc + 1;

    case (state)
      S_OPCODE: begin
        case (inst)
          0: ;  // op=NOP
          1: state_next = S_LDI0;  // op=LDI
          2: ;  // op=START
          3: state_next = S_TX0;  // op=OUT4
          4: ;
          5: begin
            state_next = S_HIZ;
            pc_next    = pc;
          end  // op=HIZ
          6: state_next = S_TX0;  // op=OUTB
          7: pc_next = wpc[0];  // op=RET
          8: state_next = S_B0;  // op=CALL
          9: state_next = S_BX;  // op=BX
          10: state_next = S_LOAD0;  // op=OUTR
          11: ;  // op=DEC
          12: state_next = S_SAVE0;  // op=SAVE
          13: begin
            state_next = S_RX0;
            pc_next    = pc;
          end  // op=IN
          14: begin
            state_next = S_WAIT;
            pc_next    = pc;
          end  // op=WAIT
          15: state_next = S_LOAD0;  // op=LOAD
          default: ;
        endcase
      end
      S_SYNC: begin
        if (timing_1)
          state_next = S_OPCODE;
        else
          pc_next = pc;
      end
      S_WAIT: begin
        if (interval_frame)
          state_next = S_OPCODE;
        else
          pc_next = pc;
      end
      S_LDI0: state_next = S_LDI1;
      S_LDI1: state_next = S_OPCODE;
      S_BX: begin
        if (cond)
          state_next = S_B0;
        else begin
          state_next = S_OPCODE;
          pc_next    = pc + 3;
        end
      end
      S_B0: state_next = S_B1;
      S_B1: begin
        state_next = S_OPCODE;
        pc_next    = {inst, lb4, 2'b0};
      end
      S_RX0: begin
        // dsum == 0 is undefined
        if (!di && dsum != 0)
          state_next = S_RX1;
        else if (timeout)  // timeout
          state_next = S_SYNC;
        else
          pc_next = pc;
      end
      S_HIZ: begin
        pc_next = pc;
        if (timing_0)
          state_next = S_SYNC;
      end
      S_RX1: begin
        if (timing_rx && eop)
          state_next = S_SYNC;
        else
          pc_next = pc;
      end
      S_TX0: state_next = S_TX1;
      S_TX1: begin
        state_next = S_TX2;
        pc_next = pc;
      end
      S_TX2: begin
        if (sadr == 0 && timing_0)
          state_next = S_OPCODE;
        else
          pc_next = pc;
      end
      S_SAVE0: state_next = S_SAVE1;
      S_SAVE1: state_next = S_OPCODE;
      S_LOAD0: begin
        state_next = S_LOAD1;
        pc_next = pc;
      end
      S_LOAD1: begin
        state_next = S_LOAD2;
        pc_next = pc;
      end
      S_LOAD2: begin
        if (insth == 10) begin  // op=OUTR
          state_next = S_TX2;
          pc_next = pc;
        end else
          state_next = S_OPCODE;
      end
      default: state_next = S_OPCODE;
    endcase
  end
end

always @(posedge clk) begin
  if (reset || (&conct)) begin
    conct <= 0;
    connected <= 0;
    timing <= 0;
    prescaler <= 0;
    bitaddr <= 0;
    nak <= 0;
    stall <= 1;
    eot <= 0;
    ug <= 0;
    interval <= 1;
    delay <= 1;
    full_speed <= FULL_SPEED;
    save <= 0;
    load <= 0;
    ukpstb <= 0;
    ukprdy <= 0;
    ukpstart <= 0;

  end else if (cs) begin
    // ensure strobe
    save <= 0;
    load <= 0;
    ukpstb <= 0;
    ukpstart <= 0;

    // div-5 prescaler for low-speed (60MHz -> 12MHz)
    if (FULL_SPEED && !full_speed)
      prescaler <= (prescaler == 4) ? 0 : prescaler + 1;
    else
      prescaler <= 0;

    // oversampling - 8 for low-speed, 5 for high-speed
    // dsum == 0 is undefined
    did <= di;
    if (!ug && did != di && dsum != 0)
      timing <= 1;
    else if (prescaler == 0) begin
      timing <= timing + 1;

      if (FULL_SPEED && full_speed && timing == 4)
        timing <= 0;
    end

    // framing
    if (interval_frame)
      interval <= 1;
    else
      interval <= interval + 1;

    // inter-packet delay
    if (!timeout && prescaler == 0)
      delay <= delay + 1;

    // WDT (data byte valid or connected and NAK)
    if (ukpstb || (connected && nak))
      conct <= 0;
    else if (interval_frame)
      conct <= conct + 1;

    // state machine register outputs
    case (state)
      S_OPCODE: begin
        insth <= inst;
        case (inst)
          0: ;  // op=NOP
          1: ;  // op=LDI
          2: begin
            ukpstart <= 1;
          end  // op=START
          3: begin
            sadr <= 3;
          end  // op=OUT4
          4: ;
          5: ;  // op=HIZ
          6: begin
            sadr <= 7;
          end  // op=OUTB
          7: begin
            wpc[0] <= wpc[1];
          end  // op=RET
          8: begin
            wpc[0] <= pc + 3;
            wpc[1] <= wpc[0];
          end  // op=CALL
          9: ;  // op=BX
          10: begin
            sadr <= 7;
          end  // op=OUTR
          11: begin
            if (wk > 0)
              wk <= wk - 1;
          end  // op=DEC
          12: ;  // op=SAVE
          13: ;  // op=IN
          14: ;  // op=WAIT
          15: ;  // op=LOAD
          default: ;
        endcase
      end
      S_SYNC: begin
        if (timing_0)
          ukprdy <= 0;
      end
      S_WAIT: ;
      S_LDI0: begin
        wk[3:0] <= inst;
      end
      S_LDI1: begin
        wk[7:4] <= inst;
      end
      S_BX: begin
        case (inst)
          0: begin
            if (!cond && !connected && FULL_SPEED)
              full_speed <= dpi[0];
          end  // op=BE
          default: ;
        endcase
      end
      S_B0: begin
        lb4 <= inst;
      end
      S_B1: ;
      S_HIZ: begin
        if (timing_0) begin
          ug <= 0;
        end
      end
      S_RX0: begin
        bitaddr <= 0;
        nak     <= 0;
        stall   <= 1;
        eot     <= 0;
        nrzrxct <= 0;
        timing  <= 0;
        ukprdy  <= 0;
        dis     <= 1;
      end
      S_RX1: begin
        if (timing_rx) begin
          if (data01) begin
            wk     <= wk - 1 + 16;  // increase by size of CRC16
            ukprdy <= 1;            // mark valid packet bytes
          end else if (payload && wk > 0)
            wk <= wk - 1;
          else if (eot) begin
            ukprdy <= 0;
            delay  <= 1;
          end
        end
      end
      S_TX0: begin
        sb[3:0] <= inst;
      end
      S_TX1: begin
        sb[7:4] <= inst;
      end
      S_TX2: begin
        delay <= 1;
      end
      S_SAVE0: begin
        addra <= inst;
      end
      S_SAVE1: begin
        addrb <= inst;
        if (addra == 15) begin
          connected <= inst != 0;
          conct     <= 0;
        end else
          save <= 1;
      end
      S_LOAD0: begin
        addra <= inst;
        load  <= 1;
      end
      S_LOAD1: ;
      S_LOAD2: begin
        wk <= load_data;
        sb <= load_data;
      end
      default: ;
    endcase

    // Sampling
    if (sample) begin
      ug <= 0;
      dis <= di;
      eot <= (eop || wk == 0);  // eop or packet length
      if (bitaddr == 16) begin
        nak   <= data[3:0] == 4'b1010;
        stall <= data[3:0] == 4'b1110;
      end
      if (nrzrxct != 6 && !(&bitaddr)) begin  // ensure bitaddr won't overflow
        data[6:0] <= data[7:1];
        data[7]   <= dis == di;  // testing bit equality
        bitaddr   <= bitaddr + 1;
      end
      if (dis == di)
        nrzrxct <= nrzrxct + 1;
      else
        nrzrxct <= 0;
      if (ukprdy && bitaddr[2:0] == 3'b000) begin  // strobe whenever we have a full byte ready
        ukpdat <= data;
        if (wk >= 15)  // ignore last two bytes (CRC of last part-packet)
          ukpstb <= 1;
      end
    end

    // Transmission
    if (transmission) begin
      ug <= 1;
      if (!ug)  // clear nrztxct when packet is initiated
        nrztxct <= 0;
      else if (dbit)
        nrztxct <= nrztxct + 1;
      else
        nrztxct <= 0;
      if (insth == 6 || insth == 10) begin  // op=OUTB, op=OUTR
        if (nrztxct != 6) begin
          up <= dbit ?  up : ~up;
          um <= dbit ? ~up :  up;
        end else begin
          up <= ~up;
          um <= up;
          nrztxct <= 0;
        end
      end else begin  // op=OUT4
        up <= sb[{sadr[2] | ~polarity, sadr[1:0]}];
        um <= sb[{sadr[2] |  polarity, sadr[1:0]}];
      end
      if (nrztxct != 6 && sadr > 0)
        sadr <= sadr - 1;
    end
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
