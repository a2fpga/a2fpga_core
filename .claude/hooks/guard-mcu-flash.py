#!/usr/bin/env python3
"""PreToolUse guard: block direct BL616 flashers that brick the a2n20v2-Enhanced.

These boards are fused/secure-boot. `make flash`, raw `BLFlashCommand`, and
`bflb-iot-tool --addr 0x0` default to writing our UNSIGNED firmware at flash
0x0, which erases the signed Sipeed Stage 1 and bricks the board (our firmware
belongs at Stage 2, 0x40000). The ONLY supported flasher is
`tools/a2n20-mcu-program` (the /flash-mcu skill), which this hook does NOT block.

Mechanism: read the PreToolUse JSON on stdin; if the Bash command invokes a
dangerous flasher, exit 2 (blocks the call; stderr is shown to the agent).
Quoted substrings are stripped first so read-only mentions (echo/grep "make
flash") don't trip it — only real, unquoted invocations match.
"""
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # can't parse -> don't interfere

if data.get("tool_name") != "Bash":
    sys.exit(0)

command = (data.get("tool_input") or {}).get("command", "")
if not command:
    sys.exit(0)

# Strip quoted strings so `grep "make flash"` / `echo "...BLFlashCommand..."`
# (read-only references) are not treated as invocations.
stripped = re.sub(r"'[^']*'", " ", command)
stripped = re.sub(r'"[^"]*"', " ", stripped)

DANGEROUS = [
    (r"\bBLFlashCommand", "raw BLFlashCommand"),
    (r"\bmake\b[^\n;|&]*\bflash\b", "make flash"),
    (r"\bbflb[-_]iot[-_]tool\b[^\n]*--addr\s+0x0+\b", "bflb-iot-tool --addr 0x0"),
]

for pattern, label in DANGEROUS:
    if re.search(pattern, stripped, re.IGNORECASE):
        sys.stderr.write(
            "BLOCKED: `%s` can BRICK the a2n20v2-Enhanced BL616.\n"
            "These flashers default to writing firmware at 0x0, erasing the\n"
            "signed Sipeed Stage 1 on a fused board. Firmware is Stage 2 @0x40000.\n"
            "Use the supported flasher instead (the /flash-mcu skill):\n"
            "  cd boards/a2n20v2-Enhanced/src/a2n20_bl616\n"
            "  ./tools/a2n20-mcu-program --stage2 \\\n"
            "      --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin\n"
            "To recover a bricked board, add:\n"
            "  --stage1 recovery/bl616_fpga_partner_20kNano.bin\n" % label
        )
        sys.exit(2)

sys.exit(0)
