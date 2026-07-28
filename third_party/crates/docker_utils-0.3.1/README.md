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
docker_utils = "0.2"
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

- `WaitForDuration(u64)`: Wait for a specified number of seconds
- `WaitUntilConsoleOutputContains(String, u64)`: Wait for a specified console output or until a timeout occurs.
- `WaitForHttpHealthCheck(String, u64)`: Wait until an HTTP request to the given URL or until a timeout occurs.
- `WaitForGrpcHealthCheck(u16, u64)`: Wait until an gRPC health request to the given URL or until a timeout occurs.

## Error Handling

The crate uses a custom `DockerError` type for comprehensive error handling, making it easy to identify 
and handle Docker-related issues in your application.

When a Docker command fails, the returned `DockerError` carries the command's exit status and
its stderr, so the cause is reported where it happens rather than surfacing later as an
unexplained wait timeout.

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
