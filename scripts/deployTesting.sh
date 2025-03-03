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

# deployTesting.sh - Deploy the testing packages for ServiceRadar

# Define the version of the packages
VERSION=${VERSION:-1.0.20}

# Define the list of remote machines
MACHINES=("192.168.2.10" "192.168.2.11" "192.168.2.12" "192.168.2.68")

# Define the list of packages to be deployed
PACKAGES=("serviceradar-agent" "serviceradar-poller")

# Loop through each machine and deploy the packages
for MACHINE in "${MACHINES[@]}"; do
    echo "Deploying to $MACHINE..."

    # SCP the packages to the remote machine
    for PACKAGE in "${PACKAGES[@]}"; do
        scp "release-artifacts/${PACKAGE}_${VERSION}.deb" root@$MACHINE:~/
    done

    # SSH into the machine and install the packages
    for PACKAGE in "${PACKAGES[@]}"; do
        ssh root@$MACHINE "dpkg -i ~/${PACKAGE}_${VERSION}.deb"
    done

    echo "Deployment to $MACHINE completed."
done

echo "All deployments completed."
