FROM ubuntu:focal
ARG VERSION=master
LABEL maintainer="Matej Sychra <suculent@me.com>"

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -qq -y make unrar-free autoconf automake libtool gcc g++ gperf \
    flex bison texinfo gawk ncurses-dev libexpat-dev python2-dev python2 \
    sed git unzip bash help2man wget bzip2

RUN apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --no-create-home micropython

RUN git clone --recursive https://github.com/pfalcon/esp-open-sdk.git \
  && git clone https://github.com/micropython/micropython.git \
  && cd micropython && git checkout $VERSION && git submodule update --init \
  && chown -R micropython:micropython ../esp-open-sdk ../micropython

USER micropython

COPY cmd.sh /opt/

CMD /opt/cmd.sh
