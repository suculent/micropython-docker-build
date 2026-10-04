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
# images' parse_yaml. micropython_modules is read as ${micropython_modules[@]},
# so a list item appends to it after a space: modules: with the items "- A"
# and "- B" gives "A B", which ${name[@]} expands to the same words the array
# would. micropython_platform is read as ${micropython_platform}, the array's
# first element, so a list item only sets it while it has no value yet. A
# plain key value replaces either, as `name=(...)` did.
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

cd esp-open-sdk && make STANDALONE=y

PATH=/esp-open-sdk/xtensa-lx106-elf/bin:$PATH

cd micropython/mpy-cross && make

# Parse thinx.yml config

PLATFORM="esp8266"

if [[ -f "thinx.yml" ]]; then
  echo "Reading thinx.yml"
  thinx_yml_load thinx.yml

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

RESULT=$?

echo ""

# Report build status using logfile
if [[ $RESULT == 0 ]]; then
  echo "THiNX BUILD SUCCESSFUL."
else
  echo "THiNX BUILD FAILED: $?"
fi
