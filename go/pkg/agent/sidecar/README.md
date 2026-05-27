# Agent Sidecar Runtime

The `sidecar` package supervises long-lived helper processes owned by the Go
agent. Phase 1 uses the runtime for `serviceradar-netprobe`; future sidecars can
reuse the same contract.

## Contract

Implement `Sidecar` for each child process:

- `Name()` returns a stable identifier used in logs, status snapshots, socket
  paths, and config paths.
- `BinaryPath()` returns the executable to launch.
- `Args(socketPath, configPath string)` returns process arguments. The manager
  computes the socket and config paths as `<runtime-dir>/<name>.sock` and
  `<config-dir>/<name>.json`.
- `OnHealthy(client)` is called after a successful health probe. The health
  client is closed after the callback returns.
- `OnUnhealthy(err)` is called after the configured consecutive health probe
  failure threshold or when the restart circuit breaker opens.

## Supervision

The manager starts each sidecar with `exec.CommandContext`, streams stdout and
stderr through the agent logger with `sidecar=<name>` and `pid=<pid>` fields,
and restarts unexpected exits with exponential backoff. Defaults:

- health interval: 5 seconds
- unhealthy threshold: 3 failed probes
- restart backoff: 1 second, doubling to a 60 second cap
- restart circuit breaker: 5 restarts per minute
- shutdown: SIGTERM, then SIGKILL after 5 seconds

`Manager.Status()` returns one status record per sidecar with `name`, `state`,
`pid`, `last_health_at`, `restart_count`, and `last_error`. The agent service is
responsible for mapping those snapshots into its public status response.
