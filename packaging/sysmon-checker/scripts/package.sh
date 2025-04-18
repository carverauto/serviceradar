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

# package.sh for serviceradar-sysmon-checker (client) component - Prepares files for RPM packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.30}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p sysmon-checker-build
cd sysmon-checker-build

# Create package directory structure (RPM paths)
mkdir -p usr/local/bin
mkdir -p usr/lib/systemd/system
mkdir -p etc/serviceradar/checkers

# Note: Binary is built by Dockerfile.rpm.sysmon, not here
echo "Preparing SysMon Checker package files (binary will be built by RPM process)..."

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/sysmon-checker/systemd/serviceradar-sysmon-checker.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" usr/lib/systemd/system/serviceradar-sysmon-checker.service
    echo "Copied serviceradar-sysmon-checker.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-sysmon-checker.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy sysmon.json from the filesystem
SYSMON_JSON_SRC="${PACKAGING_DIR}/sysmon-checker/config/checkers/sysmon.json.example"
if [ -f "$SYSMON_JSON_SRC" ]; then
    cp "$SYSMON_JSON_SRC" etc/serviceradar/checkers/sysmon.json.example
    echo "Copied sysmon.json from $SYSMON_JSON_SRC"
else
    echo "Error: sysmon.json not found at $SYSMON_JSON_SRC"
    exit 1
fi

echo "SysMon Checker package files prepared successfully"