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

# package.sh for serviceradar-otel collector - Prepares files for RPM packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.30}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p otel
cd otel

# Create package directory structure (RPM paths)
mkdir -p usr/local/bin
mkdir -p usr/lib/systemd/system

# Note: Binary is built by Dockerfile.rpm.otel, not here
echo "Preparing OTEL collector package files (binary will be built by RPM process)..."

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/otel/systemd/serviceradar-otel.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" usr/lib/systemd/system/serviceradar-otel.service
    echo "Copied serviceradar-otel.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-otel.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy otel.toml from the filesystem
OTEL_CONF_SRC="${PACKAGING_DIR}/otel.toml"
if [ -f "$OTEL_CONF_SRC" ]; then
    cp "$OTEL_CONF_SRC" etc/serviceradar/otel.toml
    echo "Copied otel.toml from $OTEL_CONF_SRC"
else
    echo "Error: otel.toml not found at $OTEL_CONF_SRC"
    exit 1
fi

echo "OTEL collector package files prepared successfully"