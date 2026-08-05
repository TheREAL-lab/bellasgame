#!/usr/bin/env bash
#
# Runs the test suite headlessly and exits non-zero if anything is wrong.
#
#   ./scripts/run_tests.sh                     # everything
#   ./scripts/run_tests.sh --filter=vision     # one file, or one test
#   ./scripts/run_tests.sh --smoke             # the play-a-whole-round smoke test
#
# Set GODOT to pick a specific binary:
#   GODOT=/path/to/Godot ./scripts/run_tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_godot() {
	if [[ -n "${GODOT:-}" ]]; then
		echo "$GODOT"
		return
	fi
	for candidate in godot godot4 Godot; do
		if command -v "$candidate" >/dev/null 2>&1; then
			echo "$candidate"
			return
		fi
	done
	# The usual place a macOS drag-and-drop install ends up.
	for candidate in \
		"/Applications/Godot.app/Contents/MacOS/Godot" \
		"$HOME/Downloads/Godot.app/Contents/MacOS/Godot"; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return
		fi
	done
	return 1
}

if ! GODOT_BIN="$(find_godot)"; then
	cat >&2 <<-EOF
	Could not find Godot 4.

	Put it on your PATH, or point at it directly:
	  GODOT="/Applications/Godot.app/Contents/MacOS/Godot" $0
	EOF
	exit 127
fi

SMOKE=0
ARGS=()
for arg in "$@"; do
	if [[ "$arg" == "--smoke" ]]; then
		SMOKE=1
	else
		ARGS+=("$arg")
	fi
done

# A fresh clone has no .godot/, and the runner can't load scenes without it.
"$GODOT_BIN" --headless --path "$ROOT" --import >/dev/null

if [[ "$SMOKE" == "1" ]]; then
	exec "$GODOT_BIN" --headless --path "$ROOT" -- autotest
fi

exec "$GODOT_BIN" --headless --path "$ROOT" res://tests/TestRunner.tscn -- "${ARGS[@]+"${ARGS[@]}"}"
