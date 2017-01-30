Micropython on ESP8266
======================
The repository provides a `Dockerfile` to build the [Micropython](https://micropython.org/) firmware for [ESP8266](https://en.wikipedia.org/wiki/ESP8266) boards.

***Warning***: The binary works on Ubuntu 14:04 and the build is based on Ubuntu 14:04

Build Instructions
------------------

Build the docker image. To specify a particular version of micropython provide it through the `build-arg`. Otherwise the HEAD of the master branch will be used.

```bash
  docker build -t micropython --build-arg VERSION=v1.8.1 .
```

Once the container is built successfuly create a container from the image

```bash
  docker create --name micropython micropython
```

Then copy the the built firmware into the host machine.

```bash
  docker cp micropython:/micropython/esp8266/build/firmware-combined.bin firmware-combined.bin
```

The firmware can then be uploaded with the esptool

```bash
  esptool.py --port ${SERIAL_PORT} --baud 115200 write_flash --verify --flash_size=8m 0 firmware-combined.bin
```

Here `${SERIAL_PORT}` is the path to the serial device on which the board is connected.

Flash from within Container
---------------------------

If you have built the image directly on your host (Linux), you also can flash your ESP directly by running a container from the image.
I prefereably **erase** flash memory of ESP8266 before starting flash a new firmware

```bash
docker run --rm -it --device ${SERIAL_PORT} --user root --workdir /micropython/esp8266 micropython make PORT=${SERIAL_PORT} erase deploy
```

Here `${SERIAL_PORT}` is the path to the serial device on which the board is connected.


Freeze personal script files in the build
-----------------------------------------

If you want to add personal python script to the build, link them into the container (-v docker option) before building and flashing the firmware
The directoty where to copy them is **modules** folder inside /micropython/esp8266/modules or run with a volume

```bash
docker run --rm -it -v $(pwd)/modules:/micropython/esp8266/modules --device /dev/ttyUSB0 --user root --workdir /micropython/esp8266 esp /bin/bash
make clean
make 
make PORT=/dev/ttyUSB0 erase deploy
```


Here `${SERIAL_PORT}` is the path to the serial device on which the board is connected.
