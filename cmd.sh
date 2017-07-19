#!/usr/bin/env bash

set -e

cd esp-open-sdk && make STANDALONE=y

PATH=/esp-open-sdk/xtensa-lx106-elf/bin:$PATH

cd micropython/mpy-cross && make

cd micropython/esp8266 && make axtls && make