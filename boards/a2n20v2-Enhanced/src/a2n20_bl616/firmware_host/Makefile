# SDK_DEMO_PATH must be absolute: SDK v2.3.27's extension.cmake builds the
# linker flag as -T${SDK_DEMO_PATH}/${BUILD_DIR}/generated/linker.ld and the
# link runs from inside build/, so a relative "." resolves one level too deep.
SDK_DEMO_PATH ?= $(abspath .)
BL_SDK_BASE ?= $(SDK_DEMO_PATH)/../../bouffalo_sdk

export BL_SDK_BASE

CHIP ?= bl616
BOARD ?= bl616dk
CROSS_COMPILE ?= riscv64-unknown-elf-

include $(BL_SDK_BASE)/project.build

# SAFETY GUARD: override the SDK's `flash` target so it refuses. The SDK target
# writes our UNSIGNED app to flash 0x0, which erases the signed Sipeed Stage 1
# on a fused board and bricks it (our firmware must go to Stage 2 @0x40000). The
# only supported flasher is ../tools/a2n20-mcu-program (the /flash-mcu skill).
# (GNU make prints "overriding recipe for target 'flash'" — that is expected.)
flash:
	@echo ''
	@echo 'ERROR: `make flash` is DISABLED for this board.'
	@echo '       It writes firmware to 0x0 and BRICKS fused boards by erasing the'
	@echo '       signed Sipeed Stage 1 (our firmware is Stage 2 @0x40000).'
	@echo '       Use the supported flasher instead (from src/a2n20_bl616/):'
	@echo '         ./tools/a2n20-mcu-program --stage2 \'
	@echo '             --firmware firmware_host/build/build_out/a2n20_bl616_host_bl616.bin'
	@echo '       Coding agents: use the /flash-mcu skill.'
	@echo ''
	@exit 1
