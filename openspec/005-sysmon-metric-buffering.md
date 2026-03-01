# Proposal 005: Sysmon Metric Buffering & Normalization

## Status
Implemented

## Context
Following the implementation of Proposal 004 (SNMP Buffering), we have identified that System Monitor (Sysmon) metrics suffer from the same data loss and aliasing issues.

Currently, `SysmonService` collects metrics periodically (e.g., every 1s or 5s) but `PushLoop` only snapshots the `Latest()` sample every 30s. This means intermediate CPU spikes, memory peaks, and disk I/O bursts are discarded.

## Goals
1.  **Lossless System Monitoring:** Transmit all collected `MetricSample`s to the backend.
2.  **Consistency:** Align `sysmon` architecture with the new `snmp` buffering architecture.
3.  **High-Fidelity Observability:** Enable per-second resolution for critical system resources.

## Proposed Design

### 1. Buffer Integration
We will reuse the generic `RingBuffer` from `pkg/agent/core` to buffer `sysmon.MetricSample` structs.

### 2. Sysmon Collector Update
The `sysmon.Collector` interface will be updated to include a drain method or the buffering will be handled in `SysmonService`. Since `DefaultCollector` runs its own loop, it is better to have it buffer internally or expose a channel.

**Recommendation:** Update `SysmonService` to wrap the collector and handle buffering.
*   `SysmonService` subscribes to collector updates (or polls `Latest()` if the collector interface isn't changed to push).
*   *Better approach:* Update `sysmon.Collector` to store history.

Let's modify `sysmon.DefaultCollector` to use a `RingBuffer` internally instead of just `latest`.

```go
// pkg/sysmon/collector.go

type DefaultCollector struct {
    // ...
    buffer *core.RingBuffer[*MetricSample]
    // ...
}

// Collect() adds to buffer
// Drain() returns buffered samples
```

### 3. MetricProvider Interface
`SysmonService` will implement the `MetricProvider` interface (defined in `pkg/agent/snmp/interfaces.go` or moved to a shared location).

```go
// pkg/agent/sysmon_service.go

func (s *SysmonService) DrainMetrics(ctx context.Context) ([]*sysmon.MetricSample, error) {
    return s.collector.Drain()
}
```

### 4. PushLoop Integration
Update `PushLoop.pushSysmonStatus` to:
1.  Call `sysmonSvc.DrainMetrics()`.
2.  Batch all samples into the `GatewayServiceStatus` message (or multiple chunks if too large).

## Implementation Plan
1.  Add `Drain()` method to `sysmon.Collector` interface.
2.  Update `DefaultCollector` to use `core.RingBuffer`.
3.  Update `SysmonService` to expose `DrainMetrics`.
4.  Refactor `PushLoop` to consume drained metrics.

## Note on Payload Size
Sysmon payloads can be large (process lists). Buffering 30 seconds of process lists might be excessive.
*   **Optimization:** We might want to buffer CPU/Memory/Disk/Network every second, but Processes less frequently (or only send diffs).
*   **Phase 1:** Buffer everything.
*   **Phase 2 (Future):** Split "high-frequency" (metrics) vs "low-frequency" (processes) if payload size becomes an issue.

## Implementation Details (Completed)

1.  **Sysmon Collector**:
    *   Updated `sysmon.Collector` interface to include `Drain()`.
    *   Updated `DefaultCollector` to use `core.RingBuffer[*MetricSample]`.
    *   Every `Collect()` call now writes to the ring buffer.
2.  **Sysmon Service**:
    *   Implemented `DrainMetrics` in `SysmonService` to expose the buffered data.
3.  **PushLoop**:
    *   Updated `pushSysmonStatus` to use `DrainMetrics`.
    *   Configured to send *all* buffered samples as individual `GatewayServiceStatus` messages within the stream, ensuring no data loss.
4.  **Verification**:
    *   Added `pkg/agent/sysmon_drain_test.go` verifying that multiple samples are collected and drained even with fast sampling intervals (e.g., 10ms).