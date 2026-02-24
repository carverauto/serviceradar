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

# package.sh for serviceradar-profiler collector - Prepares files for RPM packaging
set -e

# Define package version
VERSION=${VERSION:-1.0.30}

# Use a relative path from the script's location
BASE_DIR="$(dirname "$(dirname "$0")")"  # Go up two levels from scripts/ to root
PACKAGING_DIR="${BASE_DIR}/packaging"

echo "Using PACKAGING_DIR: $PACKAGING_DIR"

# Create the build directory
mkdir -p profiler
cd profiler

# Create package directory structure (RPM paths)
mkdir -p usr/local/bin
mkdir -p usr/lib/systemd/system

# Note: Binary is built by Dockerfile.rpm.rust.profiler, not here
echo "Preparing Profiler agent package files (binary will be built by RPM process)..."

# Copy systemd service file from the filesystem
SERVICE_FILE_SRC="${PACKAGING_DIR}/profiler/systemd/serviceradar-profiler.service"
if [ -f "$SERVICE_FILE_SRC" ]; then
    cp "$SERVICE_FILE_SRC" usr/lib/systemd/system/serviceradar-profiler.service
    echo "Copied serviceradar-profiler.service from $SERVICE_FILE_SRC"
else
    echo "Error: serviceradar-profiler.service not found at $SERVICE_FILE_SRC"
    exit 1
fi

# Copy profiler.toml from the filesystem
PROFILER_CONF_SRC="${PACKAGING_DIR}/profiler.toml"
if [ -f "$PROFILER_CONF_SRC" ]; then
    cp "$PROFILER_CONF_SRC" etc/serviceradar/profiler.toml
    echo "Copied profiler.toml from $PROFILER_CONF_SRC"
else
    echo "Error: profiler.toml not found at $PROFILER_CONF_SRC"
    exit 1
fi

echo "Profiler agent package files prepared successfully"