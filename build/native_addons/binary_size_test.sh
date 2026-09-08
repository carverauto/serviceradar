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

if [[ "$#" -lt 3 ]]; then
  echo "usage: $0 <check-addon-binary-size.sh> <baseline.json> <binary> [<binary> ...]" >&2
  exit 2
fi

checker="$(resolve_runfile "$1")"
baseline="$(resolve_runfile "$2")"
shift 2

artifacts=()
for artifact_arg in "$@"; do
  # $(locations ...) expands to a space-delimited list. Native add-on artifact
  # paths are Bazel-generated and do not contain spaces.
  for artifact in ${artifact_arg}; do
    artifacts+=("$(resolve_runfile "${artifact}")")
  done
done

BASELINE_FILE="${baseline}" REQUIRE_GSA="${REQUIRE_GSA:-0}" "${checker}" "${artifacts[@]}"
