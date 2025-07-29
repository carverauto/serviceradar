#!/bin/bash
set -e

# ServiceRadar eBPF Profiler Docker Build Script
# Usage: ./build-docker.sh [dev|prod|standalone]

cd /Users/mfreeman/src/serviceradar

DOCKER_TARGET=${1:-prod}

echo "Building ServiceRadar eBPF Profiler for ${DOCKER_TARGET}..."

case "$DOCKER_TARGET" in
  "dev")
    echo "Building development image with debugging tools..."
    docker build -f cmd/ebpf/profiler/Dockerfile -t serviceradar-profiler:dev .
    echo "Run with: docker run --privileged --pid=host --network=host -it serviceradar-profiler:dev"
    ;;
  "prod")
    echo "Building production image..."
    docker build -f cmd/ebpf/profiler/Dockerfile -t serviceradar-profiler:latest .
    echo "Run with: docker run --privileged --pid=host --network=host -p 8080:8080 serviceradar-profiler:latest"
    ;;
  "standalone")
    echo "Building for standalone testing..."
    docker build -f cmd/ebpf/profiler/Dockerfile -t serviceradar-profiler:standalone .
    echo "Test with: docker run --privileged --pid=host -v /tmp:/tmp serviceradar-profiler:standalone /usr/local/bin/serviceradar-profiler --pid 1 --tui"
    ;;
  *)
    echo "Usage: $0 [dev|prod|standalone]"
    exit 1
    ;;
esac

echo "Docker build completed successfully!"
echo ""
echo "Available commands:"
echo "  Server mode:     docker run --privileged --pid=host --network=host -p 8080:8080 serviceradar-profiler:latest"
echo "  Standalone TUI:  docker run --privileged --pid=host -it serviceradar-profiler:latest /usr/local/bin/serviceradar-profiler --pid 1 --tui"
echo "  Standalone file: docker run --privileged --pid=host -v /tmp:/tmp serviceradar-profiler:latest /usr/local/bin/serviceradar-profiler --pid 1 --file /tmp/profile.pprof"
echo ""
echo "Note: --privileged and --pid=host are required for eBPF functionality"