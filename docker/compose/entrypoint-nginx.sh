#!/bin/sh
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

set -e

echo "[Nginx Init] Waiting for upstream services to be ready..."

# Wait for web service
if wait-for-port --host web --port 3000 --attempts 30 --interval 2s --quiet; then
    echo "[Nginx Init] Web service is ready on port 3000"
else
    echo "[Nginx Init] ERROR: Timed out waiting for web service on port 3000" >&2
    exit 1
fi

# Wait for core service
if wait-for-port --host core --port 8090 --attempts 30 --interval 2s --quiet; then
    echo "[Nginx Init] Core service is ready on port 8090"
else
    echo "[Nginx Init] ERROR: Timed out waiting for core service on port 8090" >&2
    exit 1
fi

echo "[Nginx Init] All upstream services are ready!"
