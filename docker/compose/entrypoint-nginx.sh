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
for i in $(seq 1 30); do
    if nc -z web 3000 2>/dev/null; then
        echo "[Nginx Init] Web service is ready on port 3000"
        break
    fi
    echo "[Nginx Init] Waiting for web service... ($i/30)"
    sleep 2
done

# Wait for core service
for i in $(seq 1 30); do
    if nc -z core 8090 2>/dev/null; then
        echo "[Nginx Init] Core service is ready on port 8090"
        break
    fi
    echo "[Nginx Init] Waiting for core service... ($i/30)"
    sleep 2
done

echo "[Nginx Init] All upstream services are ready!"