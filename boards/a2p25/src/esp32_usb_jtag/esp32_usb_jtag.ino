/*
Tools->Board->Boards Manager->esp32 by espressif
Tools->USB CDC On Boot: Enabled
Tools->CPU Frequency: 80 MHz (WiFi)
Tools->Board: Adafruit QT Py ESP32-S3 (4M Flash 2M PSRAM)
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

#define PIN_LED0 1
#define PIN_LED1 2

#define LED_ON  HIGH
#define LED_OFF LOW

// DIP Switches
#define PIN_SW1  3
#define PIN_SW2  4
#define PIN_SW3  5
#define PIN_SW4  6

// Unassigned pins from the FPGA
#define PIN_FPGA_0 9
#define PIN_FPGA_1 10
#define PIN_FPGA_2 11

// QSPI Interface to the FPGA
#define PIN_QSPI_CS 12
#define PIN_QSPI_CLK 13
#define PIN_QSPI_D0 14
#define PIN_QSPI_D1 15
#define PIN_QSPI_D2 16
#define PIN_QSPI_D3 17

// Interrupt signal from the FPGA
#define PIN_INT  18

// I2S Interface to the FPGA
#define PIN_I2S_BCLK  21
#define PIN_I2S_DOUT  33
#define PIN_I2S_WS    47

// SD Card Interface
#define PIN_SD_CMD  37
#define PIN_SD_CLK  36
#define PIN_SD_D0   38
#define PIN_SD_D1   39
#define PIN_SD_D2   34
#define PIN_SD_D3   35
#define PIN_SD_DET  46

// Serial interface to the FPGA
#define PIN_RXD  44
#define PIN_TXD  43
#define BAUD 115200

// JTAG interface to the FPGA
#define PIN_TCK  40
#define PIN_TMS  41
#define PIN_TDI  42
#define PIN_TDO  45
#define PIN_SRST 7  // unused and unconnected, but required by the JTAG bridge

// Configuration done signal from the FPGA
#define PIN_FPGA_DONE  48

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

  //pinMode(PIN_FPGA_DONE, INPUT);
  //digitalWrite(PIN_FPGA_DONE, HIGH);

  //pinMode(PIN_LED1, OUTPUT);
  //digitalWrite(PIN_LED1, LED_ON);
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

 //pinMode(PIN_LED1, OUTPUT);
  //digitalWrite(PIN_LED1, LED_ON);  
  //digitalWrite(PIN_FPGA_DONE, HIGH);
  //  digitalWrite(LED_BUILTIN, LED_OFF);

}

void setup()
{
  pinMode(PIN_FPGA_DONE, INPUT_PULLUP);
  pinMode(9, INPUT_PULLUP);
  pinMode(PIN_LED0, OUTPUT);
  //digitalWrite(PIN_LED0, LED_ON);
  pinMode(PIN_LED1, OUTPUT);
  //digitalWrite(PIN_LED1, LED_OFF);
  //pinMode(PIN_I2S_BCLK, INPUT_PULLUP);
  pinMode(PIN_I2S_BCLK, OUTPUT);
  digitalWrite(PIN_I2S_BCLK, HIGH);

  //pinMode(PIN_FPGA_DONE, INPUT);
  //digitalWrite(PIN_FPGA_DONE, HIGH);
  Serial.begin(); // usb-serial
  Serial1.begin(BAUD, SERIAL_8N1, PIN_RXD, PIN_TXD); // hardware serial
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
  int value = digitalRead(PIN_FPGA_DONE);  // Read input
  digitalWrite(PIN_LED0, value);     // Set output
  value = digitalRead(9);  // Read input
  digitalWrite(PIN_LED1, value);     // Set output
}