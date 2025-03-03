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

# setup-build-env.sh - Set up the build environment for serviceradar

set -e

echo "Setting up ServiceRadar build environment..."

# Check for required tools
echo "Checking for required tools..."

# Check for Go
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed or not in PATH"
    echo "Please install Go from https://golang.org/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "Found Go $GO_VERSION"

# Check for Node.js and pnpm for web UI building
if ! command -v node &> /dev/null; then
    echo "Error: Node.js is not installed or not in PATH"
    echo "Please install Node.js from https://nodejs.org/"
    exit 1
fi

NODE_VERSION=$(node -v)
echo "Found Node.js $NODE_VERSION"

if ! command -v pnpm &> /dev/null; then
    echo "Error: pnpm is not installed or not in PATH"
    echo "Please install pnpm (usually installed w/ npm)"
    exit 1
fi

PNPM_VERSION=$(pnpm -v)
echo "Found pnpm $PNPM_VERSION"

# Check for ko if building containers
if [[ "$1" == "containers" ]]; then
    if ! command -v ko &> /dev/null; then
        echo "Ko not found. Installing ko..."
        go install github.com/google/ko@latest
    else
        KO_VERSION=$(ko version)
        echo "Found ko $KO_VERSION"
    fi
fi

# Set up web dependencies
echo "Setting up web UI dependencies..."
cd web
pnpm install
cd ..

# Create necessary directories
echo "Creating necessary directories..."
mkdir -p release-artifacts
mkdir -p bin
mkdir -p pkg/cloud/api/web

# Build web UI
echo "Building web UI..."
cd web
pnpm run build
cd ..

# Copy web UI to embedded location
echo "Setting up web assets for embedding..."
cp -r web/dist pkg/cloud/api/web/

if [[ "$1" == "containers" ]]; then
    # Set up kodata directory
    echo "Setting up kodata directory for container builds..."
    mkdir -p cmd/cloud/.kodata
    cp -r web/dist cmd/cloud/.kodata/web

    echo "Build environment for containerized builds is ready!"
else
    echo "Build environment for standard builds is ready!"
fi

echo "You can now run:"
if [[ "$1" == "containers" ]]; then
    echo "  - 'make container-build' to build container images"
    echo "  - 'make container-push' to build and push container images"
    echo "  - 'make deb-cloud-container' to build the cloud Debian package with container support"
    echo "  - 'make deb-all-container' to build all Debian packages with container support"
else
    echo "  - 'make build' to build all binaries"
    echo "  - 'make deb-cloud' to build the cloud Debian package"
    echo "  - 'make deb-all' to build all Debian packages"
fi