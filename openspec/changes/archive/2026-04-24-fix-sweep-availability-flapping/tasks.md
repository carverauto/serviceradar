## 1. Investigation and Design

- [x] 1.1 Analyze database to identify root cause of flapping
- [x] 1.2 Review ICMP scanner implementation (pkg/scan/icmp_scanner_unix.go)
- [x] 1.3 Identify single-packet-per-target as primary reliability issue
- [x] 1.4 Design multi-packet ICMP approach with configurable retry count

## 2. ICMP Scanner Reliability Improvements

- [x] 2.1 Add `ICMPCount` config option (default 3) to send multiple packets per target
- [x] 2.2 Modify `sendPingToTarget` to send `ICMPCount` packets with incrementing sequence numbers
- [x] 2.3 Track sent/received counts per host for packet loss calculation
- [x] 2.4 Calculate average response time from all received replies
- [x] 2.5 Mark host as available if ANY reply is received (not just all)
- [x] 2.6 Add logging for packet loss percentage when partial success

## 3. Response Time Fix

- [x] 3.1 Audit `response_time_ms` parsing in `ResultsRouter.build_sweep_result/3`
- [x] 3.2 Verify `icmp_response_time_ns` field name handling (snake_case vs camelCase)
- [x] 3.3 Add "preserve non-zero response time" logic in `bulk_insert_host_results`
- [x] 3.4 Store response time from partial success (e.g., 1 of 3 packets)

## 4. Availability Hysteresis (Anti-flapping)

- [x] 4.1 Add `unavailable_threshold` config (default 2 consecutive failures)
- [x] 4.2 Track consecutive failure count per device in sweep processing
- [x] 4.3 Only mark unavailable after threshold is exceeded
- [x] 4.4 Reset failure count on any successful sweep result

## 5. Multi-Agent Conflict Detection

- [x] 5.1 Add agent validation before processing sweep results
- [x] 5.2 Log warning when detecting results from unexpected agent
- [ ] 5.3 Consider "available if any agent reports available" aggregation
- [ ] 5.4 Document recommended configuration for multi-agent scenarios

## 6. Testing

- [ ] 6.1 Add unit tests for multi-packet ICMP logic
- [ ] 6.2 Test packet loss calculation with simulated drops
- [ ] 6.3 Test hysteresis threshold behavior
- [ ] 6.4 Integration test for response time preservation
- [ ] 6.5 Verify demo environment no longer shows flapping after deployment
