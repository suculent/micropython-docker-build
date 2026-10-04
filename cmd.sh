#!/usr/bin/env bash

set -e

# --- thinx.yml ----------------------------------------------------------------
#
# thinx.yml is repository content, and the THiNX API writes decrypted devsec
# credentials into it before a build. It is read here, never printed, eval'd or
# sourced. This script used to run `parse_yaml thinx.yml`, which would print
# every value (devsec included) into the build log, and `eval $(parse_yaml
# thinx.yml)`, which would run any $(...), backtick or quote break-out in a
# value as shell, in a container that may hold docker.sock. parse_yaml was
# never defined here, so both failed and set -e ended the build instead.
#
# thinx_yml_load FILE assigns, with plain `name=$value` assignments, only the
# names this script reads:
#   micropython_platform micropython_modules
# Any other name is ignored. Nothing is exported and nothing is printed.
#
# Names follow the old parse_yaml: the parent keys joined with "_" (two spaces
# of indent per level), e.g. micropython: / platform: -> micropython_platform.
# Values:
#  - key: "..."  quotes dropped; \" and \\ decoded (the escapes eval used to
#    decode the same way); any other backslash stays as it is;
#  - - "..."     a double-quoted list item: the same;
#  - key: ...    taken as written: $, `, ;, \ and quotes stay literal;
#  - a trailing CR (CRLF files) is dropped;
#  - a value that continues on the next line (block scalar |/>, folded plain
#    or multi-line quoted scalar) or holds a control character other than
#    tab (NUL included) is rejected; its variable is left as it was.
# A list item (`- item` under a key) appended to a bash array in the sibling
# images' parse_yaml. micropython_modules is a word list (keep_module below
# splits it), so a list item appends to it after a space: modules: with the
# items "- A" and "- B" gives "A B", the same words the array held.
# micropython_platform is read as ${micropython_platform}, the array's first
# element, so a list item only sets it while it has no value yet. A plain key
# value replaces either, as `name=(...)` did.
#
# Same awk as thinx_yml_load in the THiNX worker (services/worker/builder-lib.sh)
# and the arduino, platformio and nodemcu builder images; keep them in step.
# A missing FILE sets nothing. Returns 0.
thinx_yml_load()
{
	[ -f "$1" ] || return 0

	thinx_yml_pairs=$(tr '\000' '\001' < "$1" | awk '
		function unescape_dq(s,    out, i, n, c, d) {
			out = ""
			n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c == "\\" && i < n) {
					d = substr(s, i + 1, 1)
					if (d == "\\" || d == "\"") {
						out = out d
						i++
						continue
					}
				}
				out = out c
			}
			return out
		}
		function flush() {
			if (pending != "") print pending
			pending = ""
		}
		{
			line = $0
			sub(/\r$/, "", line)
			match(line, /^[ \t]*/)
			ind = substr(line, 1, RLENGTH)
			rest = substr(line, RLENGTH + 1)
			match(rest, /^[A-Za-z0-9_]*/)
			key = substr(rest, 1, RLENGTH)
			rest = substr(rest, RLENGTH + 1)

			if (rest ~ /^[ \t]*:[ \t]*".*"[ \t]*$/) {
				style = "dq"
			} else if (rest ~ /^[ \t]*[:-]/) {
				style = "plain"
			} else {
				# Not a key line. Blank lines and comments are skipped;
				# anything else continues the previous value, which is
				# then multi-line and rejected.
				if (line !~ /^[ \t]*(#.*)?$/) pending = ""
				next
			}

			flush()

			indent = length(ind) / 2
			vname[indent] = key
			for (i in vname) { if (i > indent) { delete vname[i] } }

			value = rest
			if (style == "dq") {
				sub(/^[ \t]*:[ \t]*"/, "", value)
				sub(/"[ \t]*$/, "", value)
				value = unescape_dq(value)
			} else {
				sub(/^[ \t]*[:-][ \t]*/, "", value)
				if (value ~ /^".*"[ \t]*$/) {
					# - "item": eval dropped these quotes too.
					sub(/[ \t]*$/, "", value)
					value = unescape_dq(substr(value, 2, length(value) - 2))
				}
			}

			if (length(value) == 0) next
			if (style == "plain" && value ~ /^[|>][-+0-9]*[ \t]*$/) next

			tabless = value
			gsub(/\t/, "", tabless)
			if (tabless ~ /[[:cntrl:]]/) next

			vn = ""
			for (i = 0; i < indent; i++) { vn = (vn)(vname[i])("_") }
			name = vn key
			# A trailing "_" is a list item: the old parse_yaml made it "+=".
			op = "="
			if (sub(/_$/, "", name)) op = "+="
			if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next

			pending = name op value
		}
		END { flush() }
	')

	# The here-document expands $thinx_yml_pairs once; its text is not
	# expanded again, and each value is assigned, never evaluated.
	# See above for list items; any other value replaces.
	while IFS= read -r thinx_yml_line
	do
		thinx_yml_name=${thinx_yml_line%%=*}
		thinx_yml_value=${thinx_yml_line#*=}
		thinx_yml_append=
		case "$thinx_yml_name" in
			*+) thinx_yml_append=1; thinx_yml_name=${thinx_yml_name%+} ;;
		esac
		case "$thinx_yml_name" in
			micropython_platform) [ -n "$thinx_yml_append" ] && [ -n "${micropython_platform+set}" ] || micropython_platform=$thinx_yml_value ;;
			micropython_modules)
				[ -n "$thinx_yml_append" ] || micropython_modules=
				micropython_modules=${micropython_modules:+$micropython_modules }$thinx_yml_value ;;
		esac
	done <<THINX_YML_PAIRS
$thinx_yml_pairs
THINX_YML_PAIRS

	unset thinx_yml_pairs thinx_yml_line thinx_yml_name thinx_yml_value thinx_yml_append
	return 0
}

# --- build --------------------------------------------------------------------
#
# Contract with the THiNX worker (services/worker, builder-lib.sh upy_build;
# see README.md, "THiNX worker contract"):
#  - the repository is mounted at /opt/workspace, and the image runs its
#    default CMD (this script) as the micropython user;
#  - thinx.yml is read only through thinx_yml_load above:
#      micropython.platform  esp8266 (the default) is the only platform this
#                            image has a toolchain for; anything else fails;
#      micropython.modules   the port's own modules to keep (a list, or one
#                            space-separated string); without it all are kept.
#                            _boot.py, flashbdev.py and inisetup.py are always
#                            kept: _boot.py mounts the filesystem with them;
#  - every *.py in the repository root, then in its modules/ directory, is
#    copied into the port's modules directory, which the build freezes into
#    the firmware (modules/x.py wins over x.py). Symlinks and names that are
#    not importable (e.g. "thinx copy.py") are skipped;
#  - the image goes to /opt/workspace/build/firmware.bin. The worker creates
#    build/ writable for this user and deploys the file; it also checks the
#    size, this script does not;
#  - the last line is "THiNX BUILD SUCCESSFUL." with exit status 0, or
#    "THiNX BUILD FAILED: <status>" with a non-zero one, and no firmware.bin.
#
# WORKSPACE, SDK_DIR and MPY_DIR exist for tests/cmd-build.sh; the worker
# leaves them unset. Plain POSIX sh, so the test can run it under busybox too.

WORKSPACE=${WORKSPACE:-/opt/workspace}
SDK_DIR=${SDK_DIR:-/esp-open-sdk}
MPY_DIR=${MPY_DIR:-/micropython}

YMLFILE=$WORKSPACE/thinx.yml
OUTDIR=$WORKSPACE/build
OUTFILE=$OUTDIR/firmware.bin
BOOT_MODULES="_boot.py flashbdev.py inisetup.py"

finish()
{
	finish_rc=$?
	echo ""
	if [ "$finish_rc" -eq 0 ]; then
		echo "THiNX BUILD SUCCESSFUL."
	else
		rm -f "$OUTFILE" 2>/dev/null
		echo "THiNX BUILD FAILED: $finish_rc"
	fi
}

fail()
{
	echo "$*"
	exit 1
}

# True when $1 is one of the boot modules or listed in micropython.modules.
# The list is split into words with globbing off: an item is a name, never
# a pattern.
keep_module()
{
	set -f
	for keep_word in $BOOT_MODULES $micropython_modules
	do
		if [ "$keep_word" = "$1" ]; then
			set +f
			return 0
		fi
	done
	set +f
	return 1
}

# Copies the *.py files of directory $1 into the port's modules directory.
freeze_dir()
{
	for freeze_src in "$1"/*.py
	do
		[ -f "$freeze_src" ] || continue
		freeze_name=${freeze_src##*/}
		if [ -L "$freeze_src" ]; then
			echo "Skipping ${freeze_name}: a symlink"
			continue
		fi
		case ${freeze_name%.py} in
			''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
				echo "Skipping ${freeze_name}: not an importable module name"
				continue ;;
		esac
		cp "$freeze_src" "$MODULES_DIR/$freeze_name"
		echo "Freezing ${freeze_name}"
	done
}

trap finish EXIT

mkdir -p "$OUTDIR" 2>/dev/null || true
[ -d "$OUTDIR" ] && [ -w "$OUTDIR" ] || fail "Cannot write to $OUTDIR."
rm -f "$OUTFILE"

unset micropython_platform micropython_modules
PLATFORM=esp8266

if [ -f "$YMLFILE" ]; then
	echo "Reading thinx.yml"
	thinx_yml_load "$YMLFILE"
	if [ -n "${micropython_platform}" ]; then
		PLATFORM=${micropython_platform}
	fi
fi

case $PLATFORM in
	esp8266) ;;
	*) fail "micropython.platform in thinx.yml is not supported: this image builds esp8266 only." ;;
esac

PORT_DIR=$MPY_DIR/ports/$PLATFORM
MODULES_DIR=$PORT_DIR/modules
[ -d "$MODULES_DIR" ] || fail "No MicroPython $PLATFORM port at $PORT_DIR."

TOOLCHAIN_BIN=$SDK_DIR/xtensa-lx106-elf/bin
[ -x "$TOOLCHAIN_BIN/xtensa-lx106-elf-gcc" ] ||
	fail "No xtensa-lx106-elf toolchain in $TOOLCHAIN_BIN: the image has to build esp-open-sdk (see Dockerfile)."
PATH=$TOOLCHAIN_BIN:$PATH
export PATH
command -v python3 > /dev/null 2>&1 || fail "python3 is missing: MicroPython builds with it."
command -v esptool > /dev/null 2>&1 || fail "esptool is missing: the esp8266 port needs it to create the image."

if [ -n "${micropython_modules}" ]; then
	for stock in "$MODULES_DIR"/*.py
	do
		[ -f "$stock" ] || continue
		if keep_module "${stock##*/}"; then
			echo "Keeping MicroPython module ${stock##*/}"
		else
			echo "Dropping MicroPython module ${stock##*/}"
			rm -f "$stock"
		fi
	done
fi

freeze_dir "$WORKSPACE"
if [ -d "$WORKSPACE/modules" ] && [ ! -L "$WORKSPACE/modules" ]; then
	freeze_dir "$WORKSPACE/modules"
fi

echo "Building mpy-cross"
make -C "$MPY_DIR/mpy-cross"

echo "Building MicroPython for $PLATFORM"
make -C "$PORT_DIR" BUILD=build-thinx

FIRMWARE=$PORT_DIR/build-thinx/firmware.bin
[ -f "$FIRMWARE" ] || fail "The build produced no $FIRMWARE."
cp "$FIRMWARE" "$OUTFILE"
echo "Firmware: $OUTFILE ($(wc -c < "$OUTFILE" | tr -d ' ') bytes)"
