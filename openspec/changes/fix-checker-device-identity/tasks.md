## 1. Add ServiceTypes for Core Services

- [x] 1.1 Add `ServiceTypeDatasvc ServiceType = "datasvc"` to `pkg/models/service_device.go`
- [x] 1.2 Add `ServiceTypeKV ServiceType = "kv"` (alias for datasvc legacy name)
- [x] 1.3 Add `ServiceTypeSync ServiceType = "sync"`
- [x] 1.4 Add `ServiceTypeMapper ServiceType = "mapper"`
- [x] 1.5 Add `ServiceTypeOtel ServiceType = "otel"`
- [x] 1.6 Add `ServiceTypeZen ServiceType = "zen"`
- [x] 1.7 Add `CreateCoreServiceDeviceUpdate()` helper similar to `CreatePollerDeviceUpdate()`
- [x] 1.8 Add `ServiceTypeCore ServiceType = "core"` for the core service

## 2. Core Service Registration with Service Device IDs

- [x] 2.1 Core now auto-detects datasvc service type and registers with `serviceradar:datasvc:instance-name` device ID
- [x] 2.2 Core now auto-detects sync service type and registers with `serviceradar:sync:instance-name` device ID
- [x] 2.3 Core now auto-detects mapper service type and registers with `serviceradar:mapper:instance-name` device ID
- [x] 2.4 Core now auto-detects otel service type and registers with `serviceradar:otel:instance-name` device ID
- [x] 2.5 Core now auto-detects zen service type and registers with `serviceradar:zen:instance-name` device ID
- [x] 2.6 Each core service includes its host IP in the device update via `registerCoreServiceDevice()`
- [x] 2.7 Added `getCoreServiceType()` to identify core services from service type string
- [x] 2.8 Added `findCoreServiceType()` to scan services list for core services
- [x] 2.9 Added `registerServiceOrCoreDevice()` helper to DRY device registration

## 3. Fix Checker Device Registration

- [x] 3.1 Modify `ensureServiceDevice` in `pkg/core/devices.go`:
  - Check if `host_ip` matches collector's registered IP
  - Skip device creation if it's the collector's own address
  - Add heuristic to detect ephemeral Docker IPs with agent/poller hostnames
- [x] 3.2 Add `getCollectorIP()` helper to look up agent/poller's registered IP
- [x] 3.3 Add `isEphemeralCollectorIP()` heuristic to detect phantom devices
- [x] 3.4 Add `isDockerBridgeIP()` helper to identify Docker bridge network IPs
- [x] 3.5 Add `extractIPFromMetadata()` helper to extract IP from service metadata

## 4. Agent/Poller IP Tracking for Collector Detection

- [x] 4.1 Use existing ServiceRegistry to look up agent/poller IPs
- [x] 4.2 Add `getCollectorIP(ctx, agentID, pollerID)` helper that queries ServiceRegistry and DB
- [x] 4.3 In `ensureServiceDevice`, check if extracted `host_ip` equals collector's registered IP
- [x] 4.4 If match, log debug message and skip device creation (it's the collector, not target)

## 5. Database Cleanup for Existing Phantom Devices

- [x] 5.1 Write SQL query to identify phantom devices (see migration file)
- [x] 5.2 Create migration `00000000000011_cleanup_phantom_devices.up.sql`:
  - Creates backup table `_phantom_devices_backup` before deletion
  - Identifies phantom devices by Docker bridge IPs + checker source + collector hostname
  - Preserves all `serviceradar:*` service devices
  - Deletes identified phantom devices
- [x] 5.3 Create rollback migration `00000000000011_cleanup_phantom_devices.down.sql`

## 6. Testing

- [x] 6.1 Unit test: `CreateCoreServiceDeviceUpdate()` generates correct service device ID
- [x] 6.2 Unit test: Service device ID survives IP change (same device_id, updated IP)
- [x] 6.3 Unit test: `isDockerBridgeIP()` correctly identifies Docker bridge IPs
- [x] 6.4 Unit test: `isEphemeralCollectorIP()` detects phantom collector devices
- [x] 6.5 Unit test: `extractIPFromMetadata()` extracts IP from various metadata keys
- [x] 6.6 Unit test: `ensureServiceDevice` skips device creation for ephemeral collector IPs
- [x] 6.7 Unit test: `ensureServiceDevice` creates devices for legitimate targets
- [x] 6.8 Unit test: `getCoreServiceType()` identifies all core service types
- [x] 6.9 Unit test: `findCoreServiceType()` scans service lists correctly
- [x] 6.10 Unit test: `registerCoreServiceDevice()` creates stable device IDs
- [x] 6.11 Unit test: `registerServiceOrCoreDevice()` routes to correct registration
- [x] 6.12 Unit test: Core service device ID format verification
- [ ] 6.13 Integration test: Agent restart with new IP updates existing device, no duplicate
- [ ] 6.14 Integration test: Core services (datasvc, sync, etc.) appear in device inventory

## 7. Verification

- [ ] 7.1 Verify agents appear in device inventory with `serviceradar:agent:*` IDs
- [ ] 7.2 Verify pollers appear in device inventory with `serviceradar:poller:*` IDs
- [ ] 7.3 Verify core services appear in device inventory with their service device IDs
- [ ] 7.4 Verify checker targets (e.g., sysmon-vm at 192.168.1.218) appear correctly
- [ ] 7.5 Verify NO phantom devices with Docker bridge IPs and hostname "agent"
