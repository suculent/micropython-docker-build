FROM ubuntu:22.04
ARG VERSION=master
LABEL maintainer="Matej Sychra <suculent@me.com>"

ARG DEBIAN_FRONTEND=noninteractive

# python3 and esptool: MicroPython builds with python3, and the esp8266 port
# makes its image with `esptool elf2image`. libtool-bin, xz-utils and bc: the
# esp-open-sdk toolchain build (crosstool-NG) needs them. python3-dev and
# python-is-python3: its cross-gdb configure looks for `python` and fails
# without it (nodemcu-docker-build symlinks python3 for the same reason).
RUN apt-get update \
  && apt-get install -qq -y make unrar-free autoconf automake libtool libtool-bin gcc g++ gperf \
    flex bison texinfo gawk ncurses-dev libexpat-dev python2-dev python2 python3 python3-dev \
    python-is-python3 esptool sed git unzip bash help2man wget bzip2 xz-utils bc

RUN apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --no-create-home micropython

# esp-open-sdk: ChrisMacGregor's fork of pfalcon's, as nodemcu-docker-build
# uses. pfalcon's stops on 22.04 at crosstool-NG's configure ("could not
# find bash >= 3.1", seen 2026-10-04); the fork also carries fixes for
# gcc 4.8.5's reload1.c under the gcc 11 host and for moved isl/expat
# tarballs. Same toolchain (gcc 4.8.5) and NONOS SDK (2.1.0-18-g61248df).
RUN git clone --recursive https://github.com/ChrisMacGregor/esp-open-sdk.git \
  && git clone https://github.com/micropython/micropython.git \
  && cd micropython && git checkout $VERSION && git submodule update --init \
  && chown -R micropython:micropython ../esp-open-sdk ../micropython

# crosstool-NG refuses to run as root.
USER micropython

# Pre-seed the newlib tarball and widen crosstool-NG's download timeout, as
# nodemcu-docker-build does: crosstool-NG 1.22 has a single usable newlib
# mirror, fetched for a 15 MB file under a 10 s timeout. The version tracks
# CT_LIBC_NEWLIB_V_2_0_0 in crosstool-NG/samples/xtensa-lx106-elf/crosstool.config.
RUN mkdir -p /esp-open-sdk/tarballs && \
    ( wget -q -T 60 -t 5 -O /esp-open-sdk/tarballs/newlib-2.0.0.tar.gz \
        https://sourceware.org/pub/newlib/newlib-2.0.0.tar.gz || \
      wget -q -T 60 -t 5 -O /esp-open-sdk/tarballs/newlib-2.0.0.tar.gz \
        https://mirrors.kernel.org/sourceware/newlib/newlib-2.0.0.tar.gz ) && \
    echo "49c29e9129325e7c3b221aa829743ddcd796d024440e47c80fc0d6769af72d8a  /esp-open-sdk/tarballs/newlib-2.0.0.tar.gz" \
      | sha256sum -c - && \
    printf 'CT_LOCAL_TARBALLS_DIR="/esp-open-sdk/tarballs"\nCT_CONNECT_TIMEOUT=60\n' \
      >> /esp-open-sdk/crosstool-config-overrides

# The toolchain is built here, once: cmd.sh used to build it on every run,
# which a build service (1 CPU, 30 min) cannot finish.
RUN cd /esp-open-sdk && make STANDALONE=y

RUN make -C /micropython/mpy-cross

COPY cmd.sh /opt/

CMD /opt/cmd.sh
