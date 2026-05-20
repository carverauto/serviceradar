---
title: Network Performance Testing
---

# Network Performance Testing (rperf)

ServiceRadar can actively measure network performance between two points in
your environment using **rperf**. Unlike passive monitoring (which observes
traffic that already exists), rperf generates synthetic traffic and measures how
the network handles it.

For each test, rperf reports:

- **Throughput** — bits per second achieved for TCP or UDP traffic.
- **Jitter** — variation in packet delay (UDP), in milliseconds.
- **Packet loss** — packets sent versus received, and loss percentage (UDP).
- **Bytes / packets transferred** over the test duration.

This makes rperf useful for validating circuit capacity, catching degraded
WAN links, and alerting before users notice slow connectivity.

## Architecture

rperf in ServiceRadar has two distinct components. They are easy to confuse, so
keep the distinction clear:

| Component | Binary / Pod | Role | Listens on |
|-----------|--------------|------|------------|
| **rperf checker** | `serviceradar-rperf-checker` (gRPC checker pod) | Runs tests on a schedule, reports results into ServiceRadar | TCP `50081` (gRPC, mTLS) |
| **rperf server** | `serviceradar-rperf` (RPM / systemd binary) | The *target* of a test; deployed on hosts you want to measure | TCP `5199` + a UDP port pool (`5200-5210`) |

The flow is:

1. The **rperf checker** is a ServiceRadar gRPC checker. A ServiceRadar
   agent/gateway polls it; on its own schedule the checker runs rperf tests
   against each configured target.
2. Each **target** is an **rperf server** running on a remote host. The checker
   acts as the rperf *client*, connecting to the server's control port (`5199`)
   and exchanging test traffic over the data ports.
3. Test results are pushed back through ServiceRadar as time-series metrics,
   where they can be queried and alerted on.

> **Port note:** the checker listens on **`50081`**, and the rperf server uses
> **`5199`** plus the UDP data pool. Older copies of the `rperf-client` README
> reference `50059`/`50051` — those are stale; use the values above.

## Deploying the rperf server on a target host

Install the `serviceradar-rperf` package (RPM) on each host you want to test
*to*. It runs as a long-lived systemd service:

```bash
sudo systemctl enable --now serviceradar-rperf
```

The packaged unit starts the server with an explicit port layout:

```
ExecStart=/usr/local/bin/serviceradar-rperf --server \
  --port 5199 \
  --tcp-port-pool 5200-5210 \
  --udp-port-pool 5200-5210
```

- `--port 5199` — the control/handshake port.
- `--tcp-port-pool` / `--udp-port-pool` — the range of data-stream ports used
  during a test. Make sure these match what the checker targets (see
  `tcp_port_pool` below).

The server runs as the unprivileged `serviceradar` user and logs to
`/var/log/rperf/rperf.log`.

### Restrict access with a firewall

The rperf server accepts test traffic from any client that can reach it. Always
restrict it to the checker's source address with a host firewall.

**ufw**

```bash
sudo ufw allow from <checker-ip> to any port 5199
sudo ufw allow from <checker-ip> to any port 5199 proto udp
sudo ufw allow from <checker-ip> to any port 5200:5210 proto udp
sudo ufw deny 5199
```

**firewalld**

```bash
sudo firewall-cmd --zone=trusted --add-source=<checker-ip> --permanent
sudo firewall-cmd --zone=trusted --add-port=5199/tcp --permanent
sudo firewall-cmd --zone=trusted --add-port=5200-5210/udp --permanent
sudo firewall-cmd --reload
```

**iptables**

```bash
sudo iptables -A INPUT -p tcp --dport 5199 -s <checker-ip> -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 5199 -j DROP
```

## Configuring the rperf checker

The checker reads a JSON config file (default path
`/etc/serviceradar/checkers/rperf.json`, set via the `CONFIG_PATH` environment
variable). A minimal config looks like this:

```json
{
  "listen_addr": "0.0.0.0:50081",
  "name": "rperf-checker",
  "type": "grpc",
  "timeout": "30s",
  "security": {
    "mode": "mtls",
    "cert_dir": "/etc/serviceradar/certs",
    "tls": {
      "cert_file": "rperf-checker.pem",
      "key_file": "rperf-checker-key.pem",
      "ca_file": "root.pem",
      "client_ca_file": "root.pem"
    }
  },
  "default_poll_interval": 300,
  "targets": [
    {
      "name": "TCP Test",
      "address": "10.0.0.20",
      "port": 5199,
      "tcp_port_pool": "5200-5210",
      "protocol": "tcp",
      "reverse": false,
      "bandwidth": 1000000,
      "duration": 10.0,
      "parallel": 1,
      "omit": 1,
      "poll_interval": 300
    }
  ]
}
```

### Top-level fields

| Field | Description |
|-------|-------------|
| `listen_addr` | Address/port the checker's gRPC server binds to (`50081`). |
| `security.mode` | `mtls`, `spiffe`, or `none`. Production uses `mtls`. |
| `security.cert_dir` | Directory holding the certificates; relative `tls.*` paths resolve against it. |
| `security.tls` | Certificate, key, and CA files for mTLS (required when `mode` is `mtls`). |
| `default_poll_interval` | Default seconds between tests, used when a target omits `poll_interval`. |
| `targets` | List of rperf servers to test against. |

### Target fields

| Field | Description |
|-------|-------------|
| `name` | Display name for the target. |
| `address` | Hostname or IP of the rperf **server**. |
| `port` | Control port on the server (`5199`). |
| `tcp_port_pool` | Data-stream port range; must match the server's pool. |
| `protocol` | `tcp` or `udp`. UDP is required to measure jitter and loss. |
| `reverse` | When `true`, the server sends and the checker receives (tests the download direction). |
| `bandwidth` | Target rate in **bytes/sec** (e.g. `1000000` = 1 MB/s). For UDP this is the send rate; for TCP it is an upper bound. |
| `duration` | Test length in seconds. |
| `parallel` | Number of parallel streams. |
| `omit` | Seconds to omit from the start of the test (warm-up; excluded from results). |
| `poll_interval` | Seconds between tests for this target. |

The configuration is validated on load: `protocol` must be `tcp` or `udp`,
`poll_interval` must be greater than zero, and a `tls` section is required when
`security.mode` is `mtls`.

## Deploying with Helm

The Helm chart ships an `rperf-checker` deployment (`serviceradar-rperf-client`)
that runs the checker pod, exposes it as a Service on port `50081`, and mounts
runtime certificates for mTLS.

The chart's default config is rendered from a template that contains the
placeholder **`PLACEHOLDER_RPERF_TARGET_ADDRESS`**. You must replace this with
the real address of an rperf server before the checker can run useful tests —
otherwise the `targets` list points at a placeholder. Set it through your
values overrides (or seed a real `targets` list via the KV store; see
[Configuration & KV Store](./configuration-system.md)).

## Querying results with SRQL

rperf results are stored as time-series metrics. In SRQL, the `rperf` entity is
an **alias for `timeseries_metrics`** — it shares the same schema, so you query
it like any other metric stream:

```sql
-- Recent rperf measurements
in:rperf | sort timestamp desc | limit 50

-- Throughput for a single target over the last day
in:rperf metric_name:"bits_per_second" target_device_ip:"10.0.0.20"
  | sort timestamp desc

-- UDP packet loss
in:rperf metric_name:"loss_percent" | sort timestamp desc
```

See the [SRQL Language Reference](./srql-language-reference.md) for the full
`timeseries_metrics` field list (`metric_name`, `metric_type`, `value`,
`target_device_ip`, `agent_id`, `timestamp`, and so on).

## Alerting on degradation

Because results land in `timeseries_metrics`, you can build alerts the same way
you would for any metric:

- **Throughput drop** — alert when `bits_per_second` for a target falls below an
  expected baseline.
- **Packet loss** — alert when `loss_percent` rises above a threshold (for UDP
  targets).
- **Jitter** — alert when `jitter_ms` exceeds your tolerance for latency-
  sensitive workloads.
- **Missing results** — alert when no rperf metrics arrive for a target within
  a multiple of its `poll_interval`, which usually means the checker cannot
  reach the rperf server.

Use the [Rule Builder](./rule-builder.md) to turn these into notifications.
