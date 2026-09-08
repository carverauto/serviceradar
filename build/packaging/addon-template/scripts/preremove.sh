#!/bin/sh
# Pre-remove for an os-package native add-on: stop + disable whatever the agent may
# have activated, so removing the package leaves no orphaned timer/service. Best-effort
# (`|| true`) so removal never fails if the units were never enabled.
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop serviceradar-addon-example.timer >/dev/null 2>&1 || true
    systemctl stop serviceradar-addon-example.service >/dev/null 2>&1 || true
    systemctl disable serviceradar-addon-example.timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
