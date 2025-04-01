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

# buildRpms.sh - Build RPM packages for ServiceRadar
set -e

export VERSION=${VERSION:-1.0.28}
export RELEASE=${RELEASE:-1}

# Create directories if they don't exist
mkdir -p release-artifacts/${VERSION}/rpm

# Function to display usage
usage() {
    echo "Usage: $0 [component]"
    echo "Components:"
    echo "  core         - Build core service RPM"
    echo "  agent        - Build agent service RPM"
    echo "  poller       - Build poller service RPM"
    echo "  web-ui       - Build web UI RPM"
    echo "  nats         - Build NATS RPM"
    echo "  kv           - Build kv RPM"
    echo "  sync         - Build sync RPM"
    echo "  dusk-checker - Build dusk checker RPM"
    echo "  snmp-poller  - Build SNMP Poller RPM"
    echo "  rperf        - Build rperf (server) RPM"
    echo "  rperf-checker- Build rperf checker RPM"
    echo "  all          - Build all components"
    exit 1
}

# Function to build core component
build_core() {
    echo "Building core component..."
    docker build \
        --platform linux/amd64 \
        --build-arg VERSION="${VERSION}" \
        --build-arg RELEASE="${RELEASE}" \
        -f Dockerfile.rpm.core \
        -t serviceradar-rpm-core \
        .

    # Extract RPM from the container
    tmp_dir=$(mktemp -d)
    container_id=$(docker create serviceradar-rpm-core)
    docker cp $container_id:/rpms/. "$tmp_dir/"
    docker rm $container_id

    # Move RPM to release directory
    find "$tmp_dir" -name "*.rpm" -exec cp {} release-artifacts/${VERSION}/rpm/ \;
    rm -rf "$tmp_dir"
}

# Function to build other components
build_component() {
    local component=$1
    local binary_path=""
    local dockerfile=""

    case $component in
        agent)
            binary_path="./cmd/agent"
            dockerfile="Dockerfile.rpm.simple"
            ;;
        poller)
            binary_path="./cmd/poller"
            dockerfile="Dockerfile.rpm.simple"
            ;;
        web-ui)
            binary_path="./cmd/web-ui"
            dockerfile="Dockerfile.rpm.web"
            ;;
        nats)
            dockerfile="Dockerfile.rpm.nats"
            ;;
        kv)
            dockerfile="Dockerfile.rpm.simple"
            ;;
        sync)
            dockerfile="Dockerfile.rpm.simple"
            ;;
        rperf)
            dockerfile="Dockerfile.rpm.rust"
            ;;
        rperf-checker)
            dockerfile="Dockerfile.rpm.rust"
            ;;
        dusk-checker)
            binary_path="./cmd/checkers/dusk"
            dockerfile="Dockerfile.rpm.simple"
            ;;
        snmp-poller)
            binary_path="./cmd/checkers/snmp"
            dockerfile="Dockerfile.rpm.simple"
            ;;
        *)
            echo "Unknown component: $component"
            usage
            ;;
    esac

    echo "Building ${component}..."
    docker build \
        --platform linux/amd64 \
        --build-arg VERSION="${VERSION}" \
        --build-arg RELEASE="${RELEASE}" \
        ${binary_path:+--build-arg BINARY_PATH="${binary_path}"} \
        ${component:+--build-arg COMPONENT="${component}"} \
        -f "$dockerfile" \
        -t "serviceradar-rpm-${component}" \
        .

    # Extract RPM from the container
    tmp_dir=$(mktemp -d)
    container_id=$(docker create "serviceradar-rpm-${component}")
    docker cp $container_id:/rpms/. "$tmp_dir/"
    docker rm $container_id

    # Move RPM to release directory
    find "$tmp_dir" -name "*.rpm" -exec cp {} release-artifacts/${VERSION}/rpm/ \;
    rm -rf "$tmp_dir"

    echo "RPM for ${component} has been built and saved to release-artifacts/${VERSION}/rpm/"
}

# Check command line arguments
if [ $# -eq 0 ]; then
    usage
fi

# Process build request
case $1 in
    core)
        build_core
        ;;
    agent|poller|dusk-checker|nats|kv|sync|rperf|rperf-checker|web-ui)
        build_component "$1"
        ;;
    all)
        build_core
        build_component "agent"
        build_component "poller"
        build_component "nats"
        build_component "kv"
        build_component "sync"
        build_component "dusk-checker"
        build_component "snmp-poller"
        build_component "web-ui"
        ;;
    *)
        echo "Unknown component: $1"
        usage
        ;;
esac

echo "Build completed. RPMs are in release-artifacts/${VERSION}/rpm/"