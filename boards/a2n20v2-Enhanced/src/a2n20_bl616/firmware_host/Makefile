SDK_DEMO_PATH ?= .
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
