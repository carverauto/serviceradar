# Arancini 😋

![crates.io](https://img.shields.io/crates/v/arancini.svg)

**Arancini** is an experimental carrier-grade BGP Monitoring Protocol (BMP) collector designed for ultra-high throughput and sub-millisecond telemetry pipelines. Built on a shared-nothing, thread-per-core architecture, it ingests BMP feeds from routers and streams curated BGP updates to **NATS JetStream**.

Arancini is a high-performance fork of [Risotto](https://github.com/nxthdr/risotto), re-engineered for linear scalability and zero-copy data paths.

## Key Features

- **Thread-per-Core Architecture:** Powered by `monoio` and `io_uring`, Arancini pins worker threads to physical CPU cores, eliminating context switching and lock contention.
- **Zero-Copy Ingest:** Utilizes registered buffer rings to DMA packets directly from the kernel to userspace.
- **Shared-Nothing State:** Curation state is sharded across workers. Each core manages its own RIB, enabling lock-free deduplication and synthetic withdraw generation.
- **NATS JetStream Native:** Replaces Kafka with high-performance async publishing to NATS, supporting fine-grained subject schemas (e.g., `arancini.updates.v4_192_0_2_1.64512.1_1`).
- **Cloud-Native Persistence:** Supports state snapshots to local storage or NATS Object Store for seamless recovery in Kubernetes environments.

---

## Quick Start

The fastest way to deploy Arancini is via Docker. The following command displays the help menu:
```bash
docker run ghcr.io/carverauto/arancini:v0.7.2 --help
```

To run with default parameters (BMP on `:4000`, Metrics on `:8080`):
```bash
docker run \
  -p 4000:4000 \
  -p 8080:8080 \
  ghcr.io/carverauto/arancini:v0.7.2
```

Monitoring is available via the Prometheus endpoint at `http://localhost:8080/metrics`.

## Data Curation & Reliability

Arancini maintains a high-fidelity representation of connected routers and their peers to solve common BMP data integrity issues:

- **Duplicate Suppression:** Suppresses redundant prefix announcements caused by BMP session resets or router restarts.
- **Synthetic Withdraws:** Automatically generates withdraw messages when a Peer Down notification is received, even if the router fails to send them.
- **Stateless Mode:** For pure telemetry ingestion without curation, Arancini can be configured to forward all updates as-is, bypassing the state store.

## Architecture: Arancini vs. Risotto

While Risotto provides a robust standard async implementation, Arancini is built for massive scale:

| Feature | Risotto (Legacy) | Arancini |
|---|---|---|
| Async Runtime | Tokio (Work-Stealing) | Monoio (Thread-per-Core) |
| I/O Driver | Epoll / Kqueue | Linux `io_uring` |
| State Locking | Global `Arc<Mutex>` | Lock-Free Shards |
| Messaging | Kafka / Redpanda | NATS JetStream |
| Memory Path | Heap-allocated `Vec` | Registered `BufRing` |

## Kernel Tuning for High Load

To achieve maximum throughput (>500k updates/sec), ensure your Linux host is tuned for high-concurrency I/O:
```bash
# Increase file descriptor limits
ulimit -n 1048576

# Tune TCP receive buffers for large bursts
sysctl -w net.core.rmem_max=33554432
sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
```

## Contributing & Development

To test the full pipeline locally, refer to the Integration Tests. The setup uses Docker Compose to spin up:

1. **Routers:** BIRD and GoBGP instances.
2. **Infrastructure:** NATS JetStream and ClickHouse.
3. **Collector:** Arancini running in worker mode.

## Running Tests
```bash
docker compose -f integration/compose.yml up -d --build
```

---

Refer to the Docker Compose [integration](./integration/) tests to try Arancini locally. The setup includes BIRD and GoBGP routers announcing BGP updates between them, and transmitting BMP messages to Arancini.

## Linux Performance Validation

For Arancini deployments, run the tuning/socket validation checks:

```bash
bash integration/bench/run_2_6_linux_tuning_validation.sh
```

This validates:
- Runtime socket option enforcement in code (`SO_REUSEPORT`, `TCP_NODELAY`, backlog and `SO_RCVBUF` wiring).
- Linux host tuning guidance (`sysctl`, file descriptor limits, and RSS/IRQ readiness checks).

## Runtime Benchmark (Arancini)

Use this script to benchmark Arancini runtime throughput with producer paths disabled:

```bash
ROUTE_COUNT_PER_BIRD=2000 TARGET_RX_DELTA=2000 TIMEOUT_SECONDS=180 ARANCINI_WORKERS=4 \
  integration/bench/run_bird_saturating_runtime_benchmark.sh
```

The script writes the report to:

```bash
integration/bench/risotto-vs-arancini-bird-saturating-report.md
```

Use the report to capture current throughput and latency numbers for your target profile and host.

## NATS JetStream mTLS

Arancini supports TLS and mutual TLS for the NATS JetStream sidecar path.

Example:

```bash
./target/release/arancini \
  --nats-enable \
  --nats-server nats://nats.example.net:4222 \
  --nats-tls-required \
  --nats-tls-ca-cert-path /etc/arancini/nats/ca.pem \
  --nats-tls-client-cert-path /etc/arancini/nats/client.pem \
  --nats-tls-client-key-path /etc/arancini/nats/client-key.pem
```

Optional:
- `--nats-tls-first` enables handshake-first mode when the NATS server is configured for it.
