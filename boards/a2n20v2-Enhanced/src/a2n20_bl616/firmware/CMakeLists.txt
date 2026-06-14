cmake_minimum_required(VERSION 3.15)

include(proj.conf)

find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})

sdk_add_include_directories(.)

target_sources(app PRIVATE
    usb_descriptor.c
    usbd_ftdi.c
    jtag_process.c
    uart_interface.c
    cli.c
    fpga_spi.c
    fpga_screen.c
    fpga_sd.c
    sdmm.c
    ff.c
    ffunicode.c
)
sdk_set_main_file(main.c)

project(a2n20_bl616)
