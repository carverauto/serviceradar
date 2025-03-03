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

# buildCore.sh - Build the core package for ServiceRadar
set -e

export VERSION=${VERSION}

# Build the builder image
docker build -t serviceradar-builder -f ./Dockerfile.build .

# Run just the core package build in the container
docker run --rm -v $(pwd):/build serviceradar-builder ./scripts/setup-deb-core.sh

echo "Build completed. Check release-artifacts/ directory for the core package."