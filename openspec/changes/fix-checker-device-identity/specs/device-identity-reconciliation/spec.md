## ADDED Requirements
### Requirement: Service Device ID as Strong Identifier
The system SHALL use service device IDs (`serviceradar:type:id` format) as strong identifiers for all ServiceRadar internal infrastructure services, allowing IP addresses to change without creating duplicate device records.

#### Scenario: Agent IP changes after container restart
- **WHEN** agent `docker-agent` with device ID `serviceradar:agent:docker-agent` restarts and gets a new IP from `172.18.0.5` to `172.18.0.8`
- **THEN** the system updates the existing device record's IP field without creating a new device, because the service device ID is the strong identifier

#### Scenario: Poller IP changes in Kubernetes
- **WHEN** poller `k8s-poller` with device ID `serviceradar:poller:k8s-poller` is rescheduled to a different node with a new pod IP
- **THEN** the existing device record is updated with the new IP, maintaining continuity of the device's history and metrics

#### Scenario: DIRE skips IP-based resolution for service devices
- **WHEN** a device update arrives with a `serviceradar:` prefixed device ID
- **THEN** the Device Identity Reconciliation Engine (DIRE) skips IP-based deduplication and resolution, preserving the service device ID as-is

### Requirement: Core Service Registration with Service Device IDs
All ServiceRadar core services (datasvc/kv, sync, mapper, otel, zen) SHALL register themselves using service device IDs so they appear in device inventory with stable identities that survive IP changes.

#### Scenario: Datasvc registers as service device
- **WHEN** the datasvc (KV) service starts and reports its status
- **THEN** it registers with device ID `serviceradar:datasvc:instance-name` and its current host IP, appearing in device inventory as an internal service

#### Scenario: Sync service registers as service device
- **WHEN** the sync service starts and reports its status
- **THEN** it registers with device ID `serviceradar:sync:instance-name` and its current host IP

#### Scenario: Core service survives IP change
- **WHEN** any core service (datasvc, sync, mapper, otel, zen) restarts with a new ephemeral IP
- **THEN** the existing device record is updated rather than creating a duplicate, because the service device ID remains constant

### Requirement: Checker Target vs Collector Host Distinction
The system SHALL distinguish between the collector host (where the checker runs) and the monitoring target (what the checker monitors), only creating device records for monitoring targets.

#### Scenario: gRPC checker polls remote sysmon target
- **WHEN** a gRPC checker running on agent `docker-agent` at IP `172.18.0.5` polls sysmon-vm at target IP `192.168.1.218`
- **THEN** the system creates a device record only for the target `192.168.1.218` and does NOT create a device record for the collector IP `172.18.0.5` based on the checker result

#### Scenario: SNMP collector polls remote target
- **WHEN** an SNMP collector running on poller at `172.18.0.6` polls metrics from target `192.168.1.1`
- **THEN** the system creates a device record only for `192.168.1.1` and does NOT create a device for the collector IP

#### Scenario: Checker host IP matches agent IP
- **WHEN** a checker reports `host_ip: 172.18.0.5` and that IP matches the registered agent's current IP
- **THEN** the system recognizes this as the collector's own address and skips device creation for that IP from the checker result

### Requirement: Checker Definitions and Results Are Not Devices
The system SHALL NOT create unified device records or sightings from checker definitions in poller configuration or from checker host metadata; only the monitoring targets themselves may become devices.

#### Scenario: Poller checker definition is ignored
- **WHEN** `poller.json` defines a checker service (e.g., `checker_service: sysmon-vm`, `checker_service_type: grpc`, `checker_host_ip: 172.18.0.5`)
- **THEN** no unified device or device sighting is created from that checker definition; device creation is limited to actual monitoring targets discovered at runtime

#### Scenario: Checker host result is ignored
- **WHEN** a checker result is received with `checker_host_ip: 172.18.0.5`, `checker_service: sysmon-vm`, and `source: checker` for collector `docker-agent`
- **THEN** the system skips device creation for that host IP and service ID, ensuring the existing target device (e.g., sysmon-vm) remains the only device in inventory

### Requirement: Internal Service Type Registry
The system SHALL maintain a registry of ServiceTypes for internal services that use service device ID format.

#### Scenario: ServiceType constants for core services
- **WHEN** the system is initialized
- **THEN** ServiceType constants exist for: `poller`, `agent`, `checker`, `datasvc`, `kv`, `sync`, `mapper`, `otel`, `zen`

#### Scenario: isServiceDeviceID check
- **WHEN** determining if a device ID is for an internal service
- **THEN** the system checks if the ID starts with `serviceradar:` prefix to identify service device IDs

### Requirement: Heuristic Fallback for Phantom Device Detection
When the collector IP cannot be determined from the ServiceRegistry, the system SHALL use heuristics to detect phantom devices based on Docker bridge network IPs and collector-like hostnames.

#### Scenario: Docker bridge IP with agent hostname
- **WHEN** a checker reports `host_ip: 172.18.0.5` with hostname containing "agent"
- **AND** the ServiceRegistry lookup returns empty (collector IP unknown)
- **THEN** the system identifies this as an ephemeral collector IP and skips device creation

#### Scenario: Docker bridge IP with proper target hostname
- **WHEN** a checker reports `host_ip: 172.18.0.10` with hostname `mysql-primary`
- **THEN** the system creates a device record because the hostname indicates a legitimate target, not a collector

#### Scenario: Non-Docker IP with agent hostname
- **WHEN** a checker reports `host_ip: 192.168.1.100` with hostname `my-agent-server`
- **THEN** the system creates a device record because the IP is not in Docker bridge ranges

#### Scenario: Docker IP boundary conditions
- **WHEN** the system evaluates IP addresses
- **THEN** it identifies IPs in ranges 172.17.0.0-172.21.255.255 as Docker bridge network IPs
- **AND** IPs like 172.16.x.x or 172.22.x.x are NOT considered Docker bridge IPs

### Requirement: Database Cleanup Migration for Phantom Devices
The system SHALL provide a database migration to clean up existing phantom devices while preserving legitimate service device records.

#### Scenario: Migration backs up phantom devices before deletion
- **WHEN** the cleanup migration runs
- **THEN** it creates a backup table `_phantom_devices_backup` containing all devices to be deleted
- **AND** then deletes the phantom devices from `unified_devices`

#### Scenario: Migration preserves service device IDs
- **WHEN** the cleanup migration identifies phantom devices
- **THEN** it excludes all devices with `device_id LIKE 'serviceradar:%'` from deletion

#### Scenario: Migration rollback restores deleted devices
- **WHEN** the rollback migration runs
- **THEN** it restores all devices from `_phantom_devices_backup` to `unified_devices`
- **AND** drops the backup table

#### Scenario: Phantom device identification criteria
- **WHEN** the migration identifies phantom devices
- **THEN** it matches devices with:
  - IP in Docker bridge ranges (172.17-21.x.x)
  - Source is 'checker' or 'self-reported'
  - Hostname is NULL, empty, 'unknown', 'localhost', or contains 'agent', 'poller', 'collector'
