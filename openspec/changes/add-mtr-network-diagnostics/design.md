## Context

MTR (My Traceroute) combines traceroute and ping into a single diagnostic tool that continuously probes each hop between source and destination. The reference C implementation (https://github.com/traviscross/mtr) uses a privileged subprocess for raw socket operations, IPC pipes for communication, and a curses/GTK UI for display.

We need a pure-Go library implementation that integrates into the serviceradar-agent's existing push-mode architecture without external binary dependencies. The agent already has a high-performance ICMP scanner (`go/pkg/scan/icmp_scanner_unix.go`) that demonstrates the raw socket patterns we'll follow.

## Goals / Non-Goals

**Goals:**
- Pure-Go MTR implementation with ICMP, UDP, and TCP probe support
- Hop-by-hop statistics: loss%, min/avg/max/stddev latency, jitter
- ECMP path detection (multiple IPs per hop)
- Async DNS resolution for hop addresses
- Integration as agent check type with configurable intervals
- On-demand execution via ControlStream for ad-hoc diagnostics
- Structured results suitable for time-series storage and visualization

**Non-Goals:**
- Interactive TUI/curses display (agent is headless)
- SCTP probe support (rarely used, can add later)
- MPLS label extraction (complex, low priority for v1)
- AS number lookup (external dependency, defer to UI layer)
- Windows support (agent is Linux/macOS focused)

## Architecture

### Package Structure

```
go/pkg/mtr/
├── tracer.go          # Core tracer orchestration (send/receive loop)
├── probe.go           # Probe types (ICMP, UDP, TCP) and construction
├── hop.go             # Per-hop statistics tracking and calculation
├── socket.go          # Raw socket abstraction (platform-specific)
├── socket_linux.go    # Linux raw/dgram socket implementation
├── socket_darwin.go   # macOS raw socket implementation
├── dns.go             # Async DNS resolution with caching
├── options.go         # Configuration and option types
└── mtr_test.go        # Unit and integration tests
```

### Core Algorithm

Reimplementation follows the reference C MTR logic:

1. **Probe Loop** (per cycle):
   - For each TTL from 1 to maxHops:
     - Send probe packet with TTL set
     - Record send timestamp
   - Listen for ICMP Time Exceeded / Echo Reply / Dest Unreachable
   - Match responses to outstanding probes via sequence number
   - Calculate RTT = receive_time - send_time
   - Update per-hop running statistics

2. **Probe Identification**:
   - ICMP: Match by ICMP ID (PID) + Sequence number
   - UDP: Match by embedded sequence in destination port (base port 33434 + seq)
   - TCP: Match by source port binding

3. **Statistics** (incremental, matching reference MTR):
   - Loss% = `100 * (1 - received / (sent - in_flight))`
   - Mean: Welford's online algorithm
   - StdDev: `sqrt(variance / (n-1))`
   - Jitter: `|current_rtt - previous_rtt|`, avg/worst tracked
   - Sample ring buffer (last 200 RTTs per hop for sparkline/histogram data)

4. **Termination**:
   - Target reached (ICMP Echo Reply or UDP/TCP port unreachable from target)
   - maxHops exceeded
   - N consecutive non-responding hops (configurable, default 10)

### Socket Strategy

Follow existing `go/pkg/scan/icmp_scanner_unix.go` patterns:

```go
// Privileged (CAP_NET_RAW or root)
conn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")

// Unprivileged fallback (Linux only, SOCK_DGRAM)
conn, err := icmp.ListenPacket("udp4", "0.0.0.0")
```

Platform build tags (`socket_linux.go`, `socket_darwin.go`) handle differences in:
- IP header inclusion in raw socket reads
- Byte order of IP length field
- SOCK_DGRAM availability

### Agent Integration

**Check Type Registration:**
```go
// In push_loop.go, alongside existing ICMP check handling
case "mtr":
    mtrChecker := mtr.NewTracer(mtr.Options{
        Target:    cfg.Target,
        MaxHops:   getSettingInt(cfg.Settings, "max_hops", 30),
        Probes:    getSettingInt(cfg.Settings, "probes_per_hop", 10),
        Protocol:  getSettingStr(cfg.Settings, "protocol", "icmp"),
        Timeout:   time.Duration(cfg.TimeoutSec) * time.Second,
        Interval:  time.Duration(getSettingInt(cfg.Settings, "probe_interval_ms", 100)) * time.Millisecond,
    })
```

**Result Flow:**
```
Tracer.Run(ctx)
  → []HopResult (per-hop stats)
  → MtrTraceResult (full trace with metadata)
  → JSON marshal → GatewayServiceStatus.message
  → PushStatus() → Gateway → Core → CNPG
```

**On-Demand via ControlStream:**
```go
case "mtr.run":
    // Parse target from command payload
    // Run single MTR trace
    // Send results back via control stream response
```

### Configuration

```json
{
    "check_id": "mtr-to-gateway",
    "check_type": "mtr",
    "name": "Path to Gateway",
    "enabled": true,
    "interval_sec": 300,
    "timeout_sec": 30,
    "target": "10.0.0.1",
    "settings": {
        "max_hops": "30",
        "probes_per_hop": "10",
        "protocol": "icmp",
        "probe_interval_ms": "100",
        "packet_size": "64",
        "dns_resolve": "true"
    }
}
```

## Decisions

- **Pure Go, no CGo**: Avoids cross-compilation complexity, matches existing build patterns. Go's `syscall` and `golang.org/x/net/icmp` packages provide everything needed.
- **Library, not service**: MTR runs in-process as a check type, not a separate service. Keeps deployment simple — no additional binary or sidecar.
- **ICMP first, UDP/TCP follow**: ICMP probes are simplest and most universally supported. UDP and TCP probe modes are phase 2.
- **No privilege escalation subprocess**: Unlike C MTR which forks a privileged child, we rely on the agent already running with CAP_NET_RAW (same as ICMP scanner). Simpler architecture.
- **Incremental statistics**: Use Welford's algorithm for numerically stable online mean/variance, matching the reference implementation's approach.

## Alternatives Considered

1. **Shell out to `mtr` binary**: Rejected — adds external dependency, parsing fragility, no structured output control, and doesn't work on systems without MTR installed.
2. **Use `go-mtr` or similar library**: Evaluated — existing Go MTR libraries are incomplete (most only do ICMP, lack jitter/ECMP), unmaintained, or have incompatible licenses. Building from the C reference gives us full control.
3. **Wasm plugin**: Possible but premature — raw socket access from Wasm is not yet supported in the plugin sandbox. Native integration is the right first step.

## Risks / Trade-offs

- **Raw socket requirement** → Same privilege level agent already needs for ICMP scanner. Document in deployment guide.
- **Probe traffic volume** → Default 10 probes × 30 hops × every 5 minutes = modest. Add rate limiting and max concurrent trace config.
- **DNS resolution latency** → Async with goroutine pool + TTL cache. Never blocks probe loop.
- **Platform test coverage** → CI runs Linux; macOS tested manually. Build tags isolate platform code.

## Open Questions

- Should MTR results feed into the topology/god-view visualization? (defer to UI proposal)
- Should we support IPv6 in v1 or defer? (recommend: support from start, minimal extra effort)
- What CNPG schema for storing hop-by-hop time series? (defer to data layer proposal)
