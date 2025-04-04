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

export VERSION=${VERSION:-1.0.28}

echo "Building core package version ${VERSION} on host..."
./scripts/setup-deb-core.sh

echo "Build completed. Check release-artifacts/ directory for the core package."