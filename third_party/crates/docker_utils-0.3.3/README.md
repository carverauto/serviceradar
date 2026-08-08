[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue

[crates-url]: https://crates.io/crates/docker_utils

[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue

[docs-url]: https://docs.rs/docker_utils/latest/docker_utils/

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

# 🐳 Docker Utils

A friendly Rust crate that simplifies Docker container management with a clean and intuitive API.

## Why?

Docker is a powerful tool to manage and deploy containers. During continuous integration (CI),
you may have to start containers, stop containers, or check the status of containers and all of that programmatically. 
Conventionally, you can either rely on GitHub actions or you can use the wonderful [Testcontainers library](https://testcontainers.com/). 

 
However, when you build your Rust project with Bazel, you cannot use GitHub actions and when accelerating your 
build with Bazel's Remote Build Execution, you cannot always use Testcontainers.


With Docker Utils, you can easily manage your containers with a clean and intuitive API for all your Bazel CI test and any
other situation where you have to work with disposable containers. Docker Utils gives you the fun without the fuzz. 

## Features

- 🐳 **Easy Docker API**
  - Only uses the standard library thus easy to cross compile. 
  - Only uses the robust Docker CLI.
  - Tested and documented [public API](src/api.rs).

- 🚀 **Container Lifecycle Management**
  - Start and stop containers with ease.
  - Check container status.
  - Pull container images.
  - Prune unused containers.
  - Collect a post-mortem when a container dies.

- ⚙️ **Flexible Configuration**
  - Environment variable support.
  - Platform-specific configurations.
  - Published ports or host networking.
  - Container reuse options.
  - Easy builder pattern support.


## Install 🚀

Add this to your `Cargo.toml`:

```toml
[dependencies]
docker_utils = "0.3"
```

## Quick Start

```rust
use docker_utils::*;

// Create a new Docker utility instance
let docker_util = DockerUtil::new().expect("Failed to create DockerUtil");

// Configure your container using the provided sample configuration for postgres
let container_config = postgres_config::postgres_db_container_config();

// Start the container or get it if it already running. Returns (container_name, port)
let (container_name, port) = docker_util
    .setup_container(&container_config)
    .expect("Failed to start container");

// Stop the container when done. The second argument deletes it after stopping.
docker_util.stop_container(&container_name, true)
    .expect("Failed to stop container");
```

## Container Configuration

Creating a new configuration using the builder pattern:

```rust
use docker_utils::*;
 
    let config = ContainerConfig::builder()
        .name("test_container")
        .image("test_image")
        .tag("latest")
        .url("0.0.0.0")
        .connection_port(8080)
        .reuse_container(true)
        .keep_configuration(true)
        .wait_strategy(WaitStrategy::NoWait)
        .build();
```  

Setting optional fields (opening additional ports, environment variables, or platform) using the builder:

```rust
use docker_utils::*;
 
    let config = ContainerConfig::builder()
        .name("test_container")
        .image("test_image")
        .tag("latest")
        .url("0.0.0.0")
        .connection_port(8080)
        .additional_ports(&[8081, 8082])
        .additional_env_vars( &["ENV_VAR=VALUE", "DEBUG=true"])
        .platform("linux/amd64")
        .reuse_container(true)
        .keep_configuration(true)
        .wait_strategy(WaitStrategy::NoWait)
        .build();
```  

Creating a new configuration using the conventional constructor:

```rust
use docker_utils::*;
 
    let config =  ContainerConfig::new(
        "test_container",
        "test_image",
        "latest",
        "0.0.0.0",
        8080,
        Some(&[8081, 8082]),
        Some(&["ENV_VAR=VALUE", "DEBUG=true"]),
        Some("linux/amd64"),
        false, // host_network: publish ports rather than share the host's network
        true,
        false,
        WaitStrategy::default(), // NoWait is the default wait strategy
    );
```  

## Host Networking 🌐

By default the container publishes its ports, mapping `connection_port` and any
`additional_ports` onto the host. Set `host_network` to run the container in Docker's host
network mode instead, where it shares the host's network namespace and binds the host's ports
directly:

```rust
use docker_utils::*;

    let config = ContainerConfig::builder()
        .name("test_container")
        .image("test_image")
        .tag("latest")
        .url("0.0.0.0")
        .connection_port(8080)
        .host_network(true)
        .reuse_container(true)
        .keep_configuration(true)
        .wait_strategy(WaitStrategy::NoWait)
        .build();
```  

In host network mode no port is published, because Docker discards published ports in that
mode and warns about it. Ports are still validated, so a zero port is still reported as a
configuration error.

`host_network` is optional in the builder and defaults to `false`, so existing configurations
keep publishing ports exactly as before. The `ContainerConfig::new` constructor takes it as an
explicit argument, positioned after `platform`.

Note that host networking is a Linux feature. Docker Desktop runs containers inside a VM,
where host network mode does not expose the container on the macOS or Windows host.

## Wait Strategies 🕒

The crate provides several wait strategies through the `wait_utils` dependency:

- `NoWait`: Return as soon as the container is started.
- `WaitForDuration(u64)`: Wait for a specified number of seconds
- `WaitUntilConsoleOutputContains(String, u64)`: Wait for a specified console output or until a timeout occurs.
- `WaitForHttpHealthCheck(String, u64)`: Wait until an HTTP request to the given URL or until a timeout occurs.
- `WaitUntilReady { probe, timeout_secs, retry_delay_ms }`: Wait until your own probe reports ready.

`WaitForGrpcHealthCheck` is not honoured here: it needs an async driver. Use `service_utils`,
or express the check as `WaitUntilReady`. It is reported as unsupported rather than silently
waiting.

Whatever the strategy, the container is checked for liveness between attempts. A container that
dies mid-wait aborts the wait immediately, instead of running out the clock and reporting a
timeout that describes the symptom rather than the cause.

### Readiness probes

Every other strategy is a fixed predicate this crate implements. None of them can express "the
operation I am about to perform succeeds", which is the only predicate that is never wrong: a
database commonly accepts connections seconds before it accepts a schema change.

```rust
use docker_utils::{Probe, ProbeContext, WaitStrategy};

fn container_is_ready(ctx: &ProbeContext) -> Probe<(), String> {
    match TcpStream::connect((ctx.host(), ctx.port())) {
        Ok(_) => Probe::Ready(()),
        Err(e) => Probe::Retry(format!("attempt {}: {e}", ctx.attempt())),
    }
}

let config = ContainerConfig::builder()
    .name("my_service")
    .image("my_image")
    .tag("latest")
    .url("127.0.0.1")
    .connection_port(8080)
    .wait_strategy(WaitStrategy::WaitUntilReady {
        probe: container_is_ready,
        timeout_secs: 60,
        retry_delay_ms: 250,
    })
    .build();
```

The host and port the probe receives are the ones declared on the config. The probe runs on a
thread of its own, so it may build its own async runtime even when `setup_container` was called
from inside `#[tokio::test]`.

## Container Diagnostics 🔎

When a container dies mid-test the only evidence is its exit state, and `docker run --rm`
deletes it seconds later. `container_diagnostics` collects the post-mortem while it still
exists:

```rust
let diagnostics = docker_util.container_diagnostics(&container_name, 200)?;

if diagnostics.looks_oom_killed() {
    eprintln!("container ran out of memory:\n{diagnostics}");
}
```

It reports the container's status, whether it is running, its restart count, its exit code and
its log tail. `looks_oom_killed` checks both the OOM flag and exit code 137, because either
alone is ambiguous.

An OOM kill presents to a client as a bare connection error, because the server never got to
write an explanation. This is what tells the two apart.

Any wait failure already carries this post-mortem, so a timeout explains itself. Call it
directly for a container that dies *after* the wait, while your test is using it.

## Error Handling

The crate uses a custom `DockerError` type for comprehensive error handling, making it easy to identify 
and handle Docker-related issues in your application.

When a Docker command fails, the returned `DockerError` carries the command's exit status and
its stderr, so the cause is reported where it happens rather than surfacing later as an
unexplained wait timeout.

Nothing in the crate terminates your process: an unreachable daemon, a failed pull and a wait
timeout are all reported as errors, so a caller can still collect diagnostics before deciding
what to do.

`stop_container(id, true)` succeeds when the container is already gone. Deleting something
absent is the requested end state, and `--rm` guarantees it after a crash, so a teardown error
would only mask the failure that produced it.

## Examples

Check out the [example directory](../../examples/docker_utils_example) for complete working examples, including:
- Postgres container setup and management
- Container lifecycle management
- Status monitoring

## Requirements

- Docker daemon running on your system
- Rust 1.90

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
