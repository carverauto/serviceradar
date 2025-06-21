## Product Requirements Document: ServiceRadar SNMP Discovery Engine

**Version:** 1.0
**Date:** 2024-07-15
**Author:** AI Assistant (based on user requirements)
**Status:** Proposed

**1. Overview**

ServiceRadar is a comprehensive network monitoring tool. To enhance its capabilities, we are introducing an SNMP-based discovery engine. This engine will be responsible for actively probing network devices using the Simple Network Management Protocol (SNMP) to gather detailed information about the devices themselves, their interfaces, and their interconnections. The ultimate goal is to use this discovered data to build and enrich a network knowledge graph in ArangoDB, enabling advanced analysis of network topology and relationships. This document outlines the requirements for the initial SNMP discovery engine.

**1.1 Purpose**
To design and implement an SNMP discovery engine that can:
*   Identify and profile network devices.
*   Discover detailed information about device interfaces.
*   Uncover Layer 2/3 neighbor relationships using LLDP and CDP.
*   Produce structured data suitable for ingestion into ServiceRadar's existing data pipeline (Timeplus Proton streams), which will subsequently feed into an ArangoDB graph database.

**1.2 Goals**
*   Develop a robust SNMP discovery module utilizing the `gosnmp` library.
*   Provide flexible seeding mechanisms for initiating discovery.
*   Collect comprehensive device, interface, and neighbor data.
*   Integrate seamlessly with ServiceRadar's data ingestion streams (`discovered_interfaces`, `topology_discovery_events`, and contribute to the `devices` stream).
*   Lay the foundation for building a rich network topology graph in ArangoDB.
*   Ensure the discovery process is configurable and manageable.

**1.3 Non-Goals**
*   Directly writing to ArangoDB (this will be handled by a separate sync service as per ADR-02, consuming data produced by this engine via Proton).
*   SNMP Trap handling (this is a separate data source).
*   SNMP Set operations or device configuration.
*   Real-time performance metric collection via SNMP (this PRD focuses on discovery; metric collection is handled by other ServiceRadar mechanisms, though discovered interfaces will be targets for such collection).
*   Discovery of end-hosts that are not SNMP-enabled (e.g., workstations, printers without SNMP).

**2. Target Users**

*   **Network Administrators/Engineers:** Will use the discovered topology and device information for troubleshooting, planning, and network visualization.
*   **SREs/Operations Teams:** Will leverage the enriched graph data for impact analysis and understanding service dependencies on network infrastructure.
*   **Security Analysts:** May use topology information to understand potential attack paths or device vulnerabilities.

**3. User Stories**

*   As a Network Admin, I want to provide a list of seed IP addresses or subnets so that the discovery engine can start identifying SNMP-enabled devices.
*   As a Network Admin, I want the discovery engine to retrieve system information (hostname, description, model, OS) from discovered devices so I can identify them.
*   As a Network Admin, I want the discovery engine to list all interfaces on a discovered device, including their names, descriptions, MAC addresses, operational status, and configured IP addresses, so I can understand device connectivity.
*   As a Network Admin, I want the discovery engine to use LLDP and CDP to identify directly connected neighbors of a device, so I can build a Layer 2 topology map.
*   As an SRE, I want the discovered device and interface data to be stored in Proton streams so that it can be processed and loaded into ArangoDB to build a network graph.
*   As an Operator, I want to configure SNMP community strings and v3 credentials globally and/or per target, so the engine can authenticate to devices.
*   As an Operator, I want the discovery process to be logged, including errors and successfully discovered devices, so I can monitor its operation.

**4. Functional Requirements**

**4.1 SNMP Communication Core (gosnmp)**
*   FR1.1: Support SNMP v2c (Community Strings).
*   FR1.2: Support SNMP v3 (AuthNoPriv, AuthPriv with MD5/SHA for authentication and DES/AES for privacy).
*   FR1.3: Configurable timeouts and retries for SNMP requests.
*   FR1.4: Ability to perform SNMP GET, GETNEXT, and WALK operations.

**4.2 Seeding Mechanism**
*   FR2.1: Allow manual configuration of seed IP addresses.
*   FR2.2: Allow manual configuration of seed IP subnets/ranges (e.g., 192.168.1.0/24).
*   FR2.3: (Future Enhancement) Optionally, consume potential targets from the existing `devices` stream in Proton, where `is_available` is true and `discovery_source` is not 'snmp_detailed'.
*   FR2.4: Configuration for seeding should be manageable (e.g., via a JSON configuration file or KV store as per ADR-01).

**4.3 Data Collection Scope**
*   FR3.1: **System Information:**
    *   `sysDescr` (SNMPv2-MIB::sysDescr.0)
    *   `sysObjectID` (SNMPv2-MIB::sysObjectID.0)
    *   `sysName` (SNMPv2-MIB::sysName.0)
    *   `sysUpTime` (SNMPv2-MIB::sysUpTimeInstance)
    *   `sysContact` (SNMPv2-MIB::sysContact.0)
    *   `sysLocation` (SNMPv2-MIB::sysLocation.0)
*   FR3.2: **Interface Information (from IF-MIB, IF-XTABLE):** For each interface:
    *   `ifIndex` (IF-MIB::ifIndex)
    *   `ifDescr` (IF-MIB::ifDescr) - Physical port name or description.
    *   `ifName` (IF-MIB::ifName) - Name of the interface.
    *   `ifAlias` (IF-MIB::ifAlias) - User-defined alias.
    *   `ifType` (IF-MIB::ifType) - e.g., ethernetCsmacd, softwareLoopback.
    *   `ifSpeed` (IF-MIB::ifSpeed) - Current bandwidth in bits per second.
    *   `ifPhysAddress` (IF-MIB::ifPhysAddress) - MAC address.
    *   `ifAdminStatus` (IF-MIB::ifAdminStatus) - Desired state (up, down, testing).
    *   `ifOperStatus` (IF-MIB::ifOperStatus) - Current operational state.
    *   Associated IP Addresses (from IP-MIB::ipAddrTable - `ipAdEntAddr`, `ipAdEntNetMask` linked by `ipAdEntIfIndex`).
*   FR3.3: **Neighbor Information (Topology):**
    *   **LLDP (LLDP-MIB):**
        *   `lldpLocPortId`, `lldpLocSysName`
        *   `lldpRemTable`: `lldpRemChassisId`, `lldpRemPortId`, `lldpRemPortDesc`, `lldpRemSysName`, `lldpRemSysDesc`, `lldpRemManAddrIfId`, `lldpRemManAddr`.
    *   **CDP (CISCO-CDP-MIB or similar):**
        *   `cdpCacheTable`: `cdpCacheAddress` (neighbor's IP), `cdpCacheVersion`, `cdpCacheDeviceId` (neighbor's hostname), `cdpCacheDevicePort` (neighbor's remote port), `cdpCachePlatform`.
*   FR3.4: **Basic Device Reachability:** The engine should confirm SNMP connectivity to a device before attempting detailed discovery. This can update/create an entry in `snmp_results`.

**4.4 Data Output and Storage (Proton Integration)**
*   FR4.1: Successfully discovered basic device information (sysName, IP, MAC (if found as a system-level MAC)) should contribute to the `devices` stream in Proton. The `discovery_source` should be marked as 'mapper'.
    *   This may involve publishing to an intermediate stream like `snmp_device_candidates` or directly enhancing entries in `snmp_results` which then feeds `unified_devices_mv`.
*   FR4.2: Detailed interface information (as per FR3.2) for each discovered device must be published to the `discovered_interfaces` Proton stream. Data must conform to the existing schema:
    *   Fields: `timestamp`, `agent_id` (of the discovery agent), `poller_id` (of the poller tasking discovery, if applicable, otherwise system/discovery engine ID), `device_ip`, `device_id`, `ifIndex`, `ifName`, `ifDescr`, `ifAlias`, `ifSpeed`, `ifPhysAddress`, `ip_addresses` (array), `ifAdminStatus`, `ifOperStatus`, `metadata`.
*   FR4.3: Discovered neighbor information (LLDP/CDP, as per FR3.3) must be published to the `topology_discovery_events` Proton stream. Data must conform to the existing schema:
    *   Fields: `timestamp`, `agent_id`, `poller_id`, `local_device_ip`, `local_device_id`, `local_ifIndex`, `local_ifName`, `protocol_type` ('LLDP' or 'CDP'), `neighbor_chassis_id`, `neighbor_port_id`, `neighbor_port_descr`, `neighbor_system_name`, `neighbor_management_address`, `metadata`.
*   FR4.4: All data published to Proton streams must include a `timestamp` and `agent_id` (identifying the instance of the discovery engine performing the work). A `poller_id` should also be included if the discovery task is initiated or managed by a specific poller.

**4.5 Configuration**
*   FR5.1: Global SNMP v2c community strings (read-only).
*   FR5.2: Global SNMP v3 credentials (username, auth protocol/password, priv protocol/password).
*   FR5.3: Per-target/subnet overrides for SNMP credentials.
*   FR5.4: Configurable list of OIDs to query (extensible beyond the defaults in FR3).
*   FR5.5: Configurable discovery schedule/interval (e.g., run every X hours).
*   FR5.6: Configuration should be loadable via file or KV store (aligning with ADR-01).

**4.6 Engine Operation**
*   FR6.1: The engine should operate periodically based on its schedule or be triggerable on-demand.
*   FR6.2: For a given seed IP/subnet, the engine will:
    1.  Attempt to ping/connect to confirm reachability (optional, configurable).
    2.  Attempt SNMP connection using configured credentials.
    3.  If successful, collect system, interface, and neighbor information.
    4.  Publish collected data to the appropriate Proton streams.
*   FR6.3: Efficiently handle subnet scanning (e.g., concurrent probes, avoiding redundant walks if multiple IPs resolve to the same device).

**4.7 Error Handling and Logging**
*   FR7.1: Log all discovery attempts, successes, and failures.
*   FR7.2: Log errors encountered during SNMP communication (e.g., timeouts, authentication failures, noSuchName).
*   FR7.3: Gracefully handle devices that do not support certain MIBs or OIDs.

**5. Non-Functional Requirements**

*   **NFR1: Performance:**
    *   Discovery of a single moderately complex device (e.g., 48-port switch with LLDP) should complete within 30-60 seconds.
    *   Scanning a /24 subnet should be reasonably efficient, avoiding excessive scan times (target TBD based on concurrency).
*   **NFR2: Scalability:**
    *   The engine should be designed to allow multiple instances to run (if needed for very large networks, though a single well-configured instance should handle typical enterprise networks).
    *   Data publication to Proton should handle bursts of discovered data.
*   **NFR3: Reliability:**
    *   The engine should be resilient to unresponsive devices or SNMP errors.
    *   Proper error handling and retry mechanisms for transient SNMP issues.
*   **NFR4: Security:**
    *   SNMPv3 credentials must be stored securely (e.g., encrypted in configuration or managed by a secrets S_USER_WARNING_HTTP_CONCURRENT_REQUESTS_PER_TASK).
    *   The engine should use read-only SNMP credentials.
*   **NFR5: Usability (Configuration):**
    *   Configuration should be clear and well-documented.
    *   Easy to specify seeds and credentials.
*   **NFR6: Maintainability:**
    *   Code should be modular and well-tested.
    *   Clear separation between SNMP interaction, data processing, and data publishing.

**6. System Architecture & Data Flow**

*   **Discovery Engine Placement:** The SNMP Discovery Engine can be a standalone service (`serviceradar-discovery`) or a specialized module within `serviceradar-core`. It will read its configuration (seeds, credentials, schedule).
*   **Data Flow:**
    1.  Discovery Engine reads configuration.
    2.  Engine performs SNMP queries against target devices based on seeds.
    3.  Collected raw data is structured.
    4.  Structured data (device info, interface details, neighbor info) is published to designated Proton streams (`discovered_interfaces`, `topology_discovery_events`, and contributing to `devices`).
    5.  (Downstream) An ArangoDB Sync Service (as per ADR-02) consumes these Proton streams to populate/update the ArangoDB graph.

```mermaid
graph TD
    subgraph "SNMP Discovery Engine"
        Config[Configuration<br>(Seeds, Credentials, Schedule)] --> SD[SNMP Discovery Logic<br>(gosnmp)]
        SD -->|SNMP Queries| TargetDevices[Network Devices]
        SD --> DataProcessor[Data Processor/Formatter]
        DataProcessor --> ProtonPublisher[Proton Stream Publisher]
    end

    ProtonPublisher -->|Device Info, Interface Info, Neighbor Info| ProtonStreams[Timeplus Proton Streams<br>- snmp_results<br>- discovered_interfaces<br>- topology_discovery_events]

    ProtonStreams -->|unified_devices_mv| DevicesStream[Proton 'unified_devices' Stream]

    %% This part is outside the scope of this PRD but shows context
    subgraph "Downstream (ADR-02)"
      ProtonStreams --> ArangoSync[ArangoDB Sync Service]
      DevicesStream --> ArangoSync
      ArangoSync --> ArangoDB[ArangoDB Graph]
    end
```

**7. Data Models (Output to Proton)**

The engine will produce data matching the schemas of:
*   `db.SweepResult` (for `snmp_results` stream, indicating basic availability and high-level info):
    *   `agent_id`: ID of the discovery engine instance.
    *   `poller_id`: (If applicable) ID of poller tasking discovery.
    *   `discovery_source`: "snmp" or "mapper".
    *   `ip`: Device IP.
    *   `mac`: Device base MAC (if discoverable).
    *   `hostname`: `sysName`.
    *   `timestamp`: Discovery time.
    *   `available`: True if SNMP responsive.
    *   `metadata`: Map including `sysDescr`, `sysObjectID`, `sysUpTime`.
*   `db.DiscoveredInterface` (for `discovered_interfaces` stream - defined in `db.go`).
*   `db.TopologyDiscoveryEvent` (for `topology_discovery_events` stream - defined in `db.go`, with `protocol_type` as "LLDP" or "CDP").

**8. API (Internal)**
No external API is proposed for this engine in v1. It operates based on configuration and schedule, publishing data to Proton. Future administrative APIs could be added for on-demand scans or status checks.

**9. Success Metrics**

*   **Coverage:** Percentage of known SNMP-enabled network devices successfully discovered and profiled.
*   **Accuracy:** Correctness of discovered interface details and neighbor relationships (validated against ground truth).
*   **Completeness:** All specified MIBs/OIDs (FR3) are successfully retrieved where supported by devices.
*   **Performance:** Discovery times align with NFR1.
*   **Integration:** Data correctly populates the target Proton streams (`discovered_interfaces`, `topology_discovery_events`, contributes to `devices`).
*   **Stability:** Engine runs reliably without crashes or excessive resource consumption.

**10. Future Considerations**

*   Discovery of more "collection" types like VLANs (`Q-BRIDGE-MIB`), LAGs (`IEEE8023-LAG-MIB`).
*   Support for custom MIBs for vendor-specific information.
*   Integration with a scheduler for more complex discovery job management.
*   API for triggering on-demand discovery scans.
*   Enhanced ARP/MAC table discovery to map non-SNMP device IPs to switch ports.
*   More sophisticated device role identification based on `sysObjectID` patterns or other heuristics.

**11. Risks & Mitigations**

*   **R1: SNMP Inconsistencies:** Devices may not implement all MIBs correctly or consistently.
    *   **M1:** Graceful error handling for missing OIDs/MIBs. Extensive logging. Allow user-configurable OID sets.
*   **R2: Network Performance Impact:** Aggressive scanning could impact network or device performance.
    *   **M2:** Configurable concurrency, request rates, and timeouts. Schedule scans during off-peak hours.
*   **R3: SNMP Credential Management:** Securely storing and managing diverse SNMP credentials can be complex.
    *   **M3:** Follow security best practices for credential storage (encryption at rest, integration with vault if available). Promote SNMPv3.
*   **R4: Scalability for Very Large Networks:** A single discovery instance might be a bottleneck.
    *   **M4:** Design for potential distributed operation in the future. Focus on efficient Proton publishing.
*   **R5: Device Support:** Varying levels of SNMP support across different vendors and models.
    *   **M5:** Prioritize common MIBs. Allow users to define custom OID mappings for problematic devices.

**12. Open Questions**

*   What is the primary mechanism for `agent_id` and `poller_id` assignment if the discovery engine is standalone? (Assume for now `agent_id` is the discovery engine's own ID, and `poller_id` is context-dependent or a system ID if globally scheduled).
*   How will the initial SNMP credentials be securely provided and managed? (Assume encrypted config or K/V store).
*   What are the exact performance targets for subnet scanning (e.g., time to scan a /22 subnet)?
*   Should the engine attempt to correlate discovered IP addresses on interfaces with existing entries in the `devices` stream to enrich a single device entity? (Yes, this is implied by contributing to the `devices` stream).