#!/usr/bin/env bash
set -euo pipefail

TAR_PATH="/usr/local/share/serviceradar-web/serviceradar-web.tar.gz"
INSTALL_DIR="/usr/local/share/serviceradar-web"

mkdir -p "$INSTALL_DIR"

if [ -f "$TAR_PATH" ]; then
  tar -xzf "$TAR_PATH" -C "$INSTALL_DIR"
  chmod +x "$INSTALL_DIR/bin/serviceradar_web_ng" || true
fi

systemctl daemon-reload || true
