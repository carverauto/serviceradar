# Proposal 004: Agent Metric Buffering & Normalization

## Status
Draft

## Context
Currently, the agent `PushLoop` polls services for their "current status" at the push interval (default 30s). Services like SNMP may poll targets much faster (e.g., 1s or 5s). Intermediate data points collected between pushes are effectively discarded or overwritten in the `TargetStatus` map.

This results in:
1.  **Aliasing:** High-frequency changes (spikes) are missed if they don't align with the 30s push.
2.  **Inaccurate Rates:** Calculating bandwidth rates (deltas) at the backend based on 30s samples averages out bursty traffic, hiding congestion events.
3.  **Data Loss:** If the agent collects 6 samples but only sends 1, 83% of the data is lost.

## Goals
1.  **Lossless Collection:** Transmit all data points collected by the agent to the gateway/backend.
2.  **High-Fidelity Charts:** Enable per-second resolution visibility even if the agent only pushes to the cloud every 30s (decoupling collection resolution from transmission latency).
3.  **Memory Safety:** Use fixed-size ring buffers to prevent memory leaks while buffering high-frequency data.
4.  **Edge Normalization:** Perform rate calculations (counters -> rates) at the edge (agent) where the raw high-frequency data exists.

## Proposed Design

### 1. The Metric Ring Buffer
We will introduce a low-level, high-performance Ring Buffer data structure. This will likely be placed in a shared package (e.g., `pkg/ds/ring` or `pkg/agent/core`).

**Characteristics:**
*   **Fixed Size:** Pre-allocated at initialization. No resizing during runtime.
*   **Overwrite:** Oldest data is overwritten if not drained fast enough (safety valve).
*   **Dual Pointers:**
    *   `Head`: Where new data is written.
    *   `Tail` (Read/Drain): Where the `PushLoop` consumes data from.

```go
// Conceptual Go Structure
type RingBuffer struct {
    Values []float64
    Times  []int64 // Unix timestamps (ms or ns resolution)
    Head   int     // Write position
    Tail   int     // Read position (for draining)
    Size   int     // Total capacity
    Count  int     // Number of readable items
    Mu     sync.RWMutex
}

// Write adds a value. If full, overwrites oldest and advances Tail.
func (r *RingBuffer) Write(t int64, v float64)

// Drain returns all values from Tail to Head and resets Tail to Head.
func (r *RingBuffer) Drain() ([]int64, []float64)
```

### 2. Service "Drain" Interface
The `Service` interface (or a specific `MetricProvider` interface) will be updated to allow "pulling" historical data rather than just "getting" current status.

```go
type MetricProvider interface {
    // DrainMetrics returns all data points collected since the last Drain call.
    // The map key is the unique metric identifier (e.g. "ifInOctets::1")
    DrainMetrics() map[string][]DataPoint
}
```

### 3. SNMP Service Refactor
Currently, `pkg/agent/snmp/aggregator.go` stores `TimeSeriesData` in slices. This will be replaced or augmented by the Ring Buffer.

*   **Collector (`collector.go`):**
    *   Currently: Collects Raw Value -> Sends to Channel.
    *   Proposed: Collects Raw Value -> Calculates Rate/Delta (if `oid.Delta=true`) immediately -> Sends Rate to Channel.
*   **Aggregator (`aggregator.go`):**
    *   Currently: Appends to slice (unbounded growth risk if not pruned).
    *   Proposed: Writes to `RingBuffer`.
*   **Drain:**
    *   New method `SNMPService.DrainMetrics()` will iterate over all Aggregators/RingBuffers and extract pending data.

### 4. PushLoop Update
Update `pushSNMPMetrics` in `pkg/agent/push_loop.go`:
1.  Instead of calling `GetTargetStatuses` (which returns a snapshot), call `DrainMetrics`.
2.  Batch these points into the `GatewayStatusChunk`.
3.  The backend (Event Writer) will receive a batch of timestamps and values, writing them all to the TimeSeriesDB.

## Netdata Comparison
| Feature | ServiceRadar Current | ServiceRadar Proposed | Netdata |
| :--- | :--- | :--- | :--- |
| **Storage** | Single Value (LastValue) | Ring Buffer (All Values) | Ring Buffer (dbengine) |
| **Transport** | Snapshot (Lossy) | Batched Stream (Lossless) | Streamed |
| **Resolution** | Push Interval (e.g. 30s) | Poll Interval (e.g. 1s) | 1s (standard) |
| **Counters** | Raw Counter | Calculated Rate (Edge) | Interpolated Rate (Edge) |

## Future Work: Time Alignment (Phase 2)
Once buffering is in place, we can implement "Interpolation" to align messy poll timestamps to a perfect grid (e.g. exactly on the second), handling jitter and missed polls gracefully. This is a key feature of Netdata that allows clean overlaying of metrics from different sources.
