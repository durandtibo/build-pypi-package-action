#!/usr/bin/env bash
# Check that the inputs and outputs documented in README.md (the tables under "## Inputs" and
# "## Outputs") are exactly the inputs and outputs declared in action.yaml, and that the defaults
# of the inputs match. A renamed, added or removed input or output, or a changed default, must be
# reflected in the README.
set -euo pipefail

cd "$(dirname "$0")/.."

# names_in_action <inputs|outputs>: the keys of the top-level section, in file order.
names_in_action() {
	awk -v section="$1:" '
		$0 == section { in_section = 1; next }
		/^[^ #]/ { in_section = 0 }
		in_section && /^  [a-z][a-z0-9-]*:/ { sub(/^  /, ""); sub(/:.*/, ""); print }
	' action.yaml
}

# default_in_action <input>: the default value, without quotes.
default_in_action() {
	awk -v name="$1:" '
		$0 == "  " name { found = 1; next }
		/^  [a-z]/ { found = 0 }
		found && /^    default:/ { sub(/^    default: */, ""); sub(/ *#.*/, ""); gsub(/"/, ""); print; exit }
	' action.yaml
}

# readme_rows <Inputs|Outputs>: the table rows (first cell and, for inputs, the last cell) of
# the README section.
readme_rows() {
	awk -v heading="## $1" '
		$0 == heading { in_section = 1; next }
		/^#/ { in_section = 0 }
		in_section && /^\| `/ { print }
	' README.md
}

status=0
backtick=$'\x60'

check_names() {
	local kind="$1" section="$2" expected actual
	expected=$(names_in_action "${kind}" | LC_ALL=C sort)
	actual=$(readme_rows "${section}" | cut -d "${backtick}" -f 2 | LC_ALL=C sort)
	if [ "${expected}" != "${actual}" ]; then
		echo "::error::The ${kind} in README.md differ from action.yaml (< action.yaml, > README.md)"
		diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") || true
		status=1
	fi
}

check_names inputs Inputs
check_names outputs Outputs

# Defaults: the README shows a literal default in backticks (`3.14`), or words for the empty
# default ("resolved from the wheel", "`""` (disabled)").
while read -r name; do
	default=$(default_in_action "${name}")
	[ -n "${default}" ] || continue
	if ! readme_rows Inputs | grep -E "^\| \`${name}\`" | grep -qF "\`${default}\` "; then
		echo "::error::The default of the input '${name}' is '${default}' in action.yaml but not in README.md"
		status=1
	fi
done < <(names_in_action inputs)

if [ "${status}" -eq 0 ]; then
	echo "✅ README.md documents the inputs and outputs of action.yaml"
fi
exit "${status}"
