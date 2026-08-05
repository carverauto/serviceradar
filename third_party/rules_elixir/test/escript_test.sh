#! /usr/bin/env bash
set -exo pipefail

if [[ -n "$ERLANG_RELEASE_TAR_SHORT_PATH" ]]; then
    mkdir -p $(dirname "$OTP_INSTALL_PATH")
    if mkdir "$OTP_INSTALL_PATH"; then
        tar --extract \
            --directory "$OTP_INSTALL_PATH" \
            --file "$ERLANG_RELEASE_TAR_SHORT_PATH"
    fi
fi

PATH="$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"

./basic hello there | tee out.log

grep "hello" out.log
grep "there" out.log

rm out.log
