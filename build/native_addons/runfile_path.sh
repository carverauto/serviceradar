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

resolve_runfile() {
  local path="$1"
  local candidate

  if [[ "${path}" = /* && -e "${path}" ]]; then
    printf '%s\n' "${path}"
    return 0
  fi

  for candidate in \
    "${PWD}/${path}" \
    "${TEST_SRCDIR:-}/${TEST_WORKSPACE:-}/${path}" \
    "${TEST_SRCDIR:-}/_main/${path}" \
    "${TEST_SRCDIR:-}/serviceradar/${path}"; do
    if [[ -n "${candidate}" && -e "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  echo "error: unable to resolve Bazel runfile ${path}" >&2
  return 1
}
