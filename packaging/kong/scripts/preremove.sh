#!/usr/bin/env bash
set -euo pipefail

# Stop serviceradar-kong service if systemd is present
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop serviceradar-kong || true
  systemctl disable serviceradar-kong || true
fi

if command -v dpkg >/dev/null 2>&1; then
  for pkg in kong kong-enterprise-edition; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "Removing $pkg (dpkg -r)..."
      dpkg -r "$pkg" || true
    fi
  done
elif command -v rpm >/dev/null 2>&1; then
  for pkg in kong kong-enterprise-edition; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      echo "Removing $pkg (rpm -e)..."
      rpm -e "$pkg" || true
    fi
  done
fi

exit 0
