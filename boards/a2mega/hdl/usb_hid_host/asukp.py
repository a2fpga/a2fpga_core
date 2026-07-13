#!/usr/bin/env python3

# ---------------------------------------------------------------------------
# Copyright 2023 nand2mario
# Copyright 2026 Mateusz Nalewajski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
# ---------------------------------------------------------------------------

# This is python implementation of the asukp.pl script.
# It is used to convert the UKP assembly code `ukp.s` into `../usb_hid_host_rom.mem`
# It also generates a listing file `ukp.lst`

import os
import shutil
import sys

instructions = {
    "nop": 0,
    "ldi": 1,
    "start": 2,
    "out4": 3,
    "out0": 4,
    "hiz": 5,
    "outb": 6,
    "ret": 7,
    "call": 8,
    "bx": 9,
    "outr": 10,
    "dec": 11,
    "save": 12,
    "in": 13,
    "wait": 14,
    "load": 15,
    "be": 16,
    "bc": 17,
    "bnak": 18,
    "bstall": 19,
    "bnz": 20,
    "bz": 21,
    "bnf": 22,
    "bjmp": 23,
}


def format_instruction(code, operands=None):
    """Format instruction bytes for listing"""
    if code in [10, 12, 15]:  # outr, save, load
        if operands and len(operands) == 2:
            return f"{code:01x} {int(operands[0]):01x} {int(operands[1]):01x}"
        if operands and len(operands) == 1:
            return f"{code:01x} {int(operands[0]):01x}"
        return f"{code:01x} {15:01x} {15:01x}"
    elif code in [1, 3, 6]:  # ldi/out4/outb with immediate
        value = int(operands[0], 16) if operands[0].startswith("0x") else int(operands[0])
        return f"{code:01x} {value & 0x0F:01x} {(value >> 4) & 0x0F:01x}"
    elif code in [8, 16, 17, 18, 19, 20, 21, 22, 23]:  # jumps
        addr = operands[0] if operands else 0
        if code in [16, 17, 18, 19, 20, 21, 22, 23]:  # bx
            return f"{instructions['bx']:01x} {(code-16):01x} {addr & 0x0F:01x} {(addr >> 4) & 0x0F:01x}"
        return f"{code:01x} {addr & 0x0F:01x} {(addr >> 4) & 0x0F:01x}"
    return f"{code:01x}"


def main():
    labels = {}
    pc = 0
    source_lines = []  # Store source lines for listing

    # First pass to calculate labels
    with open("ukp.s") as f:
        for line in f:
            source_lines.append(line.rstrip())
            line = line.split(";")[0].strip()
            if not line:
                continue

            if ":" in line:
                label = line.split(":")[0].strip()
                if label in labels:
                    sys.stderr.write(f"{line} already defined\n")
                    sys.exit(1)
                pc = (pc + 3) & ~3  # Align to 4-byte boundary
                labels[label] = pc
                print(f"pc={pc:03x}\tlabel={label}")
            else:
                tokens = line.split()
                if not tokens:
                    continue

                opcode = tokens[0]
                if opcode not in instructions:
                    sys.stderr.write(f"syntax error: {line}\n")
                    sys.exit(1)

                print(f"pc={pc:03x}\topcode={opcode}")
                code = instructions[opcode]
                if code in [16, 17, 18, 19, 20, 21, 22, 23]:  # bX
                    pc += 4
                elif code in [1, 3, 6, 8, 12]:  # instructions with operands
                    pc += 3
                elif code in [10, 15]:
                    pc += 2
                else:
                    pc += 1

    # Second pass to generate code and listing
    rom = []
    pc = 0
    listing = []

    with open("ukp.lst", "w") as lst_file:
        lst_file.write("Address  Code    Source\n")
        lst_file.write("-" * 50 + "\n")

        for i, line in enumerate(source_lines):
            orig_line = line
            line = line.split(";")[0].strip()
            comment = orig_line.split(";")[1] if ";" in orig_line else ""

            if ":" in line:
                label = line.split(":")[0].strip()
                # Align PC and add padding
                if pc % 4 == 1:
                    lst_file.write(f"{pc:04x}    0 0 0\n")
                    rom.append(0)
                    rom.append(0)
                    rom.append(0)
                elif pc % 4 == 2:
                    lst_file.write(f"{pc:04x}    0 0\n")
                    rom.append(0)
                    rom.append(0)
                elif pc % 4 == 3:
                    lst_file.write(f"{pc:04x}    0\n")
                    rom.append(0)

                pc = (pc + 3) & ~3
                line = f"{pc:04x}    {'  ':8}  {orig_line:<30} {comment}".strip()
                lst_file.write(f"{line}\n")
                continue

            tokens = line.split()
            if not tokens:
                line = f"{'  ':8}  {'  ':8}  {orig_line:<30}".strip()
                lst_file.write(f"{line}\n")
                continue

            opcode = tokens[0]
            code = instructions[opcode]
            if code in [16, 17, 18, 19, 20, 21, 22, 23]:
                rom.append(instructions["bx"])
                rom.append(code - 16)
            else:
                rom.append(code)

            pc_start = pc

            # Format instruction bytes for listing
            if code in [12]:  # save
                if len(tokens) != 3:
                    sys.stderr.write(f"Malformed instruction: {line}\n")
                    sys.exit(1)
                bytes_str = format_instruction(code, tokens[1:])
                rom.append(int(tokens[1]))
                rom.append(int(tokens[2]))
                pc += 3

            elif code in [10, 15]:  # outr, load
                if len(tokens) != 2:
                    sys.stderr.write(f"Malformed instruction: {line}\n")
                    sys.exit(1)
                bytes_str = format_instruction(code, tokens[1:])
                rom.append(int(tokens[1]))
                pc += 2

            elif code in [1, 3, 6]:  # ldi/out4/outb/outr with immediate
                bytes_str = format_instruction(code, tokens[1:])
                value = int(tokens[1], 16) if tokens[1].startswith("0x") else int(tokens[1])
                rom.append(value & 0x0F)
                rom.append((value >> 4) & 0x0F)
                pc += 3

            elif code in [8, 16, 17, 18, 19, 20, 21, 22, 23]:  # jumps
                label = tokens[1]
                address = labels[label] >> 2
                bytes_str = format_instruction(code, [address])
                rom.append(address & 0x0F)
                rom.append((address >> 4) & 0x0F)
                pc += 3 if code in [8] else 4

            else:
                bytes_str = format_instruction(code)
                pc += 1

            line = f"{pc_start:04x}    {bytes_str:8}  {orig_line:<30}".strip()
            lst_file.write(f"{line}\n")

    # Generate output file
    write_mem_file(rom)


def write_mem_file(rom):
    with open("usb_hid_host_rom.mem", "w") as f:
        for value in rom:
            f.write(f"{value:01x}\n")


if __name__ == "__main__":
    main()
