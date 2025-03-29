# rperf-grpc

A gRPC service for performing network throughput testing with rperf.

## Overview

This service provides a gRPC interface for running rperf network performance tests. It can be used as a plugin for the ServiceRadar monitoring system, allowing for scheduled performance tests and alerts.

The service:
- Exposes a gRPC API for running and managing tests
- Periodically runs tests against configured targets
- Tracks test results and provides status information
- Integrates with the ServiceRadar agent system

## Prerequisites

- Rust 1.56 or later (for building from source)
- [rperf](https://crates.io/crates/rperf) 0.1.17 or later (installed on the system)
- Protocol Buffers compiler (for building from source)

## Configuration

Create a JSON configuration file with the following structure:

```json
{
  "listen_addr": "0.0.0.0:50051",
  "security": {
    "tls_enabled": false,
    "cert_file": null,
    "key_file": null
  },
  "default_poll_interval": 300,
  "targets": [
    {
      "name": "Example TCP Test",
      "address": "example.com",
      "port": 5199,
      "protocol": "tcp",
      "reverse": false,
      "bandwidth": 1000000,
      "duration": 10.0,
      "parallel": 1,
      "length": 0,
      "omit": 1,
      "no_delay": true,
      "send_buffer": 0,
      "receive_buffer": 0,
      "send_interval": 0.05,
      "poll_interval": 300
    }
  ]
}
```

### Configuration Options

| Option | Description |
|--------|-------------|
| `listen_addr` | The address and port for the gRPC server to listen on |
| `security` | TLS configuration (optional) |
| `default_poll_interval` | Default interval (in seconds) between tests |
| `targets` | Array of target configurations for periodic testing |

#### Target Configuration

| Option | Description |
|--------|-------------|
| `name` | Display name for the target |
| `address` | Target host address |
| `port` | Target port number |
| `protocol` | "tcp" or "udp" |
| `reverse` | Whether to run in reverse mode (server sends, client receives) |
| `bandwidth` | Target bandwidth in bytes/sec |
| `duration` | Test duration in seconds |
| `parallel` | Number of parallel streams |
| `length` | Buffer length (0 for default) |
| `omit` | Seconds to omit from the start of test |
| `no_delay` | Use TCP no-delay option |
| `send_buffer` | Socket send buffer size |
| `receive_buffer` | Socket receive buffer size |
| `send_interval` | Interval for sending data (in seconds) |
| `poll_interval` | Interval between tests for this target (in seconds) |

## Building and Running

### Building from Source

```bash
# Clone the repository
git clone https://github.com/example/rperf-grpc.git
cd rperf-grpc

# Build the project
cargo build --release

# Run with a configuration file
./target/release/rperf-grpc --config config.json
```

### Using Docker

```bash
# Build the Docker image
docker build -t rperf-grpc .

# Run the container
docker run -p 50051:50051 -v /path/to/config.json:/etc/rperf-grpc/config.json rperf-grpc
```

## Integration with ServiceRadar

To use this with the ServiceRadar monitoring system:

1. Deploy the rperf-grpc service on your target hosts
2. Configure the ServiceRadar agent to connect to the rperf-grpc service
3. (Optional) Set up alerts for network performance degradation

## Securing the rperf Server

`rperf` is designed to run as a continuously available server, listening on a specified port (default: 5199). To secure it, we strongly recommend restricting access using a firewall. Below are examples for common tools:

### Using `iptables`
Allow only specific client IPs:

```bash
sudo iptables -A INPUT -p tcp --dport 5199 -s <trusted-client-ip> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 5199 -j DROP
```

### Using `ufw`
Allow only specific client IPs:

```bash
sudo ufw allow from <trusted-client-ip> to any port 5199
sudo ufw deny 5199
```

### Using `firewalld`
Allow only specific client IPs:

```bash
sudo firewall-cmd --zone=trusted --add-source=<trusted-client-ip> --permanent 
sudo firewall-cmd --zone=trusted --add-port=5199/tcp --permanent
sudo firewall-cmd --reload
```

## API Reference

### RPerfService

```protobuf
service RPerfService {
  // RunTest starts a network test and returns results
  rpc RunTest(TestRequest) returns (TestResponse) {}
  
  // GetStatus returns the current status of the service
  rpc GetStatus(StatusRequest) returns (StatusResponse) {}
}
```

See the `proto/rperf.proto` file for the complete API definition.

## License

Apache License 2.0