## 1. Immediate mitigations
- [x] 1.1 Increase `AGE_GRAPH_WORKERS` default from 1 to 4 to improve queue drain rate
- [x] 1.2 Reduce `AGE_GRAPH_QUEUE_SIZE` default from 512 to 256 to limit memory footprint
- [x] 1.3 Add memory usage metrics (Go runtime memstats) to core prometheus endpoint

## 2. Memory-bounded queueing
- [x] 2.1 Add `AGE_GRAPH_MEMORY_LIMIT_MB` config that triggers early rejection when Go heap exceeds threshold
- [x] 2.2 Implement non-blocking enqueue mode that drops batches instead of waiting when queue is full
- [x] 2.3 Add metrics for dropped/rejected batches to distinguish memory pressure from AGE failures

## 3. Payload optimization
- [x] 3.1 Existing chunking (128 items per batch via `AGE_GRAPH_CHUNK_SIZE`) is sufficient
- [ ] 3.2 Consider streaming/incremental processing for sync service messages instead of loading entire 24MB payload
- [ ] 3.3 Add payload size metrics to track large message patterns

## 4. Circuit breaker pattern
- [x] 4.1 Implement circuit breaker that temporarily disables graph writes after N consecutive failures
- [x] 4.2 Add half-open state that tests recovery with single batch before re-enabling
- [x] 4.3 Log circuit state changes and expose as metric/health check

## 5. Validation
- [x] 5.1 Deploy to demo namespace and verify no OOMKilled restarts over 24 hours
- [ ] 5.2 Confirm graph data continues to be written during steady-state operation
- [ ] 5.3 Verify metrics expose memory pressure and queue depth accurately
