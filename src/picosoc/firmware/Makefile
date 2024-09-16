ifneq ($(wildcard /opt/homebrew/opt/riscv-gnu-toolchain/bin/riscv64-unknown-elf-gcc),)
    $(info Using Mac Homebrew 64-bit RISC-V GCC Toolchain (riscv64-unknown-elf))
	TOOLCHAIN_BIN_DIR = /opt/homebrew/opt/riscv-gnu-toolchain/bin
	RISCVBUILD = 64
else
    $(info Using 32-bit RISC-V GCC Toolchain installed in /opt/riscv/bin (riscv32-unknown-elf))
	TOOLCHAIN_BIN_DIR = /opt/riscv/bin
	RISCVBUILD = 32
endif

GCC = $(TOOLCHAIN_BIN_DIR)/riscv$(RISCVBUILD)-unknown-elf-gcc
OBJCOPY = $(TOOLCHAIN_BIN_DIR)/riscv$(RISCVBUILD)-unknown-elf-objcopy
FIRMWARE_DIR = .
INCLUDE_DIR = ../libraries

LDS_FILE = $(FIRMWARE_DIR)/firmware.lds
START_FILE = $(FIRMWARE_DIR)/firmware.S
C_FILES = \
	main.c \
	$(INCLUDE_DIR)/a2fpga/a2fpga.c \
	$(INCLUDE_DIR)/a2slots/a2slots.c \
	$(INCLUDE_DIR)/soc/soc.c \
	$(INCLUDE_DIR)/uart/uart.c \
	$(INCLUDE_DIR)/xprintf/xprintf.c \
	$(INCLUDE_DIR)/a2mem/a2mem.c \
	$(INCLUDE_DIR)/pff/mmcbbp.c \
	$(INCLUDE_DIR)/pff/pff.c \

all: firmware.hex

firmware.elf: $(C_FILES) 
	$(GCC) -march=rv32im -mabi=ilp32 -mno-div \
		-nostartfiles \
		-Wl,-Bstatic,-T,$(LDS_FILE),--strip-debug,-Map=firmware.map,--cref \
		-fno-zero-initialized-in-bss -ffreestanding -Os \
		-o firmware.elf \
		-I$(INCLUDE_DIR) $(START_FILE) $(C_FILES)

firmware.asm: $(C_FILES) 
	$(GCC) -march=rv32im -mabi=ilp32 -mno-div \
		-nostartfiles \
		-Wl,-Bstatic,-T,$(LDS_FILE),--strip-debug,-Map=firmware.map,--cref \
		-fno-zero-initialized-in-bss -ffreestanding -Os \
		-I$(INCLUDE_DIR) $(START_FILE) -c -S $(C_FILES)
		mkdir asm
		mv *.s asm/

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary firmware.elf firmware.bin

firmware.hex: $(FIRMWARE_DIR)/makehex.py firmware.bin
	python3 $(FIRMWARE_DIR)/makehex.py firmware.bin 3584 > firmware.hex
	@echo "Firmware size: $$(grep .. firmware.hex | wc -l) / $$(wc -l < firmware.hex)"
	cp firmware.hex ../../../hdl/picosoc/

clean:
	rm -f firmware.elf firmware.hex firmware.bin firmware.o firmware.map asm/*.s
	rmdir asm

