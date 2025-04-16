#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
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

# setup-installer.sh - Build serviceradar-cli Debian package
set -e  # Exit on any error

# Ensure we're in the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
echo "Working directory: $(pwd)"

VERSION=${VERSION:-1.0.31}
VERSION=$(echo "$VERSION" | sed 's/refs\/tags\/v//')  # Clean Git ref if present

echo "Copying installer script for ${VERSION}"

# Use a relative path from the script's location
BASE_DIR="$(pwd)"
SCRIPTS_DIR="${BASE_DIR}/scripts"

echo "Using SCRIPTS_DIR: $SCRIPTS_DIR"

# Move the deb file to the release-artifacts directory
mv "${SCRIPTS_DIR}/install-serviceradar.sh" "${BASE_DIR}/release-artifacts/"

echo "Installer script copied to release-artifacts directory."