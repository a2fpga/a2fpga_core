/*
Tools->Board->Boards Manager->esp32 by espressif
Tools->USB CDC On Boot: Enabled
Tools->CPU Frequency: 80 MHz (WiFi)
Tools->Board: XIAO_ESP32S3
Tools->JTAG Adapter: Integrated USB JTAG
Tools->USB Mode: Hardware CDC and JTAG
*/

#include "soc/usb_serial_jtag_reg.h" // JTAG WRITE_PERI_REG
#include "soc/gpio_sig_map.h" // JTAG gpio_connect_out

/*
references
https://esp32.com/viewtopic.php?t=25670
https://eloquentarduino.com/posts/esp32-cam-quickstart
*/

//#define LED_ON  LOW
//#define LED_OFF HIGH

#define RXD  44
#define TXD  43
#define BAUD 115200

#define PIN_TCK  40
#define PIN_TMS  41
#define PIN_TDI  42
#define PIN_TDO  45
#define PIN_SRST 21

#define FPGA_DONE  48

/* ULX3S v3.1.7 S3 prototype
#define PIN_TCK  39
#define PIN_TMS  38
#define PIN_TDI  1
#define PIN_TDO  6
#define PIN_SRST 41
*/

/*
#if CONFIG_IDF_TARGET_ESP32S3
#define USB_JTAG_TCK_IDX        85
#define USB_JTAG_TMS_IDX        86
#define USB_JTAG_TDI_IDX        87
#define USB_JTAG_TRST_IDX       251
#define USB_JTAG_TDO_BRIDGE_IDX 251
#endif

#if CONFIG_IDF_TARGET_ESP32C3
// untested
#define USB_JTAG_TCK_IDX        36
#define USB_JTAG_TMS_IDX        37
#define USB_JTAG_TDI_IDX        38
#define USB_JTAG_TRST_IDX       127
#define USB_JTAG_TDO_BRIDGE_IDX 39
#endif
*/

bool usb_was_connected = false;

/* arguments are GPIO pin numbers like (1,2,3,4,5) */
void route_usb_jtag_to_gpio()
{
//  digitalWrite(LED_BUILTIN, LED_ON);
  pinMode(PIN_TCK, OUTPUT);
  pinMode(PIN_TMS, OUTPUT);
  pinMode(PIN_TDI, OUTPUT);
  pinMode(PIN_TDO, INPUT);
  pinMode(PIN_SRST, OUTPUT);
  WRITE_PERI_REG(USB_SERIAL_JTAG_CONF0_REG,
    READ_PERI_REG(USB_SERIAL_JTAG_CONF0_REG)
  | USB_SERIAL_JTAG_USB_JTAG_BRIDGE_EN);
  // esp_rom_gpio_connect_out_signal(GPIO, IOMATRIX, false, false);
  esp_rom_gpio_connect_out_signal(PIN_TCK,   USB_JTAG_TCK_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_TMS,   USB_JTAG_TMS_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_TDI,   USB_JTAG_TDI_IDX,  false, false);
  esp_rom_gpio_connect_out_signal(PIN_SRST,  USB_JTAG_TRST_IDX, false, false);
  esp_rom_gpio_connect_in_signal (PIN_TDO,   USB_JTAG_TDO_BRIDGE_IDX,  false);

  pinMode(FPGA_DONE, INPUT);
  //digitalWrite(FPGA_DONE, HIGH);
}

void unroute_usb_jtag_to_gpio()
{
  WRITE_PERI_REG(USB_SERIAL_JTAG_CONF0_REG,
    READ_PERI_REG(USB_SERIAL_JTAG_CONF0_REG)
  & ~USB_SERIAL_JTAG_USB_JTAG_BRIDGE_EN);
  pinMode(PIN_TCK,  INPUT);
  pinMode(PIN_TMS,  INPUT);
  pinMode(PIN_TDI,  INPUT);
  pinMode(PIN_TDO,  INPUT);
  pinMode(PIN_SRST, INPUT);

  pinMode(FPGA_DONE, INPUT);
  //digitalWrite(FPGA_DONE, HIGH);
//  digitalWrite(LED_BUILTIN, LED_OFF);
}

void setup()
{
//  pinMode(LED_BUILTIN, OUTPUT);
//  digitalWrite(LED_BUILTIN, LED_OFF);
  pinMode(FPGA_DONE, INPUT);
  //digitalWrite(FPGA_DONE, HIGH);
  Serial.begin(); // usb-serial
  Serial1.begin(BAUD, SERIAL_8N1, RXD, TXD); // hardware serial
}

void loop() {
  if(Serial.available())
    Serial1.write(Serial.read());
  if(Serial1.available())
    Serial.write(Serial1.read());
  bool usb_is_connected = usb_serial_jtag_is_connected();
  if(usb_was_connected == false && usb_is_connected == true)
    route_usb_jtag_to_gpio();
  if(usb_was_connected == true && usb_is_connected == false)
    unroute_usb_jtag_to_gpio();
  usb_was_connected = usb_is_connected;
}