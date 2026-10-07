#!/usr/bin/env bash
set -euo pipefail

for script in "$@"; do
    if awk '
        /^[[:space:]]*(chown|chmod)[[:space:]]+/ {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/"/, "", line)
            recursive = line ~ /(^|[[:space:]])--recursive([[:space:]]|$)/ ||
                line ~ /(^|[[:space:]])-[A-Za-z]*R[A-Za-z]*([[:space:]]|$)/
            shared_root = line ~ /\/(etc|var\/lib)\/serviceradar\/?([[:space:]]|$)/ ||
                line ~ /\$\{?serviceradar_(etc|var)_dir\}?\/?([[:space:]]|$)/
            if (recursive && shared_root) {
                print FILENAME ": unsafe recursive shared-state permission change: " $0
                failed = 1
            }
        }
        END { exit failed }
    ' "$script"; then
        continue
    fi
    exit 1
done

agent_postinstall="$1"
if awk '
    /\/var\/lib\/serviceradar\/agent(\/|[[:space:]]|$)/ {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)
        if (line != "" && line !~ /semanage[[:space:]]+fcontext/) {
            print FILENAME ": privileged reference to service-writable agent runtime: " $0
            failed = 1
        }
    }
    END { exit failed }
' "$agent_postinstall"; then
    exit 0
fi
exit 1
