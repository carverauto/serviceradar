#!/usr/bin/env bash
set -euo pipefail

systemctl stop serviceradar-web-ng.service 2>/dev/null || true
