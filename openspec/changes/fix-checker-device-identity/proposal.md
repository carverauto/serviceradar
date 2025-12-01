# Change: Fix Checker Device Identity Resolution

## Why
Checkers (sysmon, SNMP collectors, etc.) running on agents/pollers are incorrectly creating device records for the collector's ephemeral host IP (e.g., Docker container IP `172.18.0.5`) instead of only creating devices for the actual monitored targets (e.g., sysmon-vm at `192.168.1.218`). This results in phantom devices appearing in the device inventory UI with hostnames like "agent" and ephemeral container IPs.

**Important:** ServiceRadar internal infrastructure services (agents, pollers, datasvc/kv, sync, mapper, otel, zen) MUST continue to appear as devices in inventory - these are self-reported services that users need to monitor for health/availability.

## What Changes

### Leverage Existing DIRE Infrastructure
The Device Identity Reconciliation Engine (DIRE) already has the concept of **service device IDs** (`serviceradar:type:id`) which act as strong identifiers that:
- Are stable across IP changes (the ID is based on service name, not IP)
- Skip IP-based deduplication and resolution
- Allow services to update their IP when containers restart without creating duplicate devices

**Key insight:** Internal services should use `serviceradar:type:id` format IDs, which the existing DIRE system already handles correctly for IP churn.

### Changes Required

1. **Add new ServiceTypes for core services** in `pkg/models/service_device.go`:
   - `ServiceTypeDatasvc` / `ServiceTypeKV`
   - `ServiceTypeSync`
   - `ServiceTypeMapper`
   - `ServiceTypeOtel`
   - `ServiceTypeZen`

2. **Ensure core services register using service device IDs**:
   - When datasvc, sync, mapper, otel, zen report status, they should use `serviceradar:datasvc:instance-name` format
   - This leverages existing DIRE skip logic: `isServiceDeviceID()` returns true, DIRE skips IP-based resolution

3. **Fix `ensureServiceDevice` in `pkg/core/devices.go`**:
   - Currently creates devices with `partition:IP` format for checker hosts
   - Should distinguish between:
     - **Self-reported internal service** → use `serviceradar:type:id` format (handled by existing code paths)
     - **Checker polling external target** → only create device for the TARGET IP, not the checker's host IP
   - Extract target address from checker config/service data and only create device for that target

4. **Skip device creation for checker's own host IP**:
   - When processing gRPC checker results, detect if `host_ip` matches the agent/poller's registered IP
   - If so, skip device creation for that IP (it's the collector, not the target)

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `pkg/models/service_device.go` (add new ServiceTypes)
  - `pkg/core/devices.go` (`ensureServiceDevice`, extract target vs collector host)
  - Core services registration (datasvc, sync, mapper, otel, zen) to use service device IDs

## Implementation Status

### Completed (Unit Tested)

#### 1. ServiceTypes for Core Services (`pkg/models/service_device.go`)
- Added `ServiceTypeDatasvc`, `ServiceTypeKV`, `ServiceTypeSync`, `ServiceTypeMapper`, `ServiceTypeOtel`, `ServiceTypeZen`, `ServiceTypeCore`
- Added `CreateCoreServiceDeviceUpdate()` helper in `pkg/models/service_registration.go`

#### 2. Core Service Registration (`pkg/core/services.go`)
- `getCoreServiceType()` - identifies core services from service type string
- `findCoreServiceType()` - scans services list for core services
- `registerCoreServiceDevice()` - registers core service with stable device ID
- `registerServiceOrCoreDevice()` - routes to correct registration path

#### 3. Fix Checker Device Registration (`pkg/core/devices.go`)
- Modified `ensureServiceDevice()` to detect and skip collector IPs
- `getCollectorIP()` - looks up agent/poller IP from ServiceRegistry
- `isEphemeralCollectorIP()` - heuristic fallback for phantom detection
- `isDockerBridgeIP()` - identifies Docker bridge network IPs (172.17-21.x.x)
- `extractIPFromMetadata()` - extracts IP from service metadata

#### 4. Database Migration (`pkg/db/cnpg/migrations/`)
- `00000000000011_cleanup_phantom_devices.up.sql` - removes phantom devices with backup
- `00000000000011_cleanup_phantom_devices.down.sql` - restores from backup

#### 5. Test Coverage
- 21 unit tests covering all new functionality
- Tests in `pkg/core/devices_test.go`, `pkg/core/services_core_test.go`, `pkg/models/service_device_test.go`
- Edge cases: IP normalization, Docker IP boundaries, hostname case sensitivity, nil registries
- Safety tests: service device IDs excluded from phantom cleanup, legitimate Docker targets preserved

### Pending (Integration/Manual Verification)
- Integration test: Agent restart with new IP updates existing device
- Integration test: Core services appear in device inventory
- Manual verification of device inventory in production environment
