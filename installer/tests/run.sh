#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for test_file in \
	"$ROOT/tests/test-model.sh" \
	"$ROOT/tests/test-discovery.sh" \
	"$ROOT/tests/test-plan.sh" \
	"$ROOT/tests/test-bridge.sh" \
	"$ROOT/tests/test-safety.sh"; do
	printf '\n== %s ==\n' "$(basename "$test_file")"
	/bin/sh "$test_file"
done

printf '\nAll installer model and safety tests passed.\n'
