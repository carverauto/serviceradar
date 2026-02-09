#!/usr/bin/env bash
set -euo pipefail

systemctl stop serviceradar-agent-gateway.service 2>/dev/null || true
