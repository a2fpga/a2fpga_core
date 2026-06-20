cmake_minimum_required(VERSION 3.15)

include(proj.conf)

find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})

# Pull in shared FPGA-SPI sources from the FT2232 firmware (../firmware) so we
# do not duplicate them. Only fpga_spi/fpga_screen are reused; the device-mode
# (FTDI/JTAG/UART/CLI) sources are intentionally excluded from the host build.
sdk_add_include_directories(. ../firmware)
# lwIP base config (SDK's reference lwipopts.h); our lwipopts_user.h overrides it.
sdk_add_include_directories($ENV{BL_SDK_BASE}/components/net/lwip/lwip/lwip-port/config)

target_sources(app PRIVATE
    usbh_xinput.c
    ../firmware/fpga_spi.c
    ../firmware/fpga_screen.c
)
sdk_set_main_file(main.c)

project(a2n20_bl616_host)
