# Tasks: Add Interface Metrics Discovery

## 1. Protocol Buffer Updates
- [x] 1.1 Define `InterfaceMetric` message in `proto/discovery/discovery.proto`
- [x] 1.2 Add `repeated InterfaceMetric available_metrics` to `DiscoveredInterface` message
- [x] 1.3 Regenerate Go and Elixir protobuf bindings

## 2. Go Mapper Enhancement
- [x] 2.1 Define standard interface OID constants in `pkg/mapper/snmp_polling.go`
- [x] 2.2 Add `AvailableMetrics` field to `DiscoveredInterface` struct in `types.go`
- [x] 2.3 Create `probeInterfaceMetrics()` function to test OID availability
- [x] 2.4 Integrate metric probing into `queryInterfaces()` flow
- [x] 2.5 Add 64-bit counter detection (ifHC* OIDs)
- [x] 2.6 Handle SNMP Get failures gracefully (mark metric as unavailable)
- [ ] 2.7 Add unit tests for metric probing logic

## 3. Elixir Schema Changes
- [x] 3.1 Add `available_metrics` attribute to Interface resource (JSONB array)
- [x] 3.2 Generate Ash migration for new attribute
- [x] 3.3 Update `MapperResultsIngestor.normalize_interface()` to extract metrics
- [ ] 3.4 Add tests for ingestion of available_metrics field

## 4. UI Updates
- [x] 4.1 Update interface details page to display available metrics
- [x] 4.2 Create `available_metric_card` component to display metrics
- [x] 4.3 Add category icons and labels for metric types
- [x] 4.4 Show "64-bit" badge when 64-bit counters available
- [x] 4.5 Show "Available metrics unknown" when no discovery data

## 5. Integration & Testing
- [ ] 5.1 Add integration test for full discovery-to-UI flow
- [ ] 5.2 Test with devices that support only 32-bit counters
- [ ] 5.3 Test with devices that support 64-bit counters
- [x] 5.4 Verify backward compatibility with existing interfaces (null available_metrics)
- [x] 5.5 Run `make lint` and `make test`
