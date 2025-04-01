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

# package.sh for serviceradar-rperf-checker (client) component - Prepares files for RPM packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.28}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p rperf-checker-build
cd rperf-checker-build

# Create package directory structure (RPM paths)
mkdir -p usr/local/bin
mkdir -p usr/lib/systemd/system
mkdir -p etc/serviceradar/checkers

# Note: Binary is built by Dockerfile.rpm.rperf, not here
echo "Preparing RPerf Checker package files (binary will be built by RPM process)..."

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/rperf-checker/systemd/serviceradar-rperf-checker.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" usr/lib/systemd/system/serviceradar-rperf-checker.service
    echo "Copied serviceradar-rperf-checker.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-rperf-checker.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy rperf.json from the filesystem
RPERF_JSON_SRC="${PACKAGING_DIR}/rperf-checker/config/checkers/rperf.json"
if [ -f "$RPERF_JSON_SRC" ]; then
    cp "$RPERF_JSON_SRC" etc/serviceradar/checkers/rperf.json
    echo "Copied rperf.json from $RPERF_JSON_SRC"
else
    echo "Error: rperf.json not found at $RPERF_JSON_SRC"
    exit 1
fi

# Optional: Copy api.env if needed (not referenced in service file, but included for consistency)
API_ENV_SRC="${PACKAGING_DIR}/core/config/api.env"
if [ -f "$API_ENV_SRC" ]; then
    mkdir -p etc/serviceradar
    cp "$API_ENV_SRC" etc/serviceradar/api.env
    echo "Copied api.env from $API_ENV_SRC"
else
    echo "Error: api.env not found at $API_ENV_SRC"
    exit 1
fi

echo "RPerf Checker package files prepared successfully"