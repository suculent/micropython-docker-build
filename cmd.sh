#!/usr/bin/env bash

set -e

cd esp-open-sdk && make STANDALONE=y

PATH=/esp-open-sdk/xtensa-lx106-elf/bin:$PATH

cd micropython/mpy-cross && make

# Parse thinx.yml config

PLATFORM="esp8266"

if [[ -f "thinx.yml" ]]; then
  echo "Reading thinx.yml:"
  parse_yaml thinx.yml
  eval $(parse_yaml thinx.yml)

  if [[ ! -z ${micropython_platform} ]]; then
    PLATFORM=${micropython_platform}
  fi
fi

cd micropython/$PLATFORM

if [[ ! -z ${micropython_modules[@]} ]]; then
  pushd modules
  MODULES=$(ls -l *.py)
  echo "- modules: ${micropython_modules[@]}"
  for module in ${micropython_modules[@]} do
    if [[ "module" == "_boot.py" ]]; then
      break;
    fi
    if [[ $MODULES == "*${module}*"]]; then
      echo "Enabling Micropython module ${module}"
    else
      echo "Disabling Micrphython module ${module}"
      rm -rf ${module}
    fi
  done
  popd
fi

# Will probably build both firmwares and builder.sh must choose based on thinx.yml on deployment...

make axtls && make

# Report build status using logfile
if [[ $? == 0 ]]; then
  echo "THiNX BUILD SUCCESSFUL."
else
  echo "THiNX BUILD FAILED: $?"
fi