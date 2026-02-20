#!/bin/sh
set -eu

RUNNER="${TEST_SRCDIR:?}/${TEST_WORKSPACE:?}/web-ng/precommit_runner.sh"

if [ ! -f "$RUNNER" ]; then
  echo "precommit runner not found at $RUNNER" >&2
  exit 1
fi

exec /bin/sh "$RUNNER"
