Micropython on ESP8266
======================
The repository provides a `Dockerfile` to build the [Micropython](https://micropython.org/) firmware for [ESP8266](https://en.wikipedia.org/wiki/ESP8266) boards.

Based on [THiNX OpenSource IoT management platform](https://thinx.cloud).

The image is based on Ubuntu 22.04 (do not bump past it: the esp-open-sdk
toolchain does not build on newer hosts). It carries:

- the esp-open-sdk `xtensa-lx106-elf` toolchain, built when the image is built
  (`/esp-open-sdk`, [ChrisMacGregor's fork](https://github.com/ChrisMacGregor/esp-open-sdk),
  the same one `nodemcu-docker-build` uses);
- MicroPython (`/micropython`, branch or tag `VERSION`, default `master`) with
  `mpy-cross` built;
- `python3` and `esptool`, which the MicroPython esp8266 build needs;
- `/opt/cmd.sh`, the entrypoint, which runs as the unprivileged `micropython` user.

THiNX worker contract
---------------------

The THiNX build worker (`services/worker`, `upy_build` in `builder-lib.sh`)
runs this image for a repository whose platform is `micropython`:

- the repository is mounted at **`/opt/workspace`** and the image runs its
  default command (`/opt/cmd.sh`); nothing else is mounted or overridden;
- `cmd.sh` reads `/opt/workspace/thinx.yml` without evaluating or printing it
  (the THiNX API writes device credentials into it):

  ```yaml
  micropython:
    platform: esp8266   # the default, and the only platform this image builds
    modules:            # optional: the port's own modules to keep
      - apa102.py
      - port_diag.py
  ```

  Without `modules`, every module of the port's `modules/` directory is kept.
  With it, the unlisted ones are dropped, except `_boot.py`, `flashbdev.py`
  and `inisetup.py`, which `_boot.py` needs to mount the filesystem. Modules
  the port's manifest pulls from elsewhere (e.g. `dht`, `onewire`) are not
  affected. Any other `platform` fails the build;
- every `*.py` in the repository root, then in its `modules/` directory, is
  copied into the port's `modules/` directory, so the build freezes it into
  the firmware (a frozen `boot.py` / `main.py` runs at boot). `modules/x.py`
  wins over a root `x.py`. Symlinks and names that are not importable module
  names (e.g. `thinx copy.py`) are skipped;
- the firmware image is written to **`/opt/workspace/build/firmware.bin`**.
  The worker creates `build/` writable for the `micropython` user before the
  run, then deploys that file if it is over 10000 bytes;
- the log ends with `THiNX BUILD SUCCESSFUL.` and exit status 0, or with
  `THiNX BUILD FAILED: <status>`, a non-zero exit status and no
  `firmware.bin`.

File mode (`micropython: build: type: file` in thinx.yml) does not use this
image: the worker deploys the repository's `*.py` as they are.

Tests
-----

Plain `sh`, no Docker; both also run under `busybox sh`:

```bash
sh tests/cmd-build.sh            # cmd.sh end to end against a stub make/toolchain
sh tests/thinx-yml-loader.sh     # thinx.yml is never evaluated or printed
CMD_SHELL="busybox sh" busybox sh tests/cmd-build.sh
```

Build Instructions
------------------

Build the docker image of the master branch.

```bash
  docker build -t micropython .
```

To specify a particular version of micropython provide it through the `build-arg`. Otherwise the HEAD of the master branch will be used.

```bash
  docker build -t micropython --build-arg VERSION=<tag> .
```

`cmd.sh` expects the current source layout: `ports/esp8266`, and
`<BUILD>/firmware.bin` as the port's output (checked against `master` at
v1.30.0-preview, 2026-10-04). Old releases (`esp8266/` at the top level,
`firmware-combined.bin`, a separate `make axtls`) are not supported.

The build compiles the toolchain and takes a while (tens of minutes).

Build a project
---------------

```bash
mkdir -p build
chmod 777 build    # the image runs as the micropython user
docker run --rm -v "$(pwd)":/opt/workspace micropython
```

This leaves the firmware at `build/firmware.bin`. Flash it with esptool:

```bash
  esptool.py --port ${SERIAL_PORT} --baud 115200 write_flash --verify --flash_size=detect 0 build/firmware.bin
```

Here `${SERIAL_PORT}` is the path to the serial device on which the board is connected, generally `/dev/ttyUSB0`.

The `modules/` directory of this repository is a historical copy of the
esp8266 port's modules; the image does not use it.
