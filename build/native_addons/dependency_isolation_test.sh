#!/usr/bin/env bash
#
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

source "$(dirname "$0")/runfile_path.sh"

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <agent_dependency_closure>" >&2
  exit 2
fi

closure_file="$(resolve_runfile "$1")"

forbidden="$(
  grep -E '^//go/pkg/addon/sdk(:|/)|^//go/cmd/serviceradar-[a-z0-9-]+-addon(:|/)' "${closure_file}" || true
)"

if [[ -n "${forbidden}" ]]; then
  echo "add-on dependency-isolation gate FAILED: base agent target depends on add-on implementation labels:" >&2
  sed 's/^/  /' <<<"${forbidden}" >&2
  exit 1
fi

echo "add-on dependency-isolation gate passed"
