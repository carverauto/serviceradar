# Change: Fix sweep availability flapping and missing response times

## Why

Two critical bugs are affecting sweep results reliability:

1. **Device availability flapping (GH-2381)**: Devices intermittently flip between available/unavailable status across sweep cycles, even with a single agent.

2. **Missing response times (GH-2618)**: ICMP response times are not being captured or preserved when sweep results are processed, showing 0ms for most results.

## Root Cause Analysis

### Primary Issue: Unreliable ICMP Scanning

The ICMP scanner (`pkg/scan/icmp_scanner_unix.go`) sends **only ONE ICMP echo request per target**:

```go
Body: &icmp.Echo{
    ID:   s.identifier,
    Seq:  1,              // Only sequence 1 - single packet!
    Data: []byte("ping"),
}
```

If this single packet is dropped (normal in any network), the host is immediately marked unavailable with 100% packet loss. This explains the intermittent flapping even with a single agent.

**Compounding factors:**
- Network congestion can drop the single ICMP packet
- Container environments may have ICMP capability issues
- The 5-second timeout may not be sufficient for some networks
- Response time is only captured if the reply is received (0ms for unavailable hosts)

### Secondary Issue: Multi-Agent Conflicts (demo environment)

In the demo environment, two agents (`agent-dusk` and `k8s-agent`) are assigned to the same sweep group:
- `agent-dusk`: Finds ~30 hosts available (properly configured)
- `k8s-agent`: Finds only 2 hosts available (appears to lack ICMP capability or network access)
- Both agents overwrite each other's results

## What Changes

### 1. ICMP Reliability Improvements (Core Fix)
- Send **multiple ICMP packets per target** (configurable, default 3)
- Mark host as available if **any** reply is received
- Calculate packet loss percentage based on received/sent ratio
- Use **average response time** from all received replies
- Add configurable retry count and timeout per target

### 2. Response Time Preservation
- Ensure `icmp_response_time_ns` is properly parsed from sweep results
- Preserve existing response times when updating records if new value is 0/nil
- Store response time even for partial success (e.g., 1 of 3 packets received)

### 3. Sweep Result Conflict Prevention
- Add agent validation to detect configuration conflicts
- Log warnings when multiple agents submit results for the same sweep group
- Consider "available if ANY agent reports available" aggregation strategy

### 4. Availability Hysteresis
- Don't immediately mark a device unavailable after a single failed sweep
- Require **N consecutive failures** before marking unavailable (configurable)
- This prevents transient network issues from causing status flapping

## Impact

- Affected specs: `sweep-jobs`, `sweeper`
- Affected code:
  - `pkg/scan/icmp_scanner_unix.go` - Multi-packet ICMP implementation
  - `pkg/sweeper/base_processor.go` - Response time handling
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex` - Result processing
  - `elixir/serviceradar_core/lib/serviceradar/results_router.ex` - Field parsing
- Configuration: New options for ICMP count, retry behavior, hysteresis threshold
- **Breaking**: Default behavior changes from 1 to 3 ICMP packets per target
