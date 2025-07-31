# ServiceRadar eBPF Profiler - Docker Setup

This document explains how to build and run the eBPF profiler using Docker on Linux systems.

## Prerequisites

- Docker with BuildKit support
- Linux kernel 4.9+ with eBPF support
- Root privileges or CAP_BPF capabilities

## Quick Start

### 1. Build the Docker Image

```bash
# From the ServiceRadar root directory
cd /Users/mfreeman/src/serviceradar
./cmd/ebpf/profiler/build-docker.sh
```

### 2. Run the Profiler

#### Server Mode (gRPC Service)
```bash
docker run --privileged --pid=host --network=host -p 8080:8080 serviceradar-profiler:latest
```

#### Standalone Mode with TUI
```bash
docker run --privileged --pid=host -it serviceradar-profiler:latest \
  /usr/local/bin/serviceradar-profiler --pid 1 --tui --duration 30
```

#### Standalone Mode with File Output
```bash
docker run --privileged --pid=host -v /tmp:/tmp serviceradar-profiler:latest \
  /usr/local/bin/serviceradar-profiler --pid 1 --file /tmp/profile.pprof --duration 30
```

## Docker Compose

### Start the gRPC Server
```bash
cd cmd/ebpf/profiler
docker-compose up serviceradar-profiler
```

### Test with Interactive TUI
```bash
cd cmd/ebpf/profiler
docker-compose run --rm profiler-test-tui
```

### Test with File Output
```bash
cd cmd/ebpf/profiler
docker-compose run --rm profiler-test-file
# Check /tmp/profiler-output/test.pprof
```

## Required Privileges

The profiler requires elevated privileges to:
- Load eBPF programs into the kernel
- Attach to perf events
- Access process information

### Privilege Options

1. **Full Privileged** (recommended for development):
   ```bash
   docker run --privileged --pid=host serviceradar-profiler:latest
   ```

2. **Specific Capabilities** (production):
   ```bash
   docker run --cap-add=SYS_ADMIN --cap-add=BPF --cap-add=PERFMON \
     --pid=host serviceradar-profiler:latest
   ```

## Configuration

### Default Configuration
The image includes a default configuration at `/etc/serviceradar/profiler/profiler.toml`:

```toml
[server]
bind_address = "0.0.0.0"
port = 8080

[profiler]
max_concurrent_sessions = 10
max_session_duration_seconds = 300
max_frequency_hz = 1000

[ebpf]
enabled = true
max_stack_depth = 32
stack_trace_buffer_size = 8192
```

### Custom Configuration
Mount your own config file:
```bash
docker run -v /path/to/profiler.toml:/etc/serviceradar/profiler/profiler.toml \
  --privileged --pid=host serviceradar-profiler:latest
```

## Usage Examples

### Profile a Specific Process
```bash
# Find the PID you want to profile on the host
ps aux | grep your-process

# Profile it for 60 seconds with TUI
docker run --privileged --pid=host -it serviceradar-profiler:latest \
  /usr/local/bin/serviceradar-profiler --pid 12345 --duration 60 --tui
```

### Generate Flame Graph Data
```bash
# Profile and save as flame graph format
docker run --privileged --pid=host -v /tmp:/tmp serviceradar-profiler:latest \
  /usr/local/bin/serviceradar-profiler --pid 12345 --duration 30 \
  --format flamegraph --file /tmp/profile.folded

# Convert to SVG (requires flamegraph.pl on host)
flamegraph.pl /tmp/profile.folded > /tmp/flamegraph.svg
```

### Test with gRPC Client
```bash
# Start the server
docker run --privileged --pid=host --network=host serviceradar-profiler:latest

# Test with grpcurl (from another terminal)
grpcurl -plaintext localhost:8080 profiler.ProfilerService/GetStatus
```

## Troubleshooting

### Common Issues

1. **Permission Denied**
   - Ensure Docker is running with sufficient privileges
   - Try adding `--privileged` flag
   - Check kernel eBPF support: `zcat /proc/config.gz | grep BPF`

2. **No Stack Traces Collected**
   - Verify the target PID exists: `docker run --pid=host alpine ps aux | grep PID`
   - Check if process is actually consuming CPU
   - Try a higher sampling frequency: `--frequency 999`

3. **Container Exits Immediately**
   - Check logs: `docker logs serviceradar-profiler`
   - Verify configuration syntax
   - Ensure required bind addresses are available

### Debug Mode
Enable detailed logging:
```bash
docker run --privileged --pid=host -e RUST_LOG=debug serviceradar-profiler:latest \
  /usr/local/bin/serviceradar-profiler --debug
```

### Interactive Shell
Access the container for debugging:
```bash
docker run --privileged --pid=host -it --entrypoint /bin/bash serviceradar-profiler:latest
```

## Building from Source

### Local Build (Linux only)
```bash
# Install dependencies
sudo apt install llvm clang libbpf-dev protobuf-compiler

# Build with eBPF support
cargo build --release --features ebpf

# Run locally
sudo ./target/release/profiler --pid 1 --tui
```

### Cross-platform Development
Use the Docker build for consistent cross-platform development:
```bash
./build-docker.sh dev
docker run --privileged --pid=host -v $(pwd):/app -it serviceradar-profiler:dev
```

## Integration with ServiceRadar

The profiler integrates with the ServiceRadar ecosystem through:

1. **gRPC API**: Compatible with existing ServiceRadar agent patterns
2. **Configuration**: Follows ServiceRadar TOML configuration standards  
3. **Logging**: Uses structured logging compatible with ServiceRadar observability
4. **Packaging**: Follows ServiceRadar Docker packaging conventions

### Agent Integration Example
```bash
# ServiceRadar Agent can trigger profiling via gRPC:
curl -X POST localhost:8080/profiler.ProfilerService/StartProfiling \
  -d '{"process_id": 12345, "duration_seconds": 30, "frequency": 99}'
```

This Docker setup provides a complete eBPF profiling solution that can be deployed standalone or integrated into the broader ServiceRadar platform.