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

# buildAll.sh - Build all packages for ServiceRadar
VERSION=${VERSION:-1.0.23}

./scripts/setup-deb-agent.sh
./scripts/setup-deb-poller.sh
./scripts/setup-deb-web.sh
./scripts/setup-deb-dusk-checker.sh
./scripts/setup-deb-snmp-checker.sh

scp ./release-artifacts/serviceradar-poller_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-agent_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-dusk-checker_${VERSION}.deb duskadmin@192.168.2.22:~/
scp ./release-artifacts/serviceradar-snmp-checker_${VERSION}.deb duskadmin@192.168.2.22:~/
