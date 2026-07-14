#!/bin/bash
set -Eeuxo pipefail

unset http_proxy https_proxy no_proxy
unset HTTP_PROXY HTTPS_PROXY NO_PROXY

if [[ "${CI:-}" == "true" ]] ; then
    mkdir -p .cargo
    echo "[term]" >> .cargo/config.toml
    echo "color = 'always'" >> .cargo/config.toml
fi

function testwrap {
    if which cargo-nextest ; then
        cargo nextest run "$@"
    else
        cargo test "$@"
    fi
} 

testwrap
testwrap --all-features
testwrap --no-default-features
testwrap --no-default-features --features basic-auth
testwrap --no-default-features --features charsets
testwrap --no-default-features --features compress
testwrap --no-default-features --features compress-zlib
testwrap --no-default-features --features compress-zlib-ng
testwrap --no-default-features --features form
testwrap --no-default-features --features multipart-form
testwrap --no-default-features --features json
testwrap --no-default-features --features single-threaded
testwrap --no-default-features --features tls-native
testwrap --no-default-features --features tls-native,tls-native-vendored
testwrap --no-default-features --features tls-rustls-webpki-roots
testwrap --no-default-features --features tls-rustls-native-roots
testwrap --no-default-features --features tls-rustls-webpki-roots-ring
testwrap --no-default-features --features tls-rustls-native-roots-ring
