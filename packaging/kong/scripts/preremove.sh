#!/usr/bin/env bash
set -euo pipefail

if command -v dpkg >/dev/null 2>&1; then
  if dpkg -s kong-enterprise-edition >/dev/null 2>&1; then
    echo "Removing kong-enterprise-edition (dpkg -r)..."
    dpkg -r kong-enterprise-edition || true
  fi
elif command -v rpm >/dev/null 2>&1; then
  if rpm -q kong-enterprise-edition >/dev/null 2>&1; then
    echo "Removing kong-enterprise-edition (rpm -e)..."
    rpm -e kong-enterprise-edition || true
  fi
fi

exit 0

