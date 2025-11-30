## 1. Add ServiceTypes for Core Services

- [ ] 1.1 Add `ServiceTypeDatasvc ServiceType = "datasvc"` to `pkg/models/service_device.go`
- [ ] 1.2 Add `ServiceTypeKV ServiceType = "kv"` (alias for datasvc legacy name)
- [ ] 1.3 Add `ServiceTypeSync ServiceType = "sync"`
- [ ] 1.4 Add `ServiceTypeMapper ServiceType = "mapper"`
- [ ] 1.5 Add `ServiceTypeOtel ServiceType = "otel"`
- [ ] 1.6 Add `ServiceTypeZen ServiceType = "zen"`
- [ ] 1.7 Add `CreateCoreServiceDeviceUpdate()` helper similar to `CreatePollerDeviceUpdate()`

## 2. Core Service Registration with Service Device IDs

- [ ] 2.1 Update datasvc/KV service to register using `serviceradar:datasvc:instance-name` device ID
- [ ] 2.2 Update sync service to register using `serviceradar:sync:instance-name` device ID
- [ ] 2.3 Update mapper service to register using `serviceradar:mapper:instance-name` device ID
- [ ] 2.4 Update otel service to register using `serviceradar:otel:instance-name` device ID
- [ ] 2.5 Update zen service to register using `serviceradar:zen:instance-name` device ID
- [ ] 2.6 Ensure each service includes its host IP in the device update (even if ephemeral)

## 3. Fix Checker Device Registration

- [ ] 3.1 Modify `ensureServiceDevice` in `pkg/core/devices.go`:
  - Extract `target_address` or `endpoint` from checker service data
  - Only create device for the TARGET address, not the checker's `host_ip`
- [ ] 3.2 Add `extractCheckerTargetAddress()` helper to get the monitoring target from service data
- [ ] 3.3 Add logic to detect when `host_ip` matches the registered agent/poller IP
- [ ] 3.4 Skip device creation when the extracted IP is the collector's own address

## 4. Agent/Poller IP Tracking for Collector Detection

- [ ] 4.1 Store agent's current IP in service registry metadata
- [ ] 4.2 Add `getAgentCurrentIP(agentID string) string` helper
- [ ] 4.3 In `ensureServiceDevice`, check if extracted `host_ip` equals agent's registered IP
- [ ] 4.4 If match, log debug message and skip device creation (it's the collector, not target)

## 5. Database Cleanup for Existing Phantom Devices

- [ ] 5.1 Write SQL query to identify phantom devices:
  ```sql
  SELECT * FROM unified_devices
  WHERE metadata->>'source' = 'checker'
    AND (hostname IS NULL OR hostname IN ('agent', 'poller', ''))
    AND ip ~ '^172\.(17|18|19)\.'  -- Docker bridge ranges
    AND device_id NOT LIKE 'serviceradar:%'
  ```
- [ ] 5.2 Create migration to soft-delete identified phantom devices (`_deleted: true`)
- [ ] 5.3 Verify legitimate service devices are NOT affected

## 6. Testing

- [ ] 6.1 Unit test: `CreateCoreServiceDeviceUpdate()` generates correct service device ID
- [ ] 6.2 Unit test: Service device ID survives IP change (same device_id, updated IP)
- [ ] 6.3 Unit test: `extractCheckerTargetAddress()` extracts target from service data
- [ ] 6.4 Integration test: Agent restart with new IP updates existing device, no duplicate
- [ ] 6.5 Integration test: gRPC checker creates device for target only, not collector host
- [ ] 6.6 Integration test: Core services (datasvc, sync, etc.) appear in device inventory
- [ ] 6.7 Negative test: Cleanup does NOT delete serviceradar:* devices

## 7. Verification

- [ ] 7.1 Verify agents appear in device inventory with `serviceradar:agent:*` IDs
- [ ] 7.2 Verify pollers appear in device inventory with `serviceradar:poller:*` IDs
- [ ] 7.3 Verify core services appear in device inventory with their service device IDs
- [ ] 7.4 Verify checker targets (e.g., sysmon-vm at 192.168.1.218) appear correctly
- [ ] 7.5 Verify NO phantom devices with Docker bridge IPs and hostname "agent"
