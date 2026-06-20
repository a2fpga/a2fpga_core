# SDK_DEMO_PATH must be absolute: SDK v2.3.27's extension.cmake builds the
# linker flag as -T${SDK_DEMO_PATH}/${BUILD_DIR}/generated/linker.ld and the
# link runs from inside build/, so a relative "." resolves one level too deep.
SDK_DEMO_PATH ?= $(abspath .)
BL_SDK_BASE ?= $(SDK_DEMO_PATH)/../../bouffalo_sdk

export BL_SDK_BASE

CHIP ?= bl616
BOARD ?= bl616dk
CROSS_COMPILE ?= riscv64-unknown-elf-

# Use Stage 2 flash config if specified: make flash FLASH_CFG=flash_stage2_cfg.ini
ifdef FLASH_CFG
cmake_definition += -DCONFIG_FLASH_CFG=$(FLASH_CFG)
endif

include $(BL_SDK_BASE)/project.build
