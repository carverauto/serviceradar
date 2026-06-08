# Agent Sidecar Status Types

The `sidecar` package contains the shared status types used when the Go agent
reports externally supervised native helpers such as `serviceradar-netprobe`.
It no longer launches or supervises add-on subprocesses.

## Runtime Ownership

Native add-ons use one of two runtime paths:

- `agent-sidecar` add-ons are supervised by `go/pkg/agent/addon`, which uses
  HashiCorp `go-plugin` and manages one client per assigned add-on.
- netprobe is delivered as a `systemd-service` add-on. The agent does not own
  that process; `go/pkg/agent/netprobe.AttachManager` only attaches to the
  well-known IPC socket, health checks it, pushes desired config on reconnect,
  and maps health into this package's `Status` shape.

## Status

`Status` contains the public sidecar state fields (`name`, `state`, `pid`,
`last_health_at`, `restart_count`, and `last_error`). `ToProtoStatuses` maps
those snapshots into the agent's `StatusResponse.sidecars` field.
