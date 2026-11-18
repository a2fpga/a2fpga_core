/*
 * audio_ctl — the core's audio control byte (indexed debug window, index 55;
 * select A2REG_GS_SEL = 0x5F, data A2REG_GS_DATA = 0x4F). Bit 0 = sample CDC
 * mailbox path (always kept set), bit 1 = hold the CDC counters clear (left
 * 0), bits 3:2 = Mockingboard level: the AY channel sum is shifted left by
 * 3 + value before the saturating mix (hdl/sound/core_audio_mix.sv). The core
 * powers up at << 5; the firmware applies the persisted setting at boot
 * (disk.c, with the slot map, before the Apple II reset release) and live
 * from SETTINGS -> MOCKINGBOARD VOLUME. Cores without the window ignore the
 * write (a2mega artifacts built before 2026-11-16).
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AUDIO_CTL_INDEX     55
#define AUDIO_CTL_MAILBOX   0x01
#define AUDIO_MB_SHIFT_MIN  3
#define AUDIO_MB_SHIFT_MAX  6
#define AUDIO_MB_SHIFT_DEFAULT 6     /* 2026-11-18 ear pick (Nox Archaist vs the startup beep) */

/* The shift the current setting selects, 3..6 (0 in the blob = default). */
int audio_mb_shift(void);

/* Short OSD label for the current setting: LOW / MEDIUM / HIGH / MAX. */
const char *audio_mb_label(void);

/* Write the control byte for the current setting. Needs the link up. */
void audio_ctl_apply(void);

#ifdef __cplusplus
}
#endif
