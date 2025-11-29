#!/usr/bin/env sh
set -eu

CONFIG="${CONFIG_PATH:-/etc/serviceradar/checkers/sysmon-vm.json}"

# Prefer generated config if onboarding wrote one
if [ -f /var/lib/serviceradar/config/checker.json ]; then
  CONFIG="/var/lib/serviceradar/config/checker.json"
fi

exec /usr/local/bin/serviceradar-sysmon-vm --config "${CONFIG}"
