## 1. Implementation

- [x] 1.1 Create shared `ServiceRadar.Graph` module in serviceradar_core
- [x] 1.2 Update `TopologyGraph` to use `ServiceRadar.Graph.execute/2`
- [x] 1.3 Update `web-ng/Graph` to delegate to `ServiceRadar.Graph`

## 2. Verification

- [x] 2.1 Verify serviceradar_core compiles without errors
- [x] 2.2 Verify web-ng compiles without errors
- [ ] 2.3 Integration test with running docker stack
- [ ] 2.4 Confirm no `agtype` Postgrex errors in logs
