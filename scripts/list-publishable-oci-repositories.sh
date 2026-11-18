#!/usr/bin/env bash

set -euo pipefail

inventory_file="${1:-docker/images/image_inventory.bzl}"

if [[ ! -f "${inventory_file}" ]]; then
  echo "inventory file not found: ${inventory_file}" >&2
  exit 1
fi

python3 - "${inventory_file}" <<'PY' | sort -u
import ast
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
match = re.search(r"PUBLISHABLE_IMAGES\s*=\s*(\[[\s\S]*?\])\n\n", path.read_text())
if not match:
    raise SystemExit(f"unable to parse image inventory: {path}")
for entry in ast.literal_eval(match.group(1)):
    print(entry["repository"])
PY
