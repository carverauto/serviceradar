#!/usr/bin/env bash
set -euo pipefail

unit="$1"

grep -Fxq 'User=root' "$unit"
grep -Fxq 'Group=serviceradar' "$unit"
grep -Fxq 'CapabilityBoundingSet=' "$unit"
grep -Fxq 'StateDirectoryMode=2770' "$unit"
grep -Fxq 'ReadWritePaths=/var/lib/serviceradar/workload-identity /var/lib/serviceradar/agent/addons/workload-identity' "$unit"

if grep -Eq '^CapabilityBoundingSet=.*CAP_DAC_OVERRIDE' "$unit"; then
    echo "workload identity must use state-directory permissions, not CAP_DAC_OVERRIDE" >&2
    exit 1
fi
