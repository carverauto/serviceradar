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

### Requirement: Internal Service Type Registry
The system SHALL maintain a registry of ServiceTypes for internal services that use service device ID format.

#### Scenario: ServiceType constants for core services
- **WHEN** the system is initialized
- **THEN** ServiceType constants exist for: `poller`, `agent`, `checker`, `datasvc`, `kv`, `sync`, `mapper`, `otel`, `zen`

#### Scenario: isServiceDeviceID check
- **WHEN** determining if a device ID is for an internal service
- **THEN** the system checks if the ID starts with `serviceradar:` prefix to identify service device IDs
