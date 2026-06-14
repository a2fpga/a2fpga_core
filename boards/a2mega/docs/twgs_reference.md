# TransWarp GS — Technical Reference

This document is a **technical extraction and synthesis** of the *Applied Engineering TransWarp GS User's Manual (1989)* combined with register-level details from various sources.

It is intended to provide **engineering-level context** when reasoning about:

- Apple IIgs bus timing
- CPU socket interposers
- Accelerator design
- Cache-based execution islands
- IRQ / DMA / RDY interactions

This is **not** a user guide. It is a *design and behavior reference*.

---

## 1. What the TransWarp GS Is

The **TransWarp GS (TWGS)** is a **CPU replacement accelerator** for the Apple IIgs.

It works by:
- Removing the on-board **65C816**
- Inserting a **CPU socket interposer cable**
- Routing all CPU signals through a **slot-based accelerator card**
- Executing code at higher internal speed using **cache**
- Falling back to Apple IIgs-compatible timing when required

**Key principle:**
> The Apple IIgs motherboard never runs faster than "Fast" speed.
> All acceleration happens *off-bus*, inside the TransWarp hardware.

---

## 2. Physical Architecture

### Installation Topology

1. Native 65C816 is removed from the motherboard
2. TWGS ribbon cable plugs into the CPU socket
3. TWGS card is installed in **slot 3**
4. All CPU signals (PHI2, RDY, IRQ, DMA, address/data) pass through TWGS

This gives TWGS **complete control over CPU timing and arbitration**.

Architecturally similar to:
- ZipGS
- TransWarp II (6502)
- Modern FPGA CPU-socket interposers

---

## 3. CPU and Cache Model

### CPU
- WDC 65C816 (later "S" revision for higher speeds)
- Internally clocked faster than IIgs Fast mode
- Speed is **dynamic**, not fixed
- Stock speed: 7 MHz (28 MHz oscillator ÷ 4)
- Upgraded speeds: 8-18 MHz depending on oscillator and GAL upgrades
- Oscillator frequency = CPU speed × 4

### Cache
- Transparent instruction/data cache
- Stores small, frequently executed loops
- Invisible to software (no new instructions, no API)
- Stock: 8 KB cache
- Upgraded: 32 KB cache
- Cache type: SRAM (62256-series, 12-35ns depending on speed)

> Programs spend most time looping in small regions → cache accelerates loops

Cache is the **primary performance mechanism**, not bus overclocking.

### Write-Back Buffer

The TWGS uses write-back buffers to update motherboard memory at 1 MHz in the background while the CPU continues at full speed. This is critical since IIgs video memory operates at 1 MHz for Apple IIe compatibility.

---

## 4. Memory Acceleration Rules

### Accelerated
- All RAM **except** `$C000–$C0FF` (I/O space)
- Cached instruction/data paths
- GS/OS applications
- IIe/II+ compatibility code

### Not Accelerated
- I/O space
- Timing-critical hardware accesses
- DMA transfers
- Some interrupt-disabled code

---

## 5. Speed Control Model (Critical Detail)

There are **two independent speed selectors**:

### System Speed (Apple IIgs)
- Normal (1 MHz)
- Fast (2.8 MHz)

### TransWarp Speed (TWGS Control Panel)
- Normal
- TransWarp

### Effective Speed Matrix

| System Speed | TransWarp Speed | Result |
|-------------|-----------------|--------|
| Normal | Normal | Normal |
| Normal | TransWarp | **Normal (forced)** |
| Fast | Normal | Fast |
| Fast | TransWarp | **Accelerated** |

**TWGS never overrides Normal speed.**
This is a hard compatibility rule.

---

## 6. Software Control Interface

### Speed Control Register ($C074)

The primary speed control is via memory location `$C074` (decimal 49268):

| Value | Effect |
|-------|--------|
| `$00` | Maximum hardware speed (accelerated) |
| `$01` | 1 MHz (IIgs slow mode) |
| `$03` | Reserved |

Example assembly to slow down:
```asm
LDA #$01
STA $C074       ; Set 1 MHz mode
```

Example to restore fast mode:
```asm
LDA #$00
STA $C074       ; Restore accelerated speed
```

### ZipGS-Compatible Registers

The TWGS may also respond to ZipGS-style registers for compatibility:

#### $C05A - Speed/Unlock Register

**Write:**
- `$5x` four times: Unlock registers
- `$Ax`: Lock registers
- Other values: Force slow mode

**Read:**
- Bits 7-4: Current speed (0=100%, F=6.25%)
- Bits 3-0: Fixed at `1111`

#### $C05B - Status/Control Register

**Read:**
- Bit 7: 1ms clock
- Bit 6: Cache tag updated
- Bit 5: Language Card cache enable (0=cache, 1=bypass)
- Bit 4: Board disable (0=enabled, 1=disabled)
- Bit 3: Delay in effect (0=fast, 1=slow)
- Bit 2: ROM bank
- Bits 1-0: Cache size (00=8K, 01=16K, 10=32K, 11=64K)

### Speed Index Values

| Index | Speed |
|-------|-------|
| 0 | IIgs slow (1 MHz) |
| 1 | IIgs fast (2.8 MHz) |
| 2+ | Accelerated speeds |

---

## 7. IRQ / AppleTalk Safety Logic

Some software:
- Disables interrupts
- Polls hardware
- Assumes 1–2.8 MHz timing

TWGS includes **dynamic IRQ-aware throttling**:

### AppleTalk/IRQ = ON (default)
- TWGS monitors IRQ disable state
- Drops out of TransWarp speed when unsafe
- ~5% performance penalty

### AppleTalk/IRQ = OFF
- No safety throttling
- Faster
- Risky for timing-sensitive software

This is **automatic, hardware-driven speed throttling** based on IRQ state.

---

## 8. DMA Behavior

### DMA Rules
- Apple IIgs supports DMA **only at Normal speed**
- When DMA occurs:
  - TWGS flushes **only the affected cache lines**
  - DMA target memory becomes uncached
  - Remaining cache stays valid

This is **selective cache invalidation**, not global flushing.

Implication:
- TWGS tracks cache address ownership
- DMA is treated as an external coherency event

---

## 9. RDY Cycle Handling

- RDY cycles supported **only when System Speed = Normal**
- RDY at Fast speed → unpredictable behavior

TWGS:
- Honors bus-hold semantics
- Does **not** emulate RDY stretching at Fast speed

---

## 10. Automatic Slowdown Conditions

The TWGS automatically slows down for:
- Disk I/O (slots 4, 5, 6, 7)
- AppleTalk access
- DMA operations
- Video RAM access (1 MHz for IIe compatibility)
- I/O space access (`$C000-$C0FF`)

---

## 11. GAL Functions

The original TWGS used GALs for timing control:
- **GAL1**: CPU clock control
- **GAL2**: Write-back to GS memory
- **GAL8**: Slot decoding, DMA/RDY signal handling for slowdown

---

## 12. Compatibility Guarantees

Explicitly supported:
- Apple II / II+ / IIe compatibility
- DMA cards
- Z-80 cards
- PC Transporter
- AppleTalk
- AppleShare
- Memory expansion cards

Design promise:
> "Total transparent operation"

---

## 13. Engineering Summary

**TransWarp GS is not a faster bus.**

It is:
- A **CPU execution island**
- With **cache-based acceleration**
- **Dynamic speed throttling**
- **IRQ-aware safety logic**
- **Selective DMA cache invalidation**

The Apple IIgs bus is treated as **timing-hostile**, not something to "fix".

---

## 14. FPGA Implementation Notes

For FPGA implementation:

1. **Speed Control**: Implement `$C074` register as primary interface
2. **Cache**: Use BSRAM for 8-32KB cache
3. **Write-Back Buffer**: Required for motherboard memory coherency
4. **Auto-Slowdown**: Monitor I/O space access, slot activity, DMA
5. **IRQ Monitoring**: Track IRQ disable state for safety throttling
6. **DMA Coherency**: Selective cache invalidation on DMA events
7. **ZipGS Compatibility**: Consider `$C05A`/`$C05B` register support
8. **Speed Matrix**: Enforce "Normal speed = no acceleration" rule

---

## 15. Design Implications (for Modern Work)

The TWGS proves that:

- CPU socket interposition is the correct architecture
- Dynamic speed switching based on IRQ state is viable
- Cache + fallback timing beats brute-force bus acceleration
- DMA coherence can be handled selectively
- Full software transparency is achievable

This design philosophy directly applies to:
- FPGA-based Apple IIgs accelerators
- Retro-CPU replacement projects
- Mixed-speed legacy bus systems

---

## 16. References

- *Applied Engineering TransWarp GS User's Manual* (1989)
- [TransWarp GS - ReActiveMicro Wiki](https://wiki.reactivemicro.com/TransWarp_GS)
- [Apple II Accelerators - Wikipedia](https://en.wikipedia.org/wiki/Apple_II_accelerators)
- [TransWarp GS - Apple Archives](https://ae.applearchives.com/apple_iigs/transwarp_gs/)
- [Csa2 Apple II FAQs - Accelerators](https://gswv.apple2.org.za/a2zine/faqs/Csa2ACCEL.html)

---

This README is a **technical interpretation**, not a verbatim reproduction.
