#!/usr/bin/env bash
#
# Ensures first-party native add-on inventory stays wired into the release
# guardrails. This catches the failure mode where a new add-on bundle is added
# to ADDON_BUNDLES but the version-bump guard or manifest validation silently
# omits it.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <addon_inventory.bzl> <check-native-addon-version-bumps.sh> <BUILD.bazel>" >&2
  exit 2
fi

inventory="$1"
version_guard="$2"
build_file="$3"

python3 - "${inventory}" "${version_guard}" "${build_file}" <<'PY'
import re
import sys
from pathlib import Path

inventory_path, guard_path, build_path = map(Path, sys.argv[1:4])
inventory = inventory_path.read_text(encoding="utf-8")
guard = guard_path.read_text(encoding="utf-8")
build = build_path.read_text(encoding="utf-8")

inventory_ids = re.findall(r'"addon_id":\s*"([^"]+)"', inventory)
if not inventory_ids:
    raise SystemExit("error: no addon_id entries found in native add-on inventory")

dupes = sorted({addon for addon in inventory_ids if inventory_ids.count(addon) > 1})
if dupes:
    raise SystemExit(f"error: duplicate addon_id entries in inventory: {', '.join(dupes)}")

match = re.search(r"addon_ids\(\).*?cat <<'EOF'\n(?P<body>.*?)\nEOF", guard, re.S)
if not match:
    raise SystemExit("error: unable to find addon_ids() block in version bump guard")

guard_ids = [line.strip() for line in match.group("body").splitlines() if line.strip()]
missing_guard = sorted(set(inventory_ids) - set(guard_ids))
extra_guard = sorted(set(guard_ids) - set(inventory_ids))

errors = []
if missing_guard:
    errors.append(
        "version bump guard is missing native add-on(s): " + ", ".join(missing_guard)
    )
if extra_guard:
    errors.append(
        "version bump guard references unknown native add-on(s): " + ", ".join(extra_guard)
    )

manifest_labels = sorted(
    set(re.findall(r'\("addon\.yaml",\s*"([^"]+)"\)', inventory))
)
if not manifest_labels:
    errors.append("no addon.yaml manifest_entries found in inventory")

for label in manifest_labels:
    if f'"{label}"' not in build:
        errors.append(f"validate_addon_manifests_test does not include {label}")

if errors:
    raise SystemExit("error: native add-on inventory consistency failed:\n  - " + "\n  - ".join(errors))

print(
    "native add-on inventory consistency passed for "
    + ", ".join(sorted(inventory_ids))
)
PY
