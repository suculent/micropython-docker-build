#!/bin/sh
#
# cmd.sh build test: the image's entrypoint runs end to end against stubs.
#
# The THiNX worker (services/worker, builder-lib.sh upy_build) runs this image
# with the repository mounted at /opt/workspace and the default CMD. cmd.sh
# must then, without a syntax error and with absolute paths:
#  - read /opt/workspace/thinx.yml (micropython.platform, micropython.modules)
#    through thinx_yml_load, printing none of it;
#  - copy the repository's *.py (its root and its modules/ directory) into the
#    port's modules directory, so the build freezes them into the firmware;
#    names that are not importable and symlinks are skipped;
#  - with a micropython.modules list, drop the port's own modules that are not
#    listed, except the ones _boot.py needs to mount the filesystem;
#  - build mpy-cross and the esp8266 port, and copy the image to
#    /opt/workspace/build/firmware.bin, where the worker picks it up;
#  - print "THiNX BUILD SUCCESSFUL" and exit 0, or "THiNX BUILD FAILED" and
#    exit non-zero (unsupported platform, missing toolchain, make failing,
#    no firmware produced).
#
# make, python3, esptool and the xtensa gcc are stubs, and the toolchain and
# MicroPython trees are fixtures, so this runs in seconds without Docker.
# WORKSPACE, SDK_DIR and MPY_DIR point cmd.sh at the fixtures.
#
# Plain POSIX sh; cmd.sh itself is run with $CMD_SHELL (default bash), so
#   sh tests/cmd-build.sh
#   CMD_SHELL="busybox sh" busybox sh tests/cmd-build.sh
# CMD_SH=/path/to/cmd.sh tests another copy.

HERE=$(cd "$(dirname "$0")" && pwd)
CMD_SH=${CMD_SH:-$HERE/../cmd.sh}
CMD_SHELL=${CMD_SHELL:-bash}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmd-build-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM

n=0
failed=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
not_ok() {
	n=$((n + 1)); failed=$((failed + 1))
	echo "not ok $n - $1"
	[ -z "${2-}" ] || echo "#   $2"
}
check() { # DESC COMMAND...: ok when COMMAND succeeds
	desc=$1; shift
	if "$@"; then ok "$desc"; else not_ok "$desc" "${WHY:-}"; fi
	WHY=
}

[ -f "$CMD_SH" ] || { echo "Bail out! no cmd.sh at $CMD_SH"; exit 1; }

STOCK="_boot.py apa102.py espnow.py flashbdev.py inisetup.py port_diag.py"

# The stub make: records its calls; for the port it snapshots the modules
# directory the build would freeze, then writes the firmware image (or fails).
cat > "$WORK/make.stub" <<'EOF'
#!/bin/sh
echo "make $*" >> "$STUB_DIR/make.log"
dir=$(pwd); build=; prev=
for a in "$@"; do
	[ "$prev" = "-C" ] && dir=$a
	case $a in BUILD=*) build=${a#BUILD=} ;; esac
	prev=$a
done
case $dir in
	*/mpy-cross) exit 0 ;;
	*/ports/esp8266)
		rm -rf "$STUB_DIR/frozen"
		cp -R "$dir/modules" "$STUB_DIR/frozen"
		if [ "${STUB_MAKE_RC:-0}" != 0 ]; then
			echo "stub make: compile error"
			exit "$STUB_MAKE_RC"
		fi
		[ -n "${STUB_NO_FW:-}" ] && exit 0
		out=$dir/${build:-build-ESP8266_GENERIC}
		mkdir -p "$out"
		head -c "${STUB_FW_SIZE:-20000}" /dev/zero | tr '\000' 'F' > "$out/firmware.bin"
		exit 0 ;;
esac
echo "stub make: unexpected call in $dir: $*" >&2
exit 2
EOF

# newcase NAME: fixture trees for one run; thinx.yml comes from stdin (feed a
# here-document or /dev/null, never a pipe).
newcase() {
	CASE=$WORK/$1
	WS=$CASE/ws
	SDK=$CASE/sdk
	MPY=$CASE/mpy
	STUB=$CASE/stub
	mkdir -p "$WS/modules" "$WS/build" "$SDK/xtensa-lx106-elf/bin" \
		"$MPY/mpy-cross" "$MPY/ports/esp8266/modules" "$STUB/bin"
	cat > "$WS/thinx.yml"
	[ -s "$WS/thinx.yml" ] || rm -f "$WS/thinx.yml"
	for m in $STOCK; do echo "# stock $m" > "$MPY/ports/esp8266/modules/$m"; done
	printf '#!/bin/sh\nexit 0\n' > "$SDK/xtensa-lx106-elf/bin/xtensa-lx106-elf-gcc"
	cp "$WORK/make.stub" "$STUB/bin/make"
	printf '#!/bin/sh\nexit 0\n' > "$STUB/bin/python3"
	printf '#!/bin/sh\nexit 0\n' > "$STUB/bin/esptool"
	chmod +x "$STUB/bin/make" "$STUB/bin/python3" "$STUB/bin/esptool" \
		"$SDK/xtensa-lx106-elf/bin/xtensa-lx106-elf-gcc"
	# a repository like suculent/thinx-firmware-esp8266-upy
	echo "import thinx" > "$WS/main.py"
	echo "# repo thinx" > "$WS/thinx.py"
	echo "# repo mqtt" > "$WS/mqtt.py"
	echo "# repo copy" > "$WS/thinx copy.py"
	echo "# repo sensor" > "$WS/modules/sensor.py"
	ln -s /etc/hostname "$WS/evil.py"
}

# run [VAR=value...]: runs cmd.sh on the current case; sets RC and OUT.
run() {
	OUT=$CASE/output
	( cd "$CASE" && env PATH="$STUB/bin:$PATH" STUB_DIR="$STUB" \
		WORKSPACE="$WS" SDK_DIR="$SDK" MPY_DIR="$MPY" "$@" \
		$CMD_SHELL "$CMD_SH" ) > "$OUT" 2>&1
	RC=$?
}

out_has() { grep -Fq -- "$1" "$OUT"; }
frozen() { [ -f "$STUB/frozen/$1" ]; }
frozen_set() { # the frozen file names, sorted, one line
	ls "$STUB/frozen" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'
}
port_built() { grep -q "ports/esp8266" "$STUB/make.log" 2>/dev/null; }
succeeded() {
	WHY="rc=$RC; $(tail -n 5 "$OUT" | tr '\n' '|')"
	[ "$RC" -eq 0 ] && out_has "THiNX BUILD SUCCESSFUL" && ! out_has "THiNX BUILD FAILED"
}
failed_cleanly() {
	WHY="rc=$RC; $(tail -n 5 "$OUT" | tr '\n' '|')"
	[ "$RC" -ne 0 ] && out_has "THiNX BUILD FAILED" && ! out_has "THiNX BUILD SUCCESSFUL" &&
		[ ! -e "$WS/build/firmware.bin" ]
}

echo "# cmd.sh: $CMD_SH (run with $CMD_SHELL)"

# --- syntax ---------------------------------------------------------------------

if command -v bash >/dev/null 2>&1; then
	check "cmd.sh parses under bash -n" bash -n "$CMD_SH"
fi
check "cmd.sh parses under $CMD_SHELL -n" $CMD_SHELL -n "$CMD_SH"

# --- the sample repository ------------------------------------------------------

newcase sample <<'EOF'
devsec:
  ssid: "SECRET-SSID-MARKER"
  pass: "SECRET-PASS-MARKER"
  ckey: "SECRET-CKEY-MARKER"
micropython:
  platform: esp8266
  build:
    type: firmware
EOF
run
check "the sample repository builds" succeeded
WHY="$(ls -l "$WS/build" 2>&1)"
check "the firmware is copied to /opt/workspace/build/firmware.bin" \
	test "$(wc -c < "$WS/build/firmware.bin" 2>/dev/null | tr -d ' ')" = 20000
WHY="make calls: $(cat "$STUB/make.log" 2>/dev/null | tr '\n' '|')"
check "mpy-cross and the esp8266 port are built (absolute paths)" \
	sh -c 'grep -q "^make -C $1/mpy-cross" "$2" && grep -q "^make -C $1/ports/esp8266" "$2"' _ "$MPY" "$STUB/make.log"
WHY="frozen: $(frozen_set)"
check "every stock module is kept when no list is given" \
	sh -c 'for m in $1; do [ -f "$2/$m" ] || exit 1; done' _ "$STOCK" "$STUB/frozen"
check "the repository's root *.py are frozen" sh -c '
	cmp -s "$1/main.py" "$2/main.py" && cmp -s "$1/thinx.py" "$2/thinx.py" && cmp -s "$1/mqtt.py" "$2/mqtt.py"' \
	_ "$WS" "$STUB/frozen"
check "the repository's modules/*.py are frozen" cmp -s "$WS/modules/sensor.py" "$STUB/frozen/sensor.py"
check "a file that is not an importable module name is skipped" test ! -e "$STUB/frozen/thinx copy.py"
check "a symlinked .py is not followed into the firmware" test ! -e "$STUB/frozen/evil.py"
WHY="$(grep -n 'SECRET-' "$OUT" | head -n 3)"
check "no devsec value is printed" sh -c '! grep -q "SECRET-" "$1"' _ "$OUT"

# --- micropython.modules --------------------------------------------------------

newcase modules-list <<'EOF'
micropython:
  modules:
    - apa102.py
    - main.py
    - dht.py
EOF
run
check "a modules list builds" succeeded
WHY="frozen: $(frozen_set)"
check "listed stock modules and the boot-time modules are kept, the rest dropped" \
	test "$(frozen_set)" = "_boot.py apa102.py flashbdev.py inisetup.py main.py mqtt.py sensor.py thinx.py"

newcase modules-scalar <<'EOF'
micropython:
  modules: "port_diag.py espnow.py"
EOF
run
WHY="frozen: $(frozen_set)"
check "a scalar modules string is a space-separated list" \
	test "$(frozen_set)" = "_boot.py espnow.py flashbdev.py inisetup.py main.py mqtt.py port_diag.py sensor.py thinx.py"

newcase modules-module-overrides-root < /dev/null
echo "# modules/ wins" > "$WS/modules/thinx.py"
run
check "modules/x.py replaces a root x.py of the same name" cmp -s "$WS/modules/thinx.py" "$STUB/frozen/thinx.py"

# --- defaults -------------------------------------------------------------------

newcase no-thinx-yml < /dev/null
run
check "a repository without thinx.yml builds for esp8266" succeeded

# --- failures -------------------------------------------------------------------

newcase platform-esp32 <<'EOF'
micropython:
  platform: esp32
EOF
run
check "an unsupported platform fails cleanly" failed_cleanly
check "an unsupported platform builds nothing" sh -c '! grep -q ports "$1" 2>/dev/null' _ "$STUB/make.log"

newcase make-fails < /dev/null
run STUB_MAKE_RC=2
check "a failing make fails the build" failed_cleanly

newcase no-firmware < /dev/null
run STUB_NO_FW=1
check "make succeeding without a firmware image fails the build" failed_cleanly

newcase small-firmware < /dev/null
run STUB_FW_SIZE=100
check "the image is copied whatever its size (the worker checks the size)" succeeded

newcase no-toolchain < /dev/null
rm -f "$SDK/xtensa-lx106-elf/bin/xtensa-lx106-elf-gcc"
run
check "a missing toolchain fails cleanly, without building" failed_cleanly
check "a missing toolchain is named in the log" out_has "xtensa-lx106-elf"

newcase stale-firmware < /dev/null
echo "stale" > "$WS/build/firmware.bin"
run STUB_MAKE_RC=2
check "a failed build leaves no firmware image behind" failed_cleanly

# --- repository values never run as shell ---------------------------------------

newcase marker <<'EOF'
micropython:
  platform: $(touch PWNED)
  modules:
    - $(touch PWNED)
    - "*"
EOF
run
check "a marker platform fails cleanly" failed_cleanly
check "no marker file is created" sh -c '[ ! -e "$1/PWNED" ] && [ ! -e "$2/PWNED" ]' _ "$CASE" "$WS"

newcase marker-modules <<'EOF'
micropython:
  modules:
    - $(touch PWNED)
    - "*"
    - ../../../etc/passwd
EOF
run
check "marker module names build" succeeded
check "marker module names run nothing" sh -c '[ ! -e "$1/PWNED" ] && [ ! -e "$2/PWNED" ]' _ "$CASE" "$WS"
WHY="frozen: $(frozen_set)"
check "a * entry keeps no extra stock module (it is not a glob)" \
	test "$(frozen_set)" = "_boot.py flashbdev.py inisetup.py main.py mqtt.py sensor.py thinx.py"

echo "1..$n"
if [ "$failed" -gt 0 ]; then
	echo "# $failed of $n failed"
	exit 1
fi
echo "# all $n passed"
