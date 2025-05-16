## Product Requirements Document: ServiceRadar LLDP Discovery Engine

**Version:** 1.0
**Date:** 2024-07-15
**Author:** AI Assistant (based on user requirements)
**Status:** Proposed

**1. Overview**

This document specifies the requirements for an LLDP (Link Layer Discovery Protocol, IEEE 802.1AB) NNetworkServicee within ServiceRadar. This engine will utilize SNMP to query LLDP MIBs on network devices to discover Layer 2 adjacencies. The collected information is vital for constructing an accurate network topology map in ServiceRadar's ArangoDB graph database, facilitating a deeper understanding of network interconnections across multi-vendor environments.

**1.1 Purpose**
To design and implement an LLDP discovery engine that can:
*   Identify devices advertising LLDP information.
*   Collect detailed information about LLDP neighbors, including their chassis ID, port ID, system name, capabilities, and management addresses.
*   Publish this neighbor relationship data to ServiceRadar's `topology_discovery_events` Proton stream.

**1.2 Goals**
*   Develop a module using `gosnmp` to query LLDP-MIBs (and relevant extension MIBs) on network devices.
*   Provide flexible seeding mechanisms for initiating LLDP discovery, often in conjunction with general SNMP device discovery.
*   Accurately extract and structure LLDP neighbor data.
*   Ensure seamless integration with the `topology_discovery_events` stream.
*   Complement other discovery methods (like CDP and general SNMP device profiling) to provide a comprehensive, vendor-agnostic topology view.

**1.3 Non-Goals**
*   Discovery of non-LLDP neighbor protocols (CDP handled separately or by a combined module).
*   Full device profiling via LLDP (LLDP focuses on neighbor info; full profiling is for general SNMP discovery).
*   Directly writing to ArangoDB.
*   SNMP Trap handling for LLDP events (e.g., neighbor changes).
*   Configuring LLDP on devices.

**2. Target Users**

*   **Network Administrators/Engineers:** Will use discovered LLDP adjacencies for network documentation, troubleshooting Layer 2 connectivity in multi-vendor environments, and verifying physical connections.
*   **SREs/Operations Teams:** Will utilize this precise Layer 2 information in the graph DB for accurate impact analysis and dependency mapping.

**3. User Stories**

*   As a Network Admin, when an SNMP-enabled device is discovered, I want the engine to also query its LLDP tables to find all directly connected neighbors.
*   As a Network Admin, for each LLDP neighbor found, I want to know the neighbor's Chassis ID, Port ID, System Name, System Description, Management Address, and capabilities.
*   As an SRE, I want LLDP-discovered neighbor relationships to be published to the `topology_discovery_events` stream with `protocol_type` as 'LLDP' so it can be added to the ArangoDB graph.
*   As an Operator, I want to enable or disable LLDP-specific discovery globally or per device/subnet.

**4. Functional Requirements**

**4.1 SNMP Communication Core (gosnmp)**
*   FR1.1: Leverage existing SNMP v2c and v3 capabilities to access LLDP MIBs. LLDP information is read via SNMP.

**4.2 Seeding and Triggering**
*   FR2.1: LLDP discovery should primarily be triggered for devices already identified as SNMP-enabled.
*   FR2.2: Allow explicit seeding of IPs/subnets for targeted LLDP discovery runs.
*   FR2.3: Configuration for LLDP discovery (e.g., specific SNMP credentials if different, target lists) should be manageable (file or KV store).

**4.3 Data Collection Scope (LLDP-MIB, potentially LLDP-EXT-DOT1-MIB, LLDP-EXT-DOT3-MIB)**
*   FR3.1: **Local System Information (LLDP-MIB):**
    *   `lldpLocChassisIdSubtype` (LLDP-MIB::lldpLocChassisIdSubtype)
    *   `lldpLocChassisId` (LLDP-MIB::lldpLocChassisId)
    *   `lldpLocSysName` (LLDP-MIB::lldpLocSysName)
    *   `lldpLocSysDesc` (LLDP-MIB::lldpLocSysDesc)
    *   `lldpLocSysCapSupported` (LLDP-MIB::lldpLocSysCapSupported) - Bitmap
    *   `lldpLocSysCapEnabled` (LLDP-MIB::lldpLocSysCapEnabled) - Bitmap
*   FR3.2: **Local Port Information (from `lldpLocPortTable`):** For each local interface participating in LLDP:
    *   `lldpLocPortIdSubtype` (LLDP-MIB::lldpLocPortIdSubtype)
    *   `lldpLocPortId` (LLDP-MIB::lldpLocPortId)
    *   `lldpLocPortDesc` (LLDP-MIB::lldpLocPortDesc)
    *   *Crucially, the local `ifIndex` needs to be determined. This often involves mapping `lldpLocPortNum` (if available and consistently mapped by vendor) or `lldpLocPortId` (if subtype is `interfaceAlias` or `interfaceName`) to the `ifIndex` from the main IF-MIB.*
*   FR3.3: **Remote System Information (from `lldpRemTable`):** For each LLDP neighbor:
    *   Indexed by `lldpRemTimeMark`, `lldpRemLocalPortNum`, `lldpRemIndex`.
    *   `lldpRemChassisIdSubtype` (LLDP-MIB::lldpRemChassisIdSubtype)
    *   `lldpRemChassisId` (LLDP-MIB::lldpRemChassisId)
    *   `lldpRemPortIdSubtype` (LLDP-MIB::lldpRemPortIdSubtype)
    *   `lldpRemPortId` (LLDP-MIB::lldpRemPortId)
    *   `lldpRemPortDesc` (LLDP-MIB::lldpRemPortDesc)
    *   `lldpRemSysName` (LLDP-MIB::lldpRemSysName)
    *   `lldpRemSysDesc` (LLDP-MIB::lldpRemSysDesc)
    *   `lldpRemSysCapSupported` (LLDP-MIB::lldpRemSysCapSupported) - Bitmap
    *   `lldpRemSysCapEnabled` (LLDP-MIB::lldpRemSysCapEnabled) - Bitmap
*   FR3.4: **Remote Management Address (from `lldpRemManAddrTable`):**
    *   `lldpRemManAddrSubtype` (LLDP-MIB::lldpRemManAddrSubtype)
    *   `lldpRemManAddr` (LLDP-MIB::lldpRemManAddr)
    *   `lldpRemManAddrIfSubtype` (LLDP-MIB::lldpRemManAddrIfSubtype)
    *   `lldpRemManAddrIfId` (LLDP-MIB::lldpRemManAddrIfId)
    *   (Need to select the most relevant management address if multiple are advertised).

**4.4 Data Output and Storage (Proton Integration)**
*   FR4.1: Discovered LLDP neighbor relationships must be published to the `topology_discovery_events` Proton stream. Data must conform to the existing schema:
    *   `timestamp`: Time of discovery.
    *   `agent_id`: ID of the discovery engine instance.
    *   `poller_id`: (If applicable) ID of poller tasking discovery.
    *   `local_device_ip`: IP address of the device reporting the LLDP information.
    *   `local_device_id`: `lldpLocChassisId` (if MAC/NetworkAddress) or `lldpLocSysName` (if system name is more appropriate as ID).
    *   `local_ifIndex`: The `ifIndex` of the local port. This requires careful mapping from `lldpLocPortId` / `lldpLocPortNum`.
    *   `local_ifName`: `lldpLocPortDesc` or the `ifName`/`ifAlias` corresponding to the `local_ifIndex`.
    *   `protocol_type`: Hardcoded to "LLDP".
    *   `neighbor_chassis_id`: `lldpRemChassisId`.
    *   `neighbor_port_id`: `lldpRemPortId`.
    *   `neighbor_port_descr`: `lldpRemPortDesc`.
    *   `neighbor_system_name`: `lldpRemSysName`.
    *   `neighbor_management_address`: The selected `lldpRemManAddr`.
    *   `metadata`: A map to store additional LLDP information:
        *   `local_chassis_id_subtype`, `local_sys_name`, `local_sys_desc`, `local_port_id_subtype`.
        *   `remote_chassis_id_subtype`, `remote_port_id_subtype`, `remote_sys_desc`.
        *   `remote_capabilities_supported` (parsed bitmap).
        *   `remote_capabilities_enabled` (parsed bitmap).
        *   All `lldpRemManAddr` entries if multiple exist.
*   FR4.2: Information about the *local* device (the one being queried for LLDP data) and its interfaces, if not already comprehensively discovered, can be published to `snmp_results` (feeding `devices`) and `discovered_interfaces` respectively. `discovery_source` can be "lldp_context".

**4.5 Configuration**
*   FR5.1: Ability to enable/disable LLDP discovery globally.
*   FR5.2: If specific SNMP credentials are needed for LLDP MIBs (unlikely), allow override.
*   FR5.3: Configurable schedule/interval for LLDP checks (likely tied to general SNMP discovery schedule).

**4.6 Engine Operation**
*   FR6.1: When a device is targeted for discovery:
    1.  Establish SNMP connectivity.
    2.  Query LLDP MIBs (`lldpLocPortTable`, `lldpRemTable`, `lldpRemManAddrTable`).
    3.  Correlate local port information (`lldpLocPortId`, `lldpLocPortNum`) with `ifIndex` from IF-MIB.
    4.  For each remote system entry, format and publish a `topology_discovery_events` record.

**4.7 Error Handling and Logging**
*   FR7.1: Log attempts to query LLDP MIBs.
*   FR7.2: Log if LLDP is not enabled or MIBs are not populated on a device.
*   FR7.3: Log successfully discovered LLDP adjacencies.

**5. Non-Functional Requirements**

*   **NFR1: Performance:** Querying LLDP tables on a device should add minimal overhead (e.g., &lt; 5-10 seconds) to a general SNMP poll.
*   **NFR2: Accuracy:** Information mapped to `topology_discovery_events` must accurately reflect the LLDP data, especially the local `ifIndex`.
*   **NFR3: Integration:** Data must flow correctly into the `topology_discovery_events` stream using the defined schema.

**6. System Architecture & Data Flow**

*   **Discovery Engine Placement:** The LLDP Discovery Engine will likely be a module within the broader SNMP Discovery Engine or `serviceradar-core`.
*   **Data Flow:**
    1.  General SNMP Discovery identifies a device.
    2.  If configured, the LLDP module is invoked for that device.
    3.  LLDP module uses SNMP to query `LLDP-MIB` and related MIBs.
    4.  Collected LLDP neighbor data is formatted.
    5.  Formatted data is published primarily to the `topology_discovery_events` Proton stream.

```mermaid
graph TD
    subgraph "SNMP/LLDP Discovery Process"
        Config[Configuration<br>(Seeds, Credentials, LLDP Enabled?)] --> SNMPAuth[SNMP Authentication Module]
        SNMPAuth -->|SNMP Session| TargetDevice[Network Device]
        TargetDevice -->|LLDP MIB Data via SNMP| LLDPQueryLogic[LLDP MIB Query Logic<br>(gosnmp)]
        LLDPQueryLogic --> DataProcessor[Data Processor/Formatter]
        DataProcessor --> TopologyEventsPublisher[Proton: topology_discovery_events]
        DataProcessor -->|Local Device Context| OtherProtonPublishers[Proton: snmp_results, discovered_interfaces]
    end

    TopologyEventsPublisher --> ProtonStreams[Timeplus Proton Streams]
    OtherProtonPublishers --> ProtonStreams

    %% This part is outside the scope of this PRD but shows context
    subgraph "Downstream (ADR-02)"
      ProtonStreams --> ArangoSync[ArangoDB Sync Service]
      ArangoSync --> ArangoDB[ArangoDB Graph]
    end
```

**7. Data Models (Output to Proton)**

*   **Primary Output:** `topology_discovery_events` (as defined in `db.go` and FR4.1).
    *   Example `metadata` for LLDP:
        ```json
        {
          "local_chassis_id_subtype": "macAddress", // e.g., 4
          "local_sys_name": "switch-datacenter-1",
          "local_sys_desc": "Datacenter Core Switch, Model XYZ, OS v2.3",
          "local_port_id_subtype": "interfaceName", // e.g., 5
          "remote_chassis_id_subtype": "macAddress",
          "remote_port_id_subtype": "macAddress",
          "remote_sys_desc": "Access Point, Model AP-123, Firmware v1.1",
          "remote_capabilities_supported": ["WLANAccessPoint", "Router"], // Parsed from bitmap
          "remote_capabilities_enabled": ["WLANAccessPoint"], // Parsed from bitmap
          "all_remote_management_addresses": [
            {"type": "ipv4", "address": "10.1.1.5"},
            {"type": "ipv6", "address": "2001:db8::5"}
          ]
        }
        ```
*   **Contextual Output (Optional):**
    *   `snmp_results` (for basic local device info).
    *   `discovered_interfaces` (for local interface info, ensuring `ifIndex` linkage).

**8. API (Internal)**
No external API for v1. LLDP discovery is an internal capability.

**9. Success Metrics**

*   **Coverage:** Successfully retrieves LLDP data from &gt;95% of known devices configured for SNMP and LLDP.
*   **Accuracy:** &gt;99% accuracy in mapping LLDP fields to the `topology_discovery_events` stream fields, including correct `local_ifIndex`.
*   **Integration:** All discovered LLDP adjacencies correctly populate `topology_discovery_events`.
*   **Performance:** LLDP discovery adds no more than 10 seconds to the SNMP polling time for a device.

**10. Future Considerations**

*   Comprehensive parsing of all LLDP TLVs (e.g., Port VLAN ID, VLAN Name, Link Aggregation, Maximum Frame Size from extension MIBs).
*   Strategy for selecting the "best" management address if multiple are advertised by a neighbor.
*   Mechanism for aging out LLDP neighbor entries if they are no longer seen (dependent on how `topology_discovery_events` are consumed and processed into ArangoDB).

**11. Risks & Mitigations**

*   **R1: LLDP Disabled:** Devices may have LLDP disabled.
    *   **M1:** Log this status. The engine cannot discover what's not advertised.
*   **R2: SNMP Access Issues:** Standard SNMP connectivity problems.
    *   **M2:** Rely on the underlying SNMP communication module. Log errors clearly.
*   **R3: Mapping `lldpLocPortId` to `ifIndex`:** `lldpLocPortId` can be of various subtypes. Correctly mapping it to the device's `ifIndex` is critical.
    *   **M3:** Implement logic to check `lldpLocPortIdSubtype`.
        *   If `interfaceAlias(1)` or `interfaceName(5)`, query `ifTable` for a match on `ifAlias` or `ifName` to get `ifIndex`.
        *   If `macAddress(3)`, query `ifTable` for a match on `ifPhysAddress`.
        *   If `local(7)`, the `lldpLocPortId` might be the `ifIndex` itself or an internal port number; vendor documentation may be needed. `lldpLocPortNum` from `lldpLocPortTable` is often a more direct mapping to `ifIndex`.
        *   Log warnings if a clear mapping cannot be established.
*   **R4: Partial LLDP Implementations:** Some devices might not advertise all standard LLDP TLVs.
    *   **M4:** Gracefully handle missing optional TLVs. Log what data is available.

**12. Open Questions**

*   What is the definitive strategy for mapping `lldpLocPortId` (and its subtype) to the local `ifIndex` consistently across vendors? (Prioritize `lldpLocPortNum` from `lldpLocPortTable` if it maps directly to `ifIndex`. Otherwise, implement subtype-based mapping logic as in R3/M3).
*   How should multiple `lldpRemManAddr` entries be handled for the `neighbor_management_address` field? (Primary: Select the first IPv4, then first IPv6. Store all in `metadata`).
*   How should the `lldp...SysCapSupported` and `lldp...SysCapEnabled` bitmaps be parsed into meaningful strings? (Create a standard mapping, e.g., bit 0 = Other, bit 1 = Repeater, bit 2 = Bridge, etc., as per IEEE 802.1AB).
