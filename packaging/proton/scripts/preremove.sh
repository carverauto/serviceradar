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

# Pre-removal script for ServiceRadar Proton Server
set -e

# Stop and disable the service
if systemctl is-active --quiet serviceradar-proton; then
    echo "Stopping serviceradar-proton service..."
    systemctl stop serviceradar-proton
fi

if systemctl is-enabled --quiet serviceradar-proton; then
    echo "Disabling serviceradar-proton service..."
    systemctl disable serviceradar-proton
fi

echo "Pre-removal cleanup completed."