# Sweep Results Polling Interval Configuration

## Problem

When running ServiceRadar with a large number of devices (e.g., 6000 devices), frequent polling of sweep results from the sync service can overwhelm the core service and database. The logs show:

```
Jul 15 05:32:37 demo-staging serviceradar-core[46298]: 2025/07/15 05:32:37 DEBUG [database]: StoreSweepResults called with 41 results
Jul 15 05:33:07 demo-staging serviceradar-core[46298]: 2025/07/15 05:33:07 DEBUG [database]: StoreSweepResults called with 34 results
```

This indicates that sweep results are being fetched and stored every 30 seconds, which is too frequent for production environments with thousands of devices.

## Root Cause

The issue occurs when:

1. The core/poller service is configured to poll the sync service for sweep results via gRPC
2. The sync service has a `ResultsPoller` configured with a short `results_interval` (e.g., 30 seconds)
3. Each poll returns all cached sweep results, causing frequent database writes

The frequent polling is controlled by the `results_interval` field in the poller configuration for gRPC services.

## Solution

### 1. Configure Longer Results Interval

In your poller configuration (`poller.json`), set a longer `results_interval` for sync services:

```json
{
  "agents": {
    "local-agent": {
      "checks": [
        {
          "service_type": "grpc",
          "service_name": "sync",
          "details": "127.0.0.1:50058",
          "results_interval": "10m"
        }
      ]
    }
  }
}
```

### 2. Recommended Intervals by Environment

- **Development/Testing**: `1m` - `2m`
- **Small Production (< 1000 devices)**: `5m` - `10m`
- **Large Production (> 1000 devices)**: `10m` - `30m`
- **Enterprise (> 5000 devices)**: `30m` - `1h`

### 3. Configuration Fields

- `results_interval`: Controls how often the poller calls `GetResults` on the sync service
- `poll_interval`: Controls the base polling frequency for status checks (separate from results)
- `sweep_interval`: In sync service config, controls how often sweep operations are performed

## Files Modified

1. `packaging/poller/config/poller.json` - Added sync service with 10m results_interval
2. `configs/examples/poller-with-sync.json` - Example configuration with proper interval

## Verification

After applying the configuration:

1. Check poller logs for sync results frequency:
   ```bash
   journalctl -u serviceradar-poller -f | grep "GetResults"
   ```

2. Monitor core database logs:
   ```bash
   journalctl -u serviceradar-core -f | grep "StoreSweepResults"
   ```

3. Verify the interval matches your configuration (should see results polling every 10 minutes instead of every 30 seconds)

## Performance Impact

With 6000 devices and a 10-minute interval:
- **Before**: 6000 devices × 120 polls/hour = 720,000 database operations/hour
- **After**: 6000 devices × 6 polls/hour = 36,000 database operations/hour
- **Reduction**: 95% fewer database operations

This significantly reduces CPU and I/O load on both the core service and database.