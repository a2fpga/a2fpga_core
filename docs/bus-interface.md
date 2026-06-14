# Apple II Bus Interface

How the core snoops the Apple II bus, the slot/card system, and **how to build a new virtual
peripheral card**.

## The path from the Apple II to the core

```
Apple II bus  →  board bus-interface hardware  →  FPGA pins  →  apple_bus  →  a2bus_if  →  cards
```

- The **board bus-interface hardware** level-shifts the 5 V Apple II bus to the FPGA and (on the
  CPLD boards) multiplexes it onto a narrow 8-bit host bus. The mechanism differs per board (table
  below).
- **`apple_bus`** is **per board** (`boards/<board>/hdl/bus/apple_bus.sv`) — it drives that
  hardware, samples address/data at the right point in the Apple bus cycle, and produces the clean,
  synchronized [`a2bus_if`](../hdl/bus/a2bus_if.sv). It also drives card data and the
  interrupt/inhibit lines back out. Clock synchronization + edge detection is in
  [`a2bus_timing`](../hdl/bus/a2bus_timing.sv); bidirectional FPGA data pins go through a Gowin
  `IOBUF` in `top.sv`.
- Cards consume `a2bus_if` (and `slot_if`) as **slaves** and never touch the board hardware.
  **The per-board `apple_bus` is what makes the rest of the core board-independent** — whatever the
  physical interface, every card above it sees the same `a2bus_if`.

### Bus-interface hardware per board

| Board(s) | Apple II bus interface |
|---|---|
| **a2n20v2** (production) | "a2bridge" CPLD (Xilinx XC9572XL-10TQG100) — bridges the bus to an 8-bit host interface, including the IIgs M2SEL/M2B0 lines |
| **a2n20v1** | earlier "a2bridge" CPLD (Xilinx XC9572XL-10VQG64) — 8-bit host interface, without the IIgs lines |
| **a2n9** | discrete level-shifters: 74ALVC164245 (address), SN74LVC8T245 (data), LSF0108PW (control) |
| **a2mega**, **a2p25** | discrete: dual 74ALVC164245 pairs + an LSF0108PW for the control lines |

### The a2bridge CPLD (a2n20v2)

On the production a2n20v2 the interface is a small CPLD ("a2bridge") that presents the Apple II bus
to the FPGA as an **8-bit host port with a 3-bit register select** (`a2_bridge_sel`) plus read/write
strobes. `apple_bus` selects which slice of bus state to read or write:

| Select | The core reads | The core writes |
|---|---|---|
| data | the current bus data byte | the byte to drive back onto the bus (card read responses) |
| address low / high | the 16-bit bus address (two bytes) | — (the Apple drives the address during normal cycles) |
| flags | `{sync, iostrb_n, iosel_n, devsel_n, m2sel, m2b0}` — the bus's native select/sync strobes plus the IIgs lines | — |
| switches | the board DIP switches | — |
| control | the open-drain control lines | asserts control lines (drive INH/IRQ/etc. low) |

Functionally the CPLD also:

- **Manages the open-drain Apple II control lines** (INH, IRQ, RDY, DMA, NMI, reset): the core
  asserts a line by driving its bit low, otherwise the line floats (pulled up by the Apple).
- **Latches M2B0 on the falling edge of Q3** (Apple II Technical Note #68) so IIgs bank-0 decode is
  correct. M2B0 + M2SEL are the "GS control lines" the v2 bridge adds over v1 — which is why a2n20v2
  supports the IIgs and a2n20v1 does not.
- **Implements the power-on-reset hold**: it can hold the Apple in reset at power-up (gated by a DIP
  switch) until the FPGA has configured and releases it by writing the control register — the
  "delay Apple startup until the FPGA is ready" feature.
- **Passes the 7 MHz and phi1 clocks through** (level-shifted) for `apple_bus` to synchronize.

Because `apple_bus` is written to this host-port behavior, everything above it is identical no
matter which board hardware is underneath.

## What a card sees: `a2bus_if`

[`a2bus_if`](../hdl/bus/a2bus_if.sv) carries the whole bus state, synchronized to `clk_logic`. A
card uses the `slave` modport (read-only). Signals, by group:

- **Access:** `addr[15:0]`, `data[7:0]`, `rw_n` (1=read), `m2sel_n` / `m2b0` (IIgs mode/bank),
  `data_in_strobe` (a valid data byte was sampled this cycle), `extended_cycle`.
- **Apple clocks as clock-enables:** `phi0`/`phi1` (levels) plus 1-`clk_logic`-wide edge pulses
  `phi0_posedge`/`phi1_posedge`/…, and `clk_7M`/`clk_14M_posedge`, `clk_q3` (+edges). **Use the
  edge pulses, not raw clocks**, to time logic — they're the synchronized strobes.
- **Control lines (read):** `control_inh_n`, `control_irq_n`, `control_rdy_n`, `control_dma_n`,
  `control_nmi_n`, `control_reset_n`.
- **Resets:** `system_reset_n` (Apple reset ∪ FPGA reset), `device_reset_n` (FPGA-local),
  `sw_gs` (IIgs-mode DIP switch).

**Timing pattern:** address is latched mid-`phi1`; the data byte is sampled in `phi0` and flagged
by a one-cycle `data_in_strobe`. So a card detects an access to its register with something like
`data_in_strobe && selected && rw_n` (read) or `… && !rw_n` (write).

## Soft switches: `a2mem_if` (the convenience layer)

Rather than every card decoding `$C0xx` itself, [`apple_memory`](../hdl/memory/apple_memory.sv)
snoops those accesses and publishes decoded mode state on [`a2mem_if`](../hdl/memory/a2mem_if.sv)
(`TEXT_MODE`, `HIRES_MODE`, `PAGE2`, `COL80`, `STORE80`, IIgs color/`SHRG_MODE`, …, plus
keyboard `keycode`/`keypress_strobe`). Cards read the `slave` modport. This is the same state the
[video generators](video-pipeline.md) and the [coprocessor](coprocessor-interface.md) use.

## The slot/card system

The core hosts up to **8 virtual cards** in Apple II slots 0–7. A card is identified by an 8-bit
**card ID** (0 = empty). [`slotmaker`](../hdl/slots/slotmaker.sv) decodes the bus address to figure
out which slot is being accessed and presents the result on [`slot_if`](../hdl/slots/slot_if.sv):

| `slot_if` signal | Meaning |
|---|---|
| `slot[2:0]` | The slot currently being accessed |
| `card_id[7:0]` | The card ID assigned to that slot |
| `dev_select_n` | Active-low: the slot's **device register** space `$C0nX` is selected |
| `io_select_n` | Active-low: the slot's **I/O / ROM** space `$CnXX` is selected |
| `io_strobe_n` | Active-low: shared **C8 ROM** space `$C800–$CFFF` is active |
| `config_select_n` | Active-low during the slot-configuration phase |
| `card_enable` | The slot's card is enabled |

Address decode (in `slotmaker`, gated by `!m2sel_n`):

- **`$C080–$C0FF`** — device registers; `addr[6:4]` = slot → `dev_select_n`.
- **`$C100–$C7FF`** — per-slot I/O/ROM; `addr[10:8]` = slot → `io_select_n`.
- **`$C800–$CFFF`** — shared C8 ROM → `io_strobe_n`.

**Card assignment:** the default slot→card map is loaded from
[`hdl/slots/slots.hex`](../hdl/slots/slots.hex) (`$readmemh`, one card ID per slot). At runtime the
coprocessor reassigns slots through [`slotmaker_config_if`](../hdl/slots/slotmaker_config_if.sv)
(`slot`/`card_i`/`wr`/`reconfig`) — see [coprocessor-interface.md](coprocessor-interface.md). A card
knows it's the selected one by matching `slot_if.card_id == ID` (its own parameter).

## Driving data and interrupts back to the bus

Cards don't touch the bus directly. Each card outputs `rd_en_o` (it's answering a read) and
`data_o`; `top.sv` ORs the read-enables and priority-muxes the data, then hands it to `apple_bus`,
which drives it during the `phi0` window. From [a2n20v2-Enhanced/hdl/top.sv](../boards/a2n20v2-Enhanced/hdl/top.sv):

```systemverilog
assign data_out_en_w = ssp_rd || mb_rd || ssc_rd || diskii_rd || cardrom_rd;
assign data_out_w = ssc_rd ? ssc_d_w : ssp_rd ? ssp_d_w : mb_rd ? mb_d_w :
                    diskii_rd ? diskii_d_w : cardrom_rd ? cardrom_d_w : a2bus_if.data;
assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n;   // active-low IRQs AND-combined
```

`apple_bus` parameters `BUS_DATA_OUT_ENABLE` / `IRQ_OUT_ENABLE` gate whether the core is allowed to
drive data / IRQ onto the physical bus at all.

## Adding a new virtual card

Use [`mockingboard`](../hdl/mockingboard/mockingboard.sv) (simple) or
[`super_serial_card`](../hdl/ssc/super_serial_card.sv) / [`supersprite`](../hdl/supersprite/supersprite.sv)
as templates. A card module:

1. **Takes `a2bus_if.slave` + `slot_if.card`** (and `a2mem_if.slave` if it needs soft-switch state),
   plus an `ID` and `ENABLE` parameter.
2. **Selects itself** when `slot_if.card_id == ID` and the relevant `*_select_n` is low (and
   `card_enable`). Decode the register from `addr` low bits.
3. **Reads/writes** on `data_in_strobe` (`rw_n` chooses direction); presents read data on `data_o`
   and asserts `rd_en_o` while answering.
4. **Drives `irq_n_o`** (active low) if it raises interrupts.
5. **Wire it into `top.sv`:** instantiate it, add `rd_en`/`data` to the `data_out_*` mux and
   `irq_n` to the IRQ AND, behind an `ENABLE`/`ID` parameter.
6. **Assign it a slot** in [`slots.hex`](../hdl/slots/slots.hex) (or via the coprocessor at runtime).

## Bus-timing gotcha (IIgs)

`a2bus_timing` synchronizes the Apple clocks into `clk_logic` and can **denoise** `phi1`. Denoising
was added so the Mockingboard implementation passes *mbaudit* — but it introduced a regression where
some IIgs systems sample **garbage data** (the data byte is latched slightly too early/late). This
is the open top-priority item in [a2n20v2/TODO.md](../boards/a2n20v2/TODO.md); see also
[gotchas.md](gotchas.md). If you touch bus sampling timing, test against both mbaudit *and* a IIgs.

## See also

- [coprocessor-interface.md](coprocessor-interface.md) — runtime slot reconfiguration and bus observation by an MCU.
- [architecture.md](architecture.md) — where the bus interface sits in the whole design.
- [gotchas.md](gotchas.md) — bus-timing and sampling traps.
