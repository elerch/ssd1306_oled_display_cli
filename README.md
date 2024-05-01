[Phenominal walkthrough of a bunch of this stuff](https://nnarain.github.io/2020/12/01/SSD1306-OLED-Display-Driver-using-I2C.html)


Hardware
--------

SSD1306 display, 128x64.


The first incarnation was done via GIMP. We can get what we need though with ImageMagick:

magick openlogo.svg -resize 128x64 -background white -gravity center -extent 128x64 -monochrome txt:-

White pixels are #FC24FC24FC24, and black is #000000000.

We need to be in a format like openlogo.bits (for the moment)

From there, we can send to the display. Over Linux i2c, we can send a max of
32 bytes at a time, so we need to split up into multiple runs (4 horizontal or 2 vertical)

[Reference](https://stackoverflow.com/questions/25982525/why-i2c-smbus-block-max-is-limited-to-32-bytes)


Using linux i2c native
----------------------

```
i2cset 0 0x3c 0x00 0x21 0x00 0x7F i
       ^^ i2c bus number. These are /dev/i2c-n in Linux
          To find the things, use i2cdetect -y -r <bus number>

i2cset 0 0x3c 0x40 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 i
```


USB i2c mini
------------

[Driver](https://i2cdriver.com/i2cdriver.pdf)

```
./bitmap_to_i2ccl openlogo.bits > ~/i2cdriver/c/build/bytes
./i2ccl /dev/ttyUSB0 w 0x3c 0x00,0x20,0x00
                                   ^^ command

./i2ccl /dev/ttyUSB0 w 0x3c 0x40,`cat bytes`
                            ^^ i2c bus number
                                  ^^ data
```

i2ccl is doing more stuff for us though...

Initialization sequence:

```
0x00 0x8d 0x14 # Enable charge pump
0x00 0xaf      # Turn on display
```

Note that most real applications do a bunch of other things so as not to assume
any specific state on startup.

[Reference](https://github.com/adafruit/Adafruit_SSD1306/blob/master/Adafruit_SSD1306.cpp#L565-L616)
