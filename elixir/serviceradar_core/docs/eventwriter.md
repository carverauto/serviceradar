# EventWriter TLS Connection Issue

## Overview

The Elixir EventWriter is a Broadway-based pipeline that consumes messages from NATS JetStream and writes them to PostgreSQL/TimescaleDB hypertables. It replaces the Go `db-event-writer` service.

## Current Status

The EventWriter implementation is complete and tested:
- All 47 unit tests pass
- Processors for OtelMetrics, OtelTraces, Logs, Telemetry, Sweep, NetFlow
- Broadway pipeline with batching and acknowledgment
- ClusterHealth integration
- OCSF v1.7.0 schema for events

**However, the EventWriter cannot connect to NATS in docker-compose due to a TLS handshake failure.**

## The Problem

### Error Message

From NATS server logs:
```
[DBG] 172.18.0.2:52902 - cid:37 - Client connection created
[DBG] 172.18.0.2:52902 - cid:37 - Starting TLS client connection handshake
[ERR] 172.18.0.2:52902 - cid:37 - TLS handshake error: tls: first record does not look like a TLS handshake
[DBG] 172.18.0.2:52902 - cid:37 - Client connection closed: TLS Handshake Failure
```

From core-elx logs:
```
18:14:07.727 [info] Starting EventWriter supervisor
18:14:07.728 [info] Starting EventWriter producer
18:14:07.731 [error] GenServer #PID<0.5760.0> terminating
** (stop) "connection closed"
Last message: {:tcp_closed, #Port<0.26>}
```

### Root Cause Analysis

The issue is a protocol mismatch between the NATS server's TLS expectations and the Gnat (Elixir NATS client) library's behavior.

#### NATS Server Configuration

The NATS server (`docker/compose/nats.docker.conf`) is configured with mandatory mTLS:

```
tls {
  cert_file: "/etc/serviceradar/certs/nats.pem"
  key_file: "/etc/serviceradar/certs/nats-key.pem"
  ca_file: "/etc/serviceradar/certs/root.pem"
  verify: true
  verify_and_map: true
}
```

With this configuration, NATS expects:
1. Client connects via TCP
2. TLS handshake happens immediately (before any NATS protocol)
3. After TLS, NATS protocol begins (INFO, CONNECT, etc.)

#### Gnat Library Behavior

The Gnat library (v1.12.1) follows a different flow:

```elixir
# From gnat/lib/gnat.ex connect function:
with {:ok, socket} <- open_socket(settings),           # 1. TCP connect
     {:ok, info_fields} <- recv_info(socket),          # 2. Wait for INFO
     {:ok, socket} <- maybe_upgrade_to_tls(...),       # 3. Upgrade to TLS
     :ok <- send_connect(socket, settings, info_fields) # 4. Send CONNECT
```

Gnat expects:
1. TCP connect
2. Receive INFO message (plain text)
3. If `tls_required: true` in INFO, upgrade to TLS
4. Send CONNECT

This is the **STARTTLS pattern** - TLS upgrade happens after initial protocol exchange.

### The Mismatch

| NATS Server (default) | Gnat Library |
|----------------------|--------------|
| Expects TLS immediately | Expects INFO first |
| `handshake_first: true` | STARTTLS pattern |
| Sends nothing until TLS | Sends INFO immediately |

When Gnat connects:
1. Gnat opens TCP connection
2. Gnat waits for INFO message
3. NATS waits for TLS handshake
4. Neither side proceeds → timeout/close

## What We've Tried

### 1. Added `handshake_first: false` to NATS config

```
tls {
  ...
  handshake_first: false
}
```

This should make NATS send INFO first before requiring TLS. However, the error persists.

**Possible reason**: The `handshake_first` option may only apply to explicit TLS upgrade negotiation, not to the mandatory TLS case with `verify: true`.

### 2. Verified Certificates Exist

All certificates are present in `/etc/serviceradar/certs/`:
- `core.pem` - client certificate
- `core-key.pem` - client private key
- `root.pem` - CA certificate

### 3. Verified TLS Config is Passed to Gnat

The TLS configuration from `runtime.exs`:
```elixir
nats_tls_config = [
  verify: :verify_peer,
  cacertfile: Path.join(cert_dir, "root.pem"),
  certfile: Path.join(cert_dir, "core.pem"),
  keyfile: Path.join(cert_dir, "core-key.pem"),
  server_name_indication: ~c"nats.serviceradar"
]
```

This is passed through `Config.load/0` → `Producer.build_connection_settings/1` → `Gnat.start_link/1`.

### 4. Other Services Connect Successfully

Go services (datasvc), Rust services (zen, flowgger, trapd, otel-collector) all connect successfully to NATS with TLS. These clients use native TLS from the start, not STARTTLS.

## Potential Solutions

### Option 1: Patch Gnat to Support Implicit TLS

Modify Gnat to use `:ssl.connect/3` directly instead of `:gen_tcp.connect/3` when TLS options are provided:

```elixir
defp open_socket(settings) do
  host = Map.fetch!(settings, :host) |> to_charlist()
  port = Map.get(settings, :port, 4222)

  case Map.get(settings, :tls) do
    opts when is_list(opts) ->
      # Connect with SSL directly for implicit TLS
      :ssl.connect(host, port, [:binary | opts], timeout)
    _ ->
      # Plain TCP
      :gen_tcp.connect(host, port, tcp_opts, timeout)
  end
end
```

**Pros**: Cleanest solution, works with any NATS TLS config
**Cons**: Requires forking/patching Gnat

### Option 2: Use off_broadway_jetstream

The `off_broadway_jetstream` library might handle TLS differently. Would need to evaluate its TLS support.

**Pros**: Purpose-built for Broadway + JetStream
**Cons**: Different API, may have same TLS issue

### Option 3: Add Non-TLS Listener to NATS

Configure NATS with a second listener without TLS for internal services:

```
listen: 0.0.0.0:4222  # TLS required

# Add internal listener
listen: 127.0.0.1:4223  # No TLS, localhost only
```

**Pros**: Quick fix, no client changes
**Cons**: Reduces security, internal traffic unencrypted

### Option 4: Use TCP Proxy with TLS Termination

Add a TLS-terminating proxy between Gnat and NATS:

```
core-elx → plain TCP → stunnel → TLS → nats
```

**Pros**: No code changes
**Cons**: Additional complexity, extra container

### Option 5: Custom Producer with Direct SSL

Bypass Gnat's connection handling and use Erlang's `:ssl` module directly:

```elixir
def connect(config) do
  ssl_opts = [
    :binary,
    active: false,
    verify: :verify_peer,
    cacertfile: config.nats.tls[:cacertfile],
    certfile: config.nats.tls[:certfile],
    keyfile: config.nats.tls[:keyfile]
  ]

  {:ok, socket} = :ssl.connect(
    to_charlist(config.nats.host),
    config.nats.port,
    ssl_opts,
    5000
  )

  # Now use socket for NATS protocol
  # ... implement NATS protocol manually or use Gnat internals
end
```

**Pros**: Full control over TLS
**Cons**: Significant implementation effort

### Option 6: Contribute Fix to Gnat

Open an issue/PR on the Gnat repository to add support for implicit TLS connections.

**Pros**: Benefits the community
**Cons**: Timeline depends on maintainers

## Recommended Approach

**Short-term**: Option 3 (non-TLS internal listener) or Option 1 (fork Gnat)

**Long-term**: Option 6 (contribute to Gnat) + Option 1 (maintain fork until merged)

## Configuration Reference

### NATS Server Config (`docker/compose/nats.docker.conf`)

```
tls {
  cert_file: "/etc/serviceradar/certs/nats.pem"
  key_file: "/etc/serviceradar/certs/nats-key.pem"
  ca_file: "/etc/serviceradar/certs/root.pem"
  verify: true
  verify_and_map: true
  handshake_first: false  # Added but not working
}
```

### EventWriter Config (`config/runtime.exs`)

```elixir
nats_tls_config = [
  verify: :verify_peer,
  cacertfile: Path.join(cert_dir, "root.pem"),
  certfile: Path.join(cert_dir, "core.pem"),
  keyfile: Path.join(cert_dir, "core-key.pem"),
  server_name_indication: ~c"nats.serviceradar"
]

config :serviceradar_core, ServiceRadar.EventWriter,
  enabled: true,
  nats: [
    host: nats_uri.host || "localhost",
    port: nats_uri.port || 4222,
    tls: nats_tls_config
  ]
```

### Producer Connection (`lib/serviceradar/event_writer/producer.ex`)

```elixir
defp build_connection_settings(nats_config) do
  settings = %{
    host: nats_config.host,
    port: nats_config.port
  }

  settings =
    if nats_config.tls do
      Map.put(settings, :tls, nats_config.tls)
    else
      settings
    end

  settings
end
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `EVENT_WRITER_ENABLED` | Enable EventWriter | `false` |
| `EVENT_WRITER_NATS_URL` | NATS connection URL | `nats://localhost:4222` |
| `EVENT_WRITER_NATS_TLS` | Enable TLS | `false` |
| `SPIFFE_CERT_DIR` | Certificate directory | `/etc/serviceradar/certs` |
| `EVENT_WRITER_BATCH_SIZE` | Batch size for inserts | `100` |
| `EVENT_WRITER_BATCH_TIMEOUT` | Batch timeout (ms) | `1000` |

## Related Files

- `lib/serviceradar/event_writer/producer.ex` - Broadway producer with NATS connection
- `lib/serviceradar/event_writer/pipeline.ex` - Broadway pipeline configuration
- `lib/serviceradar/event_writer/config.ex` - Configuration loading
- `lib/serviceradar/event_writer/health.ex` - Health check module
- `config/runtime.exs` - Runtime configuration with TLS settings
- `docker/compose/nats.docker.conf` - NATS server configuration

## Testing Without TLS

To test EventWriter without TLS (development only):

1. Set environment variable:
   ```
   EVENT_WRITER_NATS_TLS=false
   ```

2. Add non-TLS listener to NATS (requires config change)

3. Or use a local NATS instance without TLS:
   ```bash
   docker run -p 4222:4222 nats:latest
   ```
