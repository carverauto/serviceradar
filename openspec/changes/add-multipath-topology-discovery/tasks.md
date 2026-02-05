## 1. Research & Design
- [ ] 1.1 Review Diamond-Miner paper and Python implementation for core algorithm details.
- [ ] 1.2 Design the Go implementation for the multipath probing engine.
- [ ] 1.3 Define the schema changes for `TopologyLink` and Apache AGE.

## 2. Agent Implementation (Go)
- [ ] 2.1 Implement the multipath probing logic in `pkg/scan`.
- [ ] 2.2 Add `DiscoveryTypeMultipath` to `pkg/mapper/types.go`.
- [ ] 2.3 Implement the `DiscoveryTypeMultipath` handler in `pkg/mapper/discovery.go`.
- [ ] 2.4 Update `serviceradar-agent` to support the new discovery parameters.

## 3. Core & API Implementation (Elixir)
- [ ] 3.1 Update the `DiscoveryJob` Ash resource to support multipath parameters.
- [ ] 3.2 Update the topology ingestion logic to handle multipath links.
- [ ] 3.3 Update the Apache AGE projection logic to support multiple edges with flow metadata.

## 4. UI Implementation (Phoenix/LiveView)
- [ ] 4.1 Update the Discovery Job configuration UI to support multipath discovery.
- [ ] 4.2 Update the Network Graph visualization to represent multipath links.

## 5. Testing & Verification
- [ ] 5.1 Write unit tests for the multipath probing engine.
- [ ] 5.2 Perform integration tests with a simulated multipath network environment.
- [ ] 5.3 Verify data projection into Apache AGE.
