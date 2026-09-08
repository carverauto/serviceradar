#!/usr/bin/env bash
set -euo pipefail

systemctl stop serviceradar-core-elx.service 2>/dev/null || true
