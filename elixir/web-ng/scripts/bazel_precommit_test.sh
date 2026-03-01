#!/bin/sh
set -eu

unset ENV
unset BASH_ENV

ROOT="${TEST_SRCDIR:?}/${TEST_WORKSPACE:?}"
RUNNER="${ROOT}/elixir/web-ng/precommit_runner.sh"

if [ ! -f "$RUNNER" ]; then
  echo "precommit runner not found at $RUNNER" >&2
  exit 1
fi

exec /bin/sh "$RUNNER"
