## Context

MTR (My Traceroute) combines traceroute and ping into a single diagnostic tool that continuously probes each hop between source and destination. The reference C implementation (https://github.com/traviscross/mtr) uses a privileged subprocess for raw socket operations, IPC pipes for communication, and a curses/GTK UI for display.

We need a pure-Go library implementation that integrates into the serviceradar-agent's existing push-mode architecture without external binary dependencies. The agent already has a high-performance ICMP scanner (`go/pkg/scan/icmp_scanner_unix.go`) that demonstrates the raw socket patterns we'll follow.

Results are enriched at collection time (MPLS labels from ICMP extensions, ASN from GeoLite2 MMDB, reverse DNS) so the stored dataset is complete and never needs downstream enrichment. Path data is projected into Apache AGE (`platform_graph`) for God View topology visualization.

## Goals / Non-Goals

**Goals:**
- Pure-Go MTR implementation with ICMP, UDP, and TCP probe support
- IPv4 and IPv6 support from day one
- Hop-by-hop statistics: loss%, min/avg/max/stddev latency, jitter
- ECMP path detection (multiple IPs per hop)
- MPLS label extraction from RFC 4884 ICMP extension objects
- ASN/org enrichment at collection time via GeoLite2 MMDB (reusing existing enrichment patterns)
- Async DNS resolution for hop addresses
- Integration as agent check type with configurable intervals
- On-demand execution via ControlStream for ad-hoc diagnostics
- TimescaleDB hypertables for time-series hop data storage
- Apache AGE graph projection for path topology
- God View topology overlay with MTR path visualization
- Web UI: MTR results page, device detail MTR tab, on-demand trigger

**Non-Goals:**
- Interactive TUI/curses display (agent is headless)
- SCTP probe support (rarely used, can add later)
- Windows support (agent is Linux/macOS focused)
- Real-time streaming MTR display (polling-based updates are sufficient for v1)

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
├── mpls.go            # RFC 4884 ICMP extension parsing, MPLS label extraction
├── enrich.go          # ASN/GeoIP enrichment via MMDB lookup
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
   - Parse ICMP extensions for MPLS labels (RFC 4884)
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

5. **Post-Trace Enrichment** (before result push):
   - For each hop IP: lookup ASN + org name from GeoLite2-ASN.mmdb
   - Reverse DNS already resolved async during trace
   - MPLS labels already extracted inline from ICMP responses
   - Result payload contains complete enriched dataset

### MPLS Label Extraction

Reference C MTR extracts MPLS from ICMP Time Exceeded extensions (RFC 4884):

```
ICMP Time Exceeded packet:
  [IP Header][ICMP Header][Original IP Header + 128 bytes]
  [Extension Header (if ICMP length field > 0)]
    [Object Header: length, class=1 (MPLS), c-type=1]
      [Label Entry: 20-bit label | 3-bit exp | 1-bit S | 8-bit TTL]
```

Go implementation parses the extension objects after the original datagram:
- Check ICMP header length field for extension presence
- Parse extension header (version 2, checksum)
- Iterate objects looking for class=1 (MPLS Incoming Label Stack)
- Extract label entries (4 bytes each): label, experimental bits, bottom-of-stack, TTL

### ASN Enrichment

Reuses the existing `IpEnrichmentRefreshWorker` pattern but runs at the agent level:

```go
type Enricher struct {
    asnDB *maxminddb.Reader  // GeoLite2-ASN.mmdb
}

type ASNInfo struct {
    ASN  uint32 `json:"asn"`
    Org  string `json:"org"`
}

func (e *Enricher) LookupASN(ip net.IP) (*ASNInfo, error)
```

- Agent loads MMDB file at startup (configurable path, default `/usr/share/GeoIP/GeoLite2-ASN.mmdb`)
- Lookup is local, sub-microsecond per IP — no external API calls
- Graceful degradation: if MMDB unavailable, ASN fields are empty
- Each hop result includes `asn`, `asn_org` fields pre-populated

### Socket Strategy

Follow existing `go/pkg/scan/icmp_scanner_unix.go` patterns:

```go
// Privileged (CAP_NET_RAW or root)
conn, err := net.ListenPacket("ip4:icmp", "0.0.0.0")   // IPv4
conn6, err := net.ListenPacket("ip6:ipv6-icmp", "::")   // IPv6

// Unprivileged fallback (Linux only, SOCK_DGRAM)
conn, err := icmp.ListenPacket("udp4", "0.0.0.0")
conn6, err := icmp.ListenPacket("udp6", "::")
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
        ASNDBPath: getSettingStr(cfg.Settings, "asn_db_path", "/usr/share/GeoIP/GeoLite2-ASN.mmdb"),
    })
```

**Result Flow:**
```
Tracer.Run(ctx)
  → []HopResult (per-hop stats + MPLS labels)
  → Enricher.EnrichHops(hops) (ASN lookup per hop IP)
  → MtrTraceResult (full enriched trace)
  → JSON marshal → GatewayServiceStatus.message
  → PushStatus() → Gateway → Core
  → Core ingestion:
      → CNPG hypertable insert (mtr_traces + mtr_hops)
      → AGE graph projection (MTR_PATH edges)
      → God View snapshot includes MTR overlay
```

**On-Demand via ControlStream:**
```go
case "mtr.run":
    // Parse target from command payload
    // Run single MTR trace with enrichment
    // Send results back via control stream response
```

### CNPG Schema

**`mtr_traces` hypertable** — One row per completed trace:
```sql
CREATE TABLE platform.mtr_traces (
    timestamp       TIMESTAMPTZ NOT NULL,
    trace_id        UUID NOT NULL DEFAULT gen_random_uuid(),
    agent_id        TEXT NOT NULL,
    gateway_id      TEXT NOT NULL,
    target          TEXT NOT NULL,
    target_ip       INET NOT NULL,
    target_reached  BOOLEAN NOT NULL,
    total_hops      INT NOT NULL,
    protocol        TEXT NOT NULL,         -- icmp, udp, tcp
    ip_version      INT NOT NULL,          -- 4 or 6
    packet_size     INT,
    PRIMARY KEY (timestamp, trace_id)
);
SELECT create_hypertable('platform.mtr_traces', 'timestamp');
```

**`mtr_hops` hypertable** — One row per hop per trace:
```sql
CREATE TABLE platform.mtr_hops (
    timestamp       TIMESTAMPTZ NOT NULL,
    trace_id        UUID NOT NULL,
    hop_number      INT NOT NULL,
    hop_ip          INET,                  -- NULL for non-responding hops
    hostname        TEXT,
    asn             INT,
    asn_org         TEXT,
    loss_pct        REAL NOT NULL,
    sent            INT NOT NULL,
    received        INT NOT NULL,
    last_rtt_us     INT,                   -- microseconds
    avg_rtt_us      INT,
    min_rtt_us      INT,
    max_rtt_us      INT,
    stddev_rtt_us   INT,
    jitter_us       INT,
    jitter_avg_us   INT,
    jitter_worst_us INT,
    mpls_labels     JSONB,                 -- [{label: 12345, exp: 0, ttl: 1, s: true}]
    ecmp_addrs      INET[],               -- additional IPs if ECMP detected
    PRIMARY KEY (timestamp, trace_id, hop_number)
);
SELECT create_hypertable('platform.mtr_hops', 'timestamp');

CREATE INDEX idx_mtr_hops_trace ON platform.mtr_hops (trace_id, hop_number);
CREATE INDEX idx_mtr_hops_hop_ip ON platform.mtr_hops (hop_ip, timestamp DESC);
```

### Apache AGE Graph Projection

MTR paths are projected into `platform_graph` alongside existing CANONICAL_TOPOLOGY edges:

**New vertex label:** `HopNode` — represents a network hop that isn't (yet) a known Device
- Properties: `ip`, `hostname`, `asn`, `asn_org`
- If hop IP matches a known Device, the Device vertex is used instead

**New edge label:** `MTR_PATH` — directional edge representing an observed MTR hop-to-hop link
- Properties: `agent_id`, `trace_id`, `hop_number`, `avg_rtt_us`, `loss_pct`, `last_seen`, `protocol`

**Projection logic** (runs on each trace ingestion):
```cypher
-- For each consecutive hop pair (hop_n → hop_n+1):
MERGE (a:Device {ip: $hop_n_ip})
  ON CREATE SET a.id = 'mtr:' || $hop_n_ip, a.name = $hop_n_hostname
MERGE (b:Device {ip: $hop_n1_ip})
  ON CREATE SET b.id = 'mtr:' || $hop_n1_ip, b.name = $hop_n1_hostname
MERGE (a)-[r:MTR_PATH {agent_id: $agent_id}]->(b)
  SET r.avg_rtt_us = $avg_rtt, r.loss_pct = $loss, r.last_seen = $timestamp
```

God View GodViewStream already queries `platform_graph` — adding `MTR_PATH` to the relationship filter enables the overlay with no changes to the snapshot pipeline.

### Web UI Architecture

**MTR Results Page** (`/diagnostics/mtr`):
- LiveView with periodic polling of `mtr_traces` + `mtr_hops` via Ash read actions
- Hop-by-hop table: hop #, IP, hostname, ASN (org), loss%, avg/min/max RTT, jitter, MPLS labels
- Per-hop latency sparkline (last N samples from ring buffer or historical data)
- Path comparison: select two timestamps, highlight changed hops

**God View MTR Overlay**:
- New overlay layer toggle in God View controls
- MTR_PATH edges rendered as animated directional arcs
- Color-coded by latency (green → yellow → red gradient)
- Edge thickness proportional to loss%
- Tooltip shows full hop stats on hover

**Device Detail MTR Tab**:
- Shows all MTR traces where device IP appears as source, target, or intermediate hop
- Historical path chart showing hop count and latency trends over time
- Quick action: "Run MTR to this device" triggers `mtr.run` via ControlStream

**On-Demand MTR Dialog**:
- Modal triggered from device actions or diagnostics page
- Select source agent, enter target, choose protocol
- Shows live results as trace completes (polling)

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
        "dns_resolve": "true",
        "asn_db_path": "/usr/share/GeoIP/GeoLite2-ASN.mmdb"
    }
}
```

## Decisions

- **Pure Go, no CGo**: Avoids cross-compilation complexity, matches existing build patterns. Go's `syscall` and `golang.org/x/net/icmp` packages provide everything needed.
- **Library, not service**: MTR runs in-process as a check type, not a separate service. Keeps deployment simple — no additional binary or sidecar.
- **Enrich at collection time**: ASN, MPLS, and DNS are resolved/extracted at the agent before pushing results. Stored dataset is complete — no downstream enrichment needed. This trades slightly larger payloads for elimination of enrichment lag and simplification of the query path.
- **MMDB for ASN (not API)**: GeoLite2 MMDB is local, sub-microsecond per lookup, no external API dependency. Same pattern used by existing `IpEnrichmentRefreshWorker`.
- **Hypertables + AGE (not either/or)**: Hypertables store the time-series metrics (latency, loss over time). AGE stores the topology relationships (path structure). Different query patterns, complementary storage.
- **No privilege escalation subprocess**: Unlike C MTR which forks a privileged child, we rely on the agent already running with CAP_NET_RAW (same as ICMP scanner). Simpler architecture.
- **Incremental statistics**: Use Welford's algorithm for numerically stable online mean/variance, matching the reference implementation's approach.
- **IPv6 from day one**: Minimal extra effort — same socket patterns with `ip6:ipv6-icmp`, ICMPv6 message types, and `net.IP` already handles both families.

## Alternatives Considered

1. **Shell out to `mtr` binary**: Rejected — adds external dependency, parsing fragility, no structured output control, and doesn't work on systems without MTR installed.
2. **Use `go-mtr` or similar library**: Evaluated — existing Go MTR libraries are incomplete (most only do ICMP, lack jitter/ECMP/MPLS), unmaintained, or have incompatible licenses. Building from the C reference gives us full control.
3. **Wasm plugin**: Possible but premature — raw socket access from Wasm is not yet supported in the plugin sandbox. Native integration is the right first step.
4. **Defer ASN enrichment to UI/query layer**: Rejected — enriching at query time adds latency and requires MMDB availability on the core/web host. Agent-side enrichment is simpler and produces self-contained results.
5. **Store paths only in AGE (skip hypertables)**: Rejected — AGE is great for topology queries but not for time-series analytics (latency trends, loss patterns over time). Need both.

## Risks / Trade-offs

- **Raw socket requirement** → Same privilege level agent already needs for ICMP scanner. Document in deployment guide.
- **Probe traffic volume** → Default 10 probes x 30 hops x every 5 minutes = modest. Add rate limiting and max concurrent trace config.
- **DNS resolution latency** → Async with goroutine pool + TTL cache. Never blocks probe loop.
- **Platform test coverage** → CI runs Linux; macOS tested manually. Build tags isolate platform code.
- **MPLS visibility** → Not all routers emit RFC 4884 extensions. MPLS fields are optional; absent labels simply omitted.
- **MMDB freshness** → GeoLite2 databases update weekly. Stale data means slightly outdated ASN mappings — acceptable for network diagnostics.
- **AGE graph size** → MTR paths add vertices/edges to `platform_graph`. Mitigated by: pruning stale MTR_PATH edges (configurable TTL), and using MERGE to avoid duplicates.

## Open Questions

- Retention policy for `mtr_traces`/`mtr_hops` hypertables — 30 days? 90 days? (suggest: align with existing telemetry retention)
- Should stale `MTR_PATH` edges in AGE be auto-pruned, and if so, after how long? (suggest: 24h since last_seen)
- Continuous Aggregate (CAGG) candidates: `mtr_hop_stats_5m` bucketing avg latency/loss per hop per 5-min window?
