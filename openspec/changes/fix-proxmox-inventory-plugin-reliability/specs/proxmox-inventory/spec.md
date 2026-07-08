# Proxmox Inventory

## ADDED Requirements

### Requirement: Inventory runs complete within the config-poll window
The core config-delivery pipeline SHALL NOT re-version and re-push an agent's
config unless a meaningful change occurred, so a long-running plugin inventory
run is not relaunched mid-execution.

#### Scenario: Stable config is not re-pushed
- **GIVEN** an agent running the proxmox-inventory plugin whose assignments,
  secrets, and other config inputs have not meaningfully changed
- **WHEN** the config generator runs on a dependency write or poll
- **THEN** the computed config version is unchanged
- **AND** the agent is not sent a new config
- **AND** the running plugin module is not closed/relaunched

### Requirement: Devices are only created when an IP is known
The proxmox-inventory plugin SHALL only emit a guest or node as a discovered
device when a usable IP address was resolved.

#### Scenario: Stopped guest with no address
- **GIVEN** a stopped VM with no static `netN`/`ipconfigN` address and no running
  guest agent
- **WHEN** the plugin enumerates the cluster
- **THEN** no IP-less device is created for that guest
- **AND** the guest is still recorded in the enrichment `details`

#### Scenario: Running guest with an address
- **GIVEN** a running VM with IP `192.168.2.22` (via config or guest agent)
- **WHEN** the plugin enumerates the cluster
- **THEN** exactly one device is emitted for the guest with IP `192.168.2.22`

### Requirement: Guest and node runtime status is accurate
The plugin SHALL report a guest's/node's true runtime status and availability.

#### Scenario: Stopped guest is not reported running
- **GIVEN** a guest whose Proxmox `qmpstatus`/`status` is `stopped`
- **WHEN** the plugin emits its device
- **THEN** the device's status is `stopped` and `IsAvailable` is false

### Requirement: Deterministic guest and node identity
The plugin SHALL emit one canonical device identity per guest and per node, plus
the guest MAC(s) as identifiers, so DIRE reconciles duplicate discoveries.

#### Scenario: Same guest discovered by multiple integrations
- **GIVEN** a guest discovered by the agent, the proxmox integration, and AWX
- **WHEN** the discoveries are ingested
- **THEN** DIRE reconciles them into a single device
- **AND** the device is not duplicated as separate name-based and MAC-based rows
