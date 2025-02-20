#!/bin/bash
set -e

export VERSION=${VERSION:-1.0.18}
export RELEASE=${RELEASE:-1}

# Create directories if they don't exist
mkdir -p release-artifacts/${VERSION}/rpm

# Function to display usage
usage() {
    echo "Usage: $0 [component]"
    echo "Components:"
    echo "  cloud        - Build cloud service RPM"
    echo "  agent        - Build agent service RPM"
    echo "  poller       - Build poller service RPM"
    echo "  dusk-checker - Build dusk checker RPM"
    echo "  all          - Build all components"
    exit 1
}

# Function to build cloud component (uses full Dockerfile)
build_cloud() {
    echo "Building cloud component..."
    docker build \
        --platform linux/amd64 \
        --build-arg VERSION="${VERSION}" \
        --build-arg RELEASE="${RELEASE}" \
        -f Dockerfile-rpm.cloud \
        -t serviceradar-rpm-cloud \
        .

    # Extract RPM from the container
    tmp_dir=$(mktemp -d)
    container_id=$(docker create serviceradar-rpm-cloud)
    docker cp $container_id:/rpms/. "$tmp_dir/"
    docker rm $container_id

    # Move RPM to release directory
    find "$tmp_dir" -name "*.rpm" -exec cp {} release-artifacts/${VERSION}/rpm/ \;
    rm -rf "$tmp_dir"
}

# Function to build other components using simple Dockerfile
build_component() {
    local component=$1
    local binary_path=""

    case $component in
        agent)
            binary_path="./cmd/agent"
            ;;
        poller)
            binary_path="./cmd/poller"
            ;;
        dusk-checker)
            binary_path="./cmd/checkers/dusk"
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
        --build-arg COMPONENT="${component}" \
        --build-arg BINARY_PATH="${binary_path}" \
        -f Dockerfile.rpm.simple \
        -t "serviceradar-rpm-${component}" \
        .

    # Extract RPM from the container
    tmp_dir=$(mktemp -d)
    docker create --name temp-container "serviceradar-rpm-${component}"
    docker cp temp-container:/rpms/. "$tmp_dir/"
    docker rm temp-container

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
    cloud)
        build_cloud
        ;;
    agent|poller|dusk-checker)
        build_component "$1"
        ;;
    all)
        build_cloud
        build_component "agent"
        build_component "poller"
        build_component "dusk-checker"
        ;;
    *)
        echo "Unknown component: $1"
        usage
        ;;
esac

echo "Build completed. RPMs are in release-artifacts/${VERSION}/rpm/"