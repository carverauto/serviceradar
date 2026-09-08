#!/usr/bin/env bash
set -euo pipefail

for script in "$@"; do
    if awk '
        /^[[:space:]]*chown[[:space:]]+-R[[:space:]]+/ {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/"/, "", line)
            if (line ~ /\/var\/lib\/serviceradar[[:space:]]*$/ ||
                line ~ /\$\{?serviceradar_var_dir\}?[[:space:]]*$/) {
                print FILENAME ": unsafe recursive ownership change: " $0
                failed = 1
            }
        }
        END { exit failed }
    ' "$script"; then
        continue
    fi
    exit 1
done
