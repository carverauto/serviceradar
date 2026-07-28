# Wait Utils

A Rust utility crate providing flexible waiting strategies for services and containers. This crate helps you implement reliable service health checks and startup conditions in your applications.

## Features

- **HTTP Health Checks**: Wait for HTTP services to become available
- **gRPC Health Checks**: Wait for gRPC services to become ready
- **Console Output Monitoring**: Wait for specific output in container logs
- **Timeout Controls**: Simple timeout-based waiting with customizable durations

## Usage

Add this to your `Cargo.toml`:

```toml
[dependencies]
wait_utils = "0.1.0"
```

### Examples

#### HTTP Health Check

```rust
use wait_utils::wait_strategies::wait_until_http_health_check;

let health_url = "http://localhost:8080/health";
let timeout_secs = 30;

match wait_until_http_health_check(true, health_url, &timeout_secs) {
    Ok(_) => println!("Service is healthy!"),
    Err(e) => eprintln!("Health check failed: {}", e),
}
```

#### gRPC Health Check

```rust
use wait_utils::wait_strategies::wait_until_grpc_health_check;

async fn check_grpc_health() {
    let health_url = "http://localhost:50051";
    let timeout_secs = 30;

    match wait_until_grpc_health_check(true, health_url, &timeout_secs).await {
        Ok(_) => println!("gRPC service is healthy!"),
        Err(e) => eprintln!("gRPC health check failed: {}", e),
    }
}
```

#### Container Console Output

```rust
use wait_utils::wait_strategies::wait_until_console_output;

let container_id = "your_container_id";
let expected_output = "Server started successfully";
let timeout_secs = 60;

match wait_until_console_output(true, container_id, expected_output, &timeout_secs) {
    Ok(_) => println!("Found expected output!"),
    Err(e) => eprintln!("Failed to find expected output: {}", e),
}
```

## Error Handling

All waiting strategies return a `Result<(), WaitStrategyError>`. The `WaitStrategyError` type provides detailed error messages when waiting conditions are not met within the specified timeout.

## Contributing

Contributions are welcome! Feel free to:
- Report issues
- Submit pull requests
- Suggest new features
- Improve documentation

## Licence
This project is licensed under the [MIT license](LICENSE).

## Author
* [Marvin Hansen](https://github.com/marvin-hansen)
* Contact: https://deepcausality.com/contact/
* Github GPG key ID: 369D5A0B210D39BC
