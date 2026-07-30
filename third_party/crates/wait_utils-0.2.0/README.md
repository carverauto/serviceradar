# Wait Utils

A Rust utility crate providing flexible waiting strategies for services and containers. This crate helps you implement reliable service health checks and startup conditions in your applications.

## Features

- **Readiness Probes**: Wait on your own operation succeeding, not on a proxy for it
- **HTTP Health Checks**: Wait for HTTP services to become available
- **gRPC Health Checks**: Wait for gRPC services to become ready
- **Console Output Monitoring**: Wait for specific output in container logs
- **Timeout Controls**: Simple timeout-based waiting with customizable durations

## Usage

Add this to your `Cargo.toml`:

```toml
[dependencies]
wait_utils = "0.1"
```

### Examples

#### HTTP Health Check

```rust
use wait_utils::wait_until_http_health_check;

let health_url = "http://localhost:8080/health";
let timeout_secs = 30;

match wait_until_http_health_check(true, health_url, &timeout_secs) {
    Ok(_) => println!("Service is healthy!"),
    Err(e) => eprintln!("Health check failed: {}", e),
}
```

#### gRPC Health Check

```rust
use wait_utils::wait_until_grpc_health_check;

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
use wait_utils::wait_until_console_output;

let container_id = "your_container_id";
let expected_output = "Server started successfully";
let timeout_secs = 60;

match wait_until_console_output(true, container_id, expected_output, &timeout_secs) {
    Ok(_) => println!("Found expected output!"),
    Err(e) => eprintln!("Failed to find expected output: {}", e),
}
```

#### Readiness Probe

Every other strategy is a fixed predicate this crate implements. None of them can express "the
operation I am about to perform succeeds", which is the only predicate that is never wrong: a
service commonly accepts connections seconds before it accepts real work.

```rust
use std::time::Duration;
use wait_utils::{Probe, wait_until_ready};

let mut attempts = 0;
let ready = wait_until_ready(true, Duration::from_secs(60), Duration::from_millis(250), || {
    attempts += 1;
    match do_the_real_thing() {
        Ok(value) => Probe::Ready(value),
        Err(e) if is_transient(&e) => Probe::Retry(format!("{e}")),
        Err(e) => Probe::Fatal(format!("{e}")),
    }
});
```

The outcome is three-way rather than a `Result`, because "not yet" and "never" need different
handling. Retrying a permanent failure burns the whole budget and then reports a timeout, which
describes the symptom and hides the cause. `Probe::Fatal` stops at once.

Consecutive identical retry messages are collapsed in the debug log, so the one line that
differs is not buried under a hundred that do not.

#### As a wait strategy

`WaitStrategy::WaitUntilReady` carries a probe, so a driver can run it for you:

```rust
use wait_utils::{Probe, ProbeContext, WaitStrategy};

fn service_is_ready(ctx: &ProbeContext) -> Probe<(), String> {
    match TcpStream::connect((ctx.host(), ctx.port())) {
        Ok(_) => Probe::Ready(()),
        Err(e) => Probe::Retry(format!("attempt {}: {e}", ctx.attempt())),
    }
}

let strategy = WaitStrategy::WaitUntilReady {
    probe: service_is_ready,
    timeout_secs: 60,
    retry_delay_ms: 250,
};
```

The probe is a plain `fn` pointer rather than a boxed closure, so `WaitStrategy` keeps `Debug`,
`Clone`, `Eq`, `Ord` and `Hash`, and so does every config that holds one. It therefore cannot
capture state: the address it needs arrives in the [`ProbeContext`], along with the attempt
number, which lets a probe escalate to `Probe::Fatal` after N tries without holding state.

The probe is synchronous by contract, and each driver guarantees it runs with no ambient async
runtime, so a probe may build one of its own.

## Which driver honours which strategy

`WaitStrategy` is a shared vocabulary with two drivers. `docker_utils` applies it synchronously
to containers, `service_utils` applies it asynchronously to locally started binaries. Not every
variant can be honoured by both, and a driver that cannot honour one reports it rather than
waiting:

| Variant | docker_utils | service_utils |
|---|---|---|
| `NoWait` | yes | yes |
| `WaitForDuration` | yes | yes |
| `WaitUntilConsoleOutputContains` | yes | no, there is no container to read logs from |
| `WaitForHttpHealthCheck` | yes | yes |
| `WaitForGrpcHealthCheck` | no, the driver is synchronous | yes |
| `WaitUntilReady` | yes | yes |

## One-shot predicates

The looping strategies above have one-shot counterparts, for drivers that want to compose the
check with something else they know, such as whether the container is still alive:

- `http_check_ok(dbg, url) -> bool`
- `console_output_contains(dbg, container_id, needle) -> bool`

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
