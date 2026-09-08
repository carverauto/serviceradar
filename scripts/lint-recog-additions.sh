#!/usr/bin/env bash
# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDITIONS_FILE="${REPO_ROOT}/third_party/netprobe_corpora/recog/serviceradar-recog-additions.xml"

cd "${REPO_ROOT}"

if ! grep -Eq 'License: CC0-1\.0' "${ADDITIONS_FILE}"; then
  echo "missing CC0-1.0 license header in ${ADDITIONS_FILE}" >&2
  exit 1
fi

python3 - "${ADDITIONS_FILE}" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
allowed_services = {
    "http_server",
    "ssh_banner",
    "smb_version",
    "ftp_banner",
    "smtp_banner",
    "telnet_banner",
    "snmp_banner",
    "sip_banner",
    "rdp_banner",
    "dns_version",
}

try:
    root = ET.parse(path).getroot()
except ET.ParseError as exc:
    raise SystemExit(f"{path}: invalid XML: {exc}") from exc

if root.tag != "fingerprints":
    raise SystemExit(f"{path}: root element must be <fingerprints>")

for fingerprint in root.findall("fingerprint"):
    service = fingerprint.attrib.get("service")
    if service not in allowed_services:
        raise SystemExit(f"{path}: fingerprint has unknown service {service!r}")
    if not fingerprint.attrib.get("pattern"):
        raise SystemExit(f"{path}: fingerprint for {service} is missing pattern")
    for param in fingerprint.findall("param"):
        if not param.attrib.get("name"):
            raise SystemExit(f"{path}: param in {service} fingerprint is missing name")
        if "pos" in param.attrib:
            try:
                int(param.attrib["pos"])
            except ValueError as exc:
                raise SystemExit(
                    f"{path}: param {param.attrib.get('name')!r} has non-integer pos"
                ) from exc
PY

if command -v sfw >/dev/null 2>&1; then
  exec sfw cargo test -p serviceradar-netprobe --no-default-features --offline \
    recog::tests::matches_http_server_banner
fi

exec cargo test -p serviceradar-netprobe --no-default-features --offline \
  recog::tests::matches_http_server_banner
