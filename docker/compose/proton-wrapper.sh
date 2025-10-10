#!/usr/bin/env bash
set -euo pipefail

PROTON_REAL=${PROTON_REAL:-/usr/local/bin/proton.bin}
GLIBC_LIB=${GLIBC_LIB:-/usr/glibc-compat/lib}
GLIBC_LIB64=${GLIBC_LIB64:-/usr/glibc-compat/lib64}
INTERPRETER_CANDIDATES="${PROTON_INTERPRETER:-}
/usr/glibc-compat/lib/ld-linux-x86-64.so.2
/usr/glibc-compat/lib64/ld-linux-x86-64.so.2
/lib64/ld-linux-x86-64.so.2
/lib/ld-linux-x86-64.so.2"

if [ ! -x "$PROTON_REAL" ]; then
    echo "proton wrapper: missing binary at $PROTON_REAL" >&2
    exit 127
fi

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
if [ -d "$GLIBC_LIB" ]; then
    LD_LIBRARY_PATH="$GLIBC_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
if [ -d "$GLIBC_LIB64" ]; then
    LD_LIBRARY_PATH="$GLIBC_LIB64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export LD_LIBRARY_PATH

for candidate in $INTERPRETER_CANDIDATES; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        exec "$candidate" "$PROTON_REAL" "$@"
    fi
    if [ -n "$candidate" ] && [ -r "$candidate" ]; then
        # Some images ship the interpreter as a regular file (ld-linux) without +x
        chmod +x "$candidate" 2>/dev/null || true
        if [ -x "$candidate" ]; then
            exec "$candidate" "$PROTON_REAL" "$@"
        fi
    fi
    # Try plain invocation with library path if candidate was empty string
    if [ -z "$candidate" ]; then
        continue
    fi
    # Continue searching
    true
done

exec "$PROTON_REAL" "$@"
