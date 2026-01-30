# Design: Dusk Checker WASM Plugin

## Context

The dusk checker monitors Dusk blockchain nodes by connecting via WebSocket to the RUES (Rusk Event Stream) protocol, subscribing to block acceptance events, and reporting node health. It's currently embedded in `serviceradar-agent` as `DuskService`.

The WASM plugin system provides a sandboxed runtime (wazero) with host functions for network I/O, configuration, and result submission. The `serviceradar-sdk-go` abstracts these host functions into a developer-friendly Go API.

### Stakeholders
- Platform operators deploying Dusk monitoring
- Plugin developers as reference implementation
- Agent maintainers (reduced embedded code)

### Constraints
- TinyGo compilation limits (no goroutines, limited stdlib)
- WASI preview1 constraints on networking
- WebSocket requires either HTTP upgrade support or dedicated host function

## Goals / Non-Goals

### Goals
- Dusk checker runs as a standalone WASM plugin
- Plugin uses `serviceradar-sdk-go` for all host interactions
- Remove all embedded dusk code from `serviceradar-agent`
- Maintain feature parity with current implementation (block monitoring, health reporting)
- Plugin is assignable via control plane like other plugins
- Add WebSocket support to SDK and agent runtime

### Non-Goals
- Adding new dusk monitoring features (scope limited to migration)
- Backwards compatibility with embedded dusk checker
- Real-time block streaming (plugin executes on schedule, gets latest block)

## Decisions

### Decision 1: Plugin Architecture

**Choice**: Single-shot check model (not long-running WebSocket)

**Rationale**: The current embedded dusk checker maintains a persistent WebSocket connection. However, WASM plugins execute on a schedule and return results. We have two options:

1. **Long-running plugin** - Keep WebSocket open across invocations (complex, requires state persistence)
2. **Per-check connection** - Connect, get latest block, disconnect (simpler, aligns with plugin model)

Option 2 aligns with how other plugins work and avoids complex state management. The trade-off is slightly higher latency per check, but Dusk block times (~10s) make this acceptable.

**Alternatives considered**:
- Stateful plugin sessions - Adds complexity to plugin runtime, deferred to future enhancement

### Decision 2: WebSocket Host Function

**Choice**: Extend `http_request` to support WebSocket upgrade OR add `websocket_*` host functions

**Rationale**: The plugin needs to:
1. Upgrade HTTP connection to WebSocket
2. Send/receive binary messages
3. Handle RUES protocol framing

Options:
1. **Extend http_request** - Add `upgrade: websocket` option, return connection handle
2. **Dedicated websocket host functions** - `websocket_connect`, `websocket_send`, `websocket_recv`
3. **TCP raw sockets** - Plugin handles HTTP upgrade itself

Option 2 provides cleaner semantics. Option 3 is too low-level and duplicates HTTP handling.

**Decision**: Implement dedicated WebSocket host functions:
- `websocket_connect(url) -> handle`
- `websocket_send(handle, data) -> error`
- `websocket_recv(handle, timeout) -> data, error`
- `websocket_close(handle) -> error`

### Decision 3: Plugin Configuration Schema

**Choice**: Reuse existing `DuskConfig` structure mapped to plugin config

```yaml
# Plugin config (from DuskProfile)
node_address: "wss://node.example.com:8080"
timeout: "30s"
```

The plugin reads this via `sdk.LoadConfig()`. The control plane maps `DuskProfile` attributes to plugin configuration.

### Decision 4: Result Schema

**Choice**: Map block data to `serviceradar.plugin_result.v1`

```json
{
  "status": "OK",
  "summary": "Block 1234567 at 2025-01-29T12:00:00Z",
  "metrics": [
    {"name": "block_height", "value": 1234567, "unit": "blocks"},
    {"name": "block_age_seconds", "value": 5.2, "unit": "seconds"}
  ],
  "details": {
    "hash": "abc123...",
    "timestamp": "2025-01-29T12:00:00Z"
  }
}
```

This preserves all current data while fitting the standard plugin result format.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| WebSocket host function complexity | Use proven library (gorilla/websocket) in agent |
| TinyGo limitations break dusk logic | Test critical paths early; keep plugin logic simple |
| Performance regression from per-check connect | Acceptable for Dusk block times (~10s); measure latency |

## Implementation Notes (Added Post-Implementation)

### TinyGo Reflection Metadata

**Issue**: TinyGo's linker optimizes away reflection metadata for types not explicitly used with `json.Unmarshal`. This causes `sdk.LoadConfig()` to fail with `json: Unmarshal(nil *main.Config)`.

**Workaround**: Add explicit dummy unmarshal in the plugin:

```go
// TinyGo workaround: explicitly unmarshal to include reflection metadata
var initCfg Config
_ = json.Unmarshal([]byte(`{"node_address":"x"}`), &initCfg)

// Now sdk.LoadConfig works correctly
cfg := Config{}
_ = sdk.LoadConfig(&cfg)
```

### TinyGo Map Serialization

**Issue**: TinyGo has issues with map iteration during JSON marshalling. SDK methods like `WithLabel()` and `WithMetric()` that populate map fields cause runtime "out of bounds memory access" errors.

**Workaround**: For now, include all metadata in the summary text rather than using structured labels/metrics:

```go
// Instead of:
result := sdk.Ok("Block 1234").WithLabel("node", addr).WithMetric("height", 1234, "blocks", nil)

// Use:
result := sdk.Ok(fmt.Sprintf("Block %d, node: %s", height, addr))
```

**Future Fix**: Investigate TinyGo map support improvements or use slice-based alternatives for labels/metrics.

### Actual Result Schema

Due to TinyGo limitations, the actual result is simpler than the design:

```json
{
  "status": "OK",
  "summary": "Block 1234567 (hash: abc123...) at 2025-01-29T12:00:00Z, age: 5.2s, node: node.example.com:8080",
  "observed_at": "2025-01-29T12:00:05Z",
  "schema_version": 1
}
```

## Open Questions

1. Should WebSocket host functions be general-purpose or dusk-specific?
   - **Decision**: General-purpose, other plugins may need WebSocket
2. Where should the plugin source live?
   - **Decision**: `serviceradar-plugins` repo with Go and Rust plugin organization
3. Should we support TLS/mTLS for Dusk node connections in the plugin?
   - **Decision**: Yes, via host function that uses agent's cert store
