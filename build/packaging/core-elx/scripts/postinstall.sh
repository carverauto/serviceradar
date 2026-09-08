#!/usr/bin/env bash
set -euo pipefail

TAR_PATH="/usr/local/share/serviceradar-core-elx/serviceradar-core-elx.tar.gz"
INSTALL_DIR="/usr/local/share/serviceradar-core-elx"

mkdir -p "$INSTALL_DIR"

if [ -f "$TAR_PATH" ]; then
  tar -xzf "$TAR_PATH" -C "$INSTALL_DIR"
  chmod +x "$INSTALL_DIR/bin/serviceradar_core_elx" || true
fi

systemctl daemon-reload || true
