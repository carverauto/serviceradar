# Change: Fix core OOM crashes from AGE graph queue memory pressure

## Why
Core in the demo namespace is being OOMKilled (4 restarts in 8 hours) despite having 4Gi memory allocated. Investigation reveals a memory leak pattern in the AGE graph writer:

1. **Queue backlog builds up**: Queue depth reaches 38-39 items with 120+ second wait times
2. **Single worker bottleneck**: Default `AGE_GRAPH_WORKERS=1` processes batches in 5-8 seconds each, cannot drain incoming work
3. **Large sync payloads**: ~24MB messages with 16,384 device updates processed every ~5 minutes
4. **Memory accumulates in goroutines**: Each `enqueue()` call creates a goroutine that waits on a result channel for up to 2 minutes, holding payload data in memory
5. **Retry amplification**: Failed batches retry 3x with backoff, extending memory retention
6. **No memory-aware backpressure**: Queue accepts work until full (512 items) regardless of memory pressure

The result is memory grows from 3.3Gi toward 4Gi until the kernel OOMKills the process.

## What Changes
- Increase default AGE graph workers from 1 to 4 to improve queue drain rate
- Add memory-aware backpressure that rejects new batches when memory usage exceeds a threshold (e.g., 80% of limit)
- Implement fire-and-forget mode for non-critical graph updates to avoid goroutine accumulation
- Add circuit breaker pattern to temporarily disable graph writes when AGE is overloaded
- Expose memory usage and queue pressure metrics for alerting
- Consider payload size limits or chunking for very large sync batches (>16K devices)

## Impact
- Affected specs: device-relationship-graph
- Affected code: pkg/registry/age_graph_writer.go, pkg/registry/age_graph_metrics.go, pkg/core/registry_handler.go
- K8s config: Consider increasing memory limits or adding memory monitoring alerts
