#!/usr/bin/env bash
# Retained as a fail-closed compatibility entrypoint; publication credentials and
# verification belong to the GitHub workflow, not this retired launcher.
set -euo pipefail
echo "Direct publication is retired. Use: gh workflow run publish-oci.yml --repo carverauto/serviceradar --ref <reviewed-branch>" >&2
echo "For an authorized product release, use scripts/cut-release.sh and the release.yml workflow." >&2
exit 2
