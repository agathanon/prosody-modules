#!/bin/sh
# Run scansion integration tests against a throwaway Prosody, once per
# storage backend.
#
# Usage: test/run-scansion.sh [script.scs ...]
#   With no arguments, runs every mod_*/spec/scansion/*.scs.
#   TEST_BACKENDS="internal sql" selects the storage backends to test.
#   SCANSION_ARGS="-v" passes extra options to scansion.
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
	set -- mod_*/spec/scansion/*.scs
fi

test/certs.sh

compose() {
	docker compose -f test/docker-compose.yml -p prosody-modules-test "$@"
}

status=0
for backend in ${TEST_BACKENDS:-internal sql}; do
	echo "== Storage backend: $backend"
	# Exported so every compose call sees the same config; otherwise
	# "compose run" would recreate Prosody with the default backend
	export TEST_STORAGE="$backend"
	compose up -d --wait prosody
	# shellcheck disable=SC2086
	if ! compose run --rm --no-deps -T scansion -h prosody ${SCANSION_ARGS:-} "$@"; then
		status=1
		compose logs prosody | tail -n 50
	fi
	# Guard against silently testing the wrong backend
	driver=$(compose exec -T prosody prosodyctl shell \
		"> local _, name = require'prosody.core.storagemanager'.get_driver('localhost', 'recovery_email'); return name" \
		| sed -n 's/^Result: //p')
	if [ "$driver" != "$backend" ]; then
		echo "ERROR: expected storage driver '$backend', Prosody used '$driver'"
		status=1
	fi
	compose down -v
done
exit "$status"
