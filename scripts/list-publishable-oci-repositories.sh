#!/usr/bin/env bash

set -euo pipefail

inventory_file="${1:-docker/images/image_inventory.bzl}"

if [[ ! -f "${inventory_file}" ]]; then
  echo "inventory file not found: ${inventory_file}" >&2
  exit 1
fi

rg -o '"repository": "[^"]+"' "${inventory_file}" \
  | sed -E 's/.*"repository": "([^"]+)"/\1/' \
  | sort -u
