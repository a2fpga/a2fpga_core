#!/bin/sh
MERLIN32_DIR="/opt/homebrew/Cellar/merlin32/1.0/lib"
merlin32 -V "$MERLIN32_DIR" cardrom.s
python3 makehex.py cardrom 2048 > cardrom.hex
cp cardrom.hex ../../hdl/cardrom/





