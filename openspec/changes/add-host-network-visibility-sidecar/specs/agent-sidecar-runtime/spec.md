## ADDED Requirements

### Requirement: Generic sidecar manager in `serviceradar-agent`

`serviceradar-agent` SHALL include a sidecar manager component
(`go/pkg/agent/sidecar/`) that owns the lifecycle of zero or more
co-located native sidecar processes. The manager MUST start configured
sidecars at agent startup, stop them on agent shutdown, and surface
their runtime state through the agent's status response.

#### Scenario: Sidecar starts when agent starts
- **WHEN** `serviceradar-agent` boots with at least one sidecar
  registered
- **THEN** the manager spawns the registered sidecar binary as a child
  process before the agent reports `ready`

#### Scenario: Sidecars terminate on agent shutdown
- **WHEN** `serviceradar-agent` receives `SIGTERM`
- **THEN** the manager sends `SIGTERM` to every supervised sidecar
- **AND** waits up to 5 seconds per sidecar for clean exit before
  sending `SIGKILL`

### Requirement: Per-sidecar Unix domain socket lifecycle

The manager SHALL create a per-sidecar socket directory under
`/run/serviceradar/<name>/` with `0700` permissions, pass the socket
path to the sidecar via `--socket`, and reuse the same socket for the
sidecar's lifetime. Sockets MUST be removed on clean shutdown.

#### Scenario: Stale socket from a previous run is removed before restart
- **WHEN** the manager restarts a sidecar after a crash
- **THEN** any pre-existing socket file at the configured path is
  unlinked before the new child is spawned

### Requirement: Structured liveness probing

The manager SHALL probe each sidecar's liveness over its IPC socket on
a configurable interval (default 5 seconds). A sidecar is considered
unhealthy after three consecutive probe failures or any unexpected
child exit. Unhealthy sidecars MUST be terminated and restarted under
exponential back-off starting at 1 second and capped at 60 seconds.

#### Scenario: Three failed probes trigger restart
- **WHEN** three consecutive probes return no response within their
  individual timeouts
- **THEN** the manager terminates the sidecar and schedules a restart
  under the next back-off slot

#### Scenario: Crash-loop circuit breaker engages
- **WHEN** a sidecar exits non-zero more than five times within one
  minute
- **THEN** the manager pauses restart attempts for at least 60 seconds
- **AND** marks the sidecar `circuit_open` in the agent status response

### Requirement: Sidecar state surfaced in agent status

The agent's status response SHALL include a `sidecars` collection where
each entry reports `name`, `state` (one of `starting`, `running`,
`unhealthy`, `restarting`, `circuit_open`, `stopped`), `pid` (when
running), `last_health_at`, `restart_count`, and `last_error` (when
present).

#### Scenario: UI consumer can read sidecar health from status
- **WHEN** a control-plane client requests the agent status
- **THEN** the response includes the `sidecars` array
- **AND** each entry carries the fields enumerated above

### Requirement: Sidecar capabilities are independent of the agent process

The manager MUST NOT inherit or share Linux capabilities, secrets, or
file descriptors with supervised sidecars beyond those required to
spawn and supervise the child. Each sidecar binary MUST acquire its
own privileges (file capabilities or Kubernetes pod `securityContext`)
independently of the parent agent process.

#### Scenario: Agent process retains no elevated capability granted to a sidecar
- **WHEN** a sidecar is configured to require `CAP_BPF`
- **THEN** the agent process itself does not gain `CAP_BPF`
- **AND** the capability is asserted only on the sidecar binary

### Requirement: Structured logging passthrough

The manager SHALL attach each supervised sidecar's stdout and stderr to
the agent's structured logger, tagging each line with at least
`sidecar=<name>` and `pid=<pid>` so operators can correlate sidecar
logs with the agent's log stream.

#### Scenario: Sidecar log line is tagged
- **WHEN** a sidecar writes a single line to stdout
- **THEN** the agent emits a structured log record containing the
  sidecar's line plus the `sidecar` and `pid` tags
