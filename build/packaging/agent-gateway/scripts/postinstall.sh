#!/usr/bin/env bash
set -euo pipefail

TAR_PATH="/usr/local/share/serviceradar-agent-gateway/serviceradar-agent-gateway.tar.gz"
INSTALL_DIR="/usr/local/share/serviceradar-agent-gateway"

mkdir -p "$INSTALL_DIR"

if [ -f "$TAR_PATH" ]; then
  tar -xzf "$TAR_PATH" -C "$INSTALL_DIR"
  chmod +x "$INSTALL_DIR/bin/serviceradar_agent_gateway" || true
fi

systemctl daemon-reload || true
