Okay, let's draft a PRD for a CDP (Cisco Discovery Protocol) Discovery Engine, keeping it distinct yet complementary to the SNMP Discovery Engine.

## Product Requirements Document: ServiceRadar CDP Discovery Engine

**Version:** 1.0
**Date:** 2024-07-15
**Author:** AI Assistant (based on user requirements)
**Status:** Proposed

**1. Overview**

This document outlines the requirements for a Cisco Discovery Protocol (CDP) NNetworkServicee in ServiceRadar. This engine will specifically focus on leveraging CDP information, typically accessed via SNMP, to discover Layer 2 adjacencies with Cisco devices. The data gathered will be crucial for building an accurate network topology map within ServiceRadar's graph database (ArangoDB), by providing detailed neighbor relationship information.

**1.1 Purpose**
To design and implement a CDP discovery engine that can:
*   Identify Cisco devices that are CDP neighbors to a queried device.
*   Collect detailed information about these CDP neighbors, including their device ID, platform, capabilities, and connected interface.
*   Publish this neighbor relationship data to ServiceRadar's `topology_discovery_events` Proton stream, enriching the network graph.

**1.2 Goals**
*   Develop a module that uses `gosnmp` to query CDP-specific MIBs on network devices.
*   Provide flexible seeding mechanisms for initiating CDP discovery (often piggybacking on general SNMP-enabled device discovery).
*   Focus on extracting and structuring CDP neighbor data accurately.
*   Integrate seamlessly with the `topology_discovery_events` stream.
*   Complement other discovery methods (like LLDP and general SNMP device profiling) to provide a comprehensive topology view.

**1.3 Non-Goals**
*   Discovery of non-CDP neighbor protocols (LLDP will be handled by a separate or combined LLDP/general topology module).
*   Full device profiling via CDP (CDP provides neighbor info; full profiling is better suited for general SNMP discovery).
*   Directly writing to ArangoDB.
*   SNMP Trap handling for CDP events (e.g., neighbor changes).
*   Configuring CDP on devices.

**2. Target Users**

*   **Network Administrators/Engineers:** Will use the discovered CDP adjacencies to validate network diagrams, troubleshoot Layer 2 connectivity, and understand device interconnections, especially in Cisco-centric environments.
*   **SREs/Operations Teams:** Will leverage this precise Layer 2 information in the graph DB for accurate impact analysis.

**3. User Stories**

*   As a Network Admin, when an SNMP-enabled Cisco device is discovered, I want the engine to also query its CDP table to find all directly connected Cisco neighbors.
*   As a Network Admin, for each CDP neighbor found, I want to know the neighbor's Device ID (hostname), platform type, management IP address, and the local/remote interface pair forming the connection.
*   As an SRE, I want CDP-discovered neighbor relationships to be published to the `topology_discovery_events` stream with `protocol_type` as 'CDP' so it can be added to the ArangoDB graph.
*   As an Operator, I want to enable or disable CDP-specific discovery globally or per device/subnet.

**4. Functional Requirements**

**4.1 SNMP Communication Core (gosnmp)**
*   FR1.1: Utilize existing SNMP v2c and v3 capabilities (from the general SNMP engine or a shared library) to access CDP MIBs. CDP information is read via SNMP.

**4.2 Seeding and Triggering**
*   FR2.1: CDP discovery should primarily be triggered for devices already identified as SNMP-enabled and likely supporting CDP (e.g., based on `sysObjectID` or vendor).
*   FR2.2: Allow explicit seeding of IPs/subnets for targeted CDP discovery runs.
*   FR2.3: Configuration for CDP discovery (e.g., specific SNMP credentials if different, target lists) should be manageable (file or KV store).

**4.3 Data Collection Scope (CISCO-CDP-MIB)**
*   FR3.1: For each local interface participating in CDP:
    *   `cdpInterfaceName` (CISCO-CDP-MIB::cdpInterfaceName)
    *   `cdpInterfaceIfIndex` (CISCO-CDP-MIB::cdpInterfaceIfIndex) - Correlates to the main `ifIndex`.
*   FR3.2: For each CDP neighbor (from `cdpCacheTable`):
    *   `cdpCacheAddress` (CISCO-CDP-MIB::cdpCacheAddress) - Neighbor's primary (often management) IP address.
    *   `cdpCacheAddressType` (CISCO-CDP-MIB::cdpCacheAddressType) - Type of address (e.g., IPv4).
    *   `cdpCacheVersion` (CISCO-CDP-MIB::cdpCacheVersion) - Neighbor's CDP version string.
    *   `cdpCacheDeviceId` (CISCO-CDP-MIB::cdpCacheDeviceId) - Neighbor's hostname/device ID.
    *   `cdpCacheDevicePort` (CISCO-CDP-MIB::cdpCacheDevicePort) - Neighbor's remote interface identifier (e.g., "GigabitEthernet0/1").
    *   `cdpCachePlatform` (CISCO-CDP-MIB::cdpCachePlatform) - Neighbor's hardware platform (e.g., "cisco WS-C2960-24TT-L").
    *   `cdpCacheCapabilities` (CISCO-CDP-MIB::cdpCacheCapabilities) - Bitmap of neighbor's capabilities (e.g., Router, Switch, Host).
    *   `cdpCacheNativeVLAN` (CISCO-CDP-MIB::cdpCacheNativeVLAN) - (Optional but useful)
    *   `cdpCacheDuplex` (CISCO-CDP-MIB::cdpCacheDuplex) - (Optional but useful)
    *   The entry is indexed by `cdpCacheIfIndex` (local interface index) and `cdpCacheDeviceIndex` (an arbitrary index for multiple neighbors on one interface, though rare for point-to-point).

**4.4 Data Output and Storage (Proton Integration)**
*   FR4.1: Discovered CDP neighbor relationships must be published to the `topology_discovery_events` Proton stream. Data must conform to the existing schema:
    *   `timestamp`: Time of discovery.
    *   `agent_id`: ID of the discovery engine instance.
    *   `poller_id`: (If applicable) ID of poller tasking discovery.
    *   `local_device_ip`: IP address of the device reporting the CDP information.
    *   `local_device_id`: `sysName` of the device reporting CDP information.
    *   `local_ifIndex`: `cdpInterfaceIfIndex` of the local interface.
    *   `local_ifName`: `cdpInterfaceName` of the local interface.
    *   `protocol_type`: Hardcoded to "CDP".
    *   `neighbor_chassis_id`: Mapped from `cdpCacheDeviceId`.
    *   `neighbor_port_id`: Mapped from `cdpCacheDevicePort`.
    *   `neighbor_port_descr`: (Not directly available in CDP, use `cdpCacheDevicePort` or leave null).
    *   `neighbor_system_name`: Mapped from `cdpCacheDeviceId` (often the hostname).
    *   `neighbor_management_address`: Mapped from `cdpCacheAddress`.
    *   `metadata`: A map to store additional CDP information like `cdpCachePlatform`, `cdpCacheVersion`, `cdpCacheCapabilities`, `cdpCacheNativeVLAN`, `cdpCacheDuplex`.
*   FR4.2: Information about the *local* device (the one being queried for CDP data) and its interfaces, if not already comprehensively discovered by the general SNMP engine, can be published to `snmp_results` (feeding `devices`) and `discovered_interfaces` respectively, to ensure context. `discovery_source` can be "cdp_context".

**4.5 Configuration**
*   FR5.1: Ability to enable/disable CDP discovery globally.
*   FR5.2: If specific SNMP credentials are needed for CDP MIBs (unlikely, but possible), allow override.
*   FR5.3: Configurable schedule/interval for CDP checks (likely tied to general SNMP discovery schedule).

**4.6 Engine Operation**
*   FR6.1: When a device is targeted for discovery:
    1.  Establish SNMP connectivity (relying on general SNMP engine capabilities).
    2.  Query the `cdpInterfaceTable` to find local interfaces running CDP.
    3.  Query the `cdpCacheTable` to retrieve neighbor entries.
    4.  For each neighbor, format and publish a `topology_discovery_events` record.

**4.7 Error Handling and Logging**
*   FR7.1: Log attempts to query CDP MIBs.
*   FR7.2: Log if CDP is not enabled or MIBs are not populated on a device.
*   FR7.3: Log successfully discovered CDP adjacencies.

**5. Non-Functional Requirements**

*   **NFR1: Performance:** Querying CDP tables on a device should add minimal overhead (e.g., &lt; 5-10 seconds) to a general SNMP poll.
*   **NFR2: Accuracy:** Information mapped to `topology_discovery_events` must accurately reflect the CDP data.
*   **NFR3: Integration:** Data must flow correctly into the `topology_discovery_events` stream using the defined schema.

**6. System Architecture & Data Flow**

*   **Discovery Engine Placement:** The CDP Discovery Engine will likely be a module within the broader SNMP Discovery Engine or `serviceradar-core`, as it relies on SNMP to fetch CDP data.
*   **Data Flow:**
    1.  General SNMP Discovery identifies a device.
    2.  If configured, the CDP module is invoked for that device.
    3.  CDP module uses SNMP to query `CISCO-CDP-MIB`.
    4.  Collected CDP neighbor data is formatted.
    5.  Formatted data is published primarily to the `topology_discovery_events` Proton stream.

```mermaid
graph TD
    subgraph "SNMP/CDP Discovery Process"
        Config[Configuration<br>(Seeds, Credentials, CDP Enabled?)] --> SNMPAuth[SNMP Authentication Module]
        SNMPAuth -->|SNMP Session| TargetDevice[Network Device (Cisco)]
        TargetDevice -->|CDP MIB Data via SNMP| CDPQueryLogic[CDP MIB Query Logic<br>(gosnmp)]
        CDPQueryLogic --> DataProcessor[Data Processor/Formatter]
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
    *   Example `metadata` for CDP:
        ```json
        {
          "platform": "cisco WS-C2960-24TT-L",
          "cdp_version": "Cisco IOS Software, C2960 Software (C2960-LANBASEK9-M), Version 12.2(55)SE1, RELEASE SOFTWARE (fc1)",
          "capabilities": "Switch,IGMP", // Parsed from bitmap
          "native_vlan": "1",
          "duplex": "full"
        }
        ```
*   **Contextual Output (Optional):**
    *   `snmp_results` (for basic local device info if not already present).
    *   `discovered_interfaces` (for local interface info if not already present).

**8. API (Internal)**
No external API for v1. CDP discovery is an internal capability.

**9. Success Metrics**

*   **Coverage:** Successfully retrieves CDP data from &gt;95% of known Cisco devices configured for SNMP and CDP.
*   **Accuracy:** &gt;99% accuracy in mapping CDP fields (`cdpCacheDeviceId`, `cdpCacheDevicePort`, `cdpCacheAddress`, `cdpCachePlatform`) to the `topology_discovery_events` stream fields.
*   **Integration:** All discovered CDP adjacencies correctly populate `topology_discovery_events`.
*   **Performance:** CDP discovery adds no more than 10 seconds to the SNMP polling time for a device.

**10. Future Considerations**

*   Parsing `cdpCacheCapabilities` bitmap into a human-readable list of strings.
*   More intelligent correlation of `cdpCacheAddress` to determine if it's a primary management IP vs. any IP on the neighbor.
*   Potential for a combined LLDP/CDP discovery module to reduce redundant SNMP walks if both are desired.

**11. Risks & Mitigations**

*   **R1: CDP Disabled:** Devices may have CDP disabled.
    *   **M1:** Log this status. The engine cannot discover what's not advertised.
*   **R2: SNMP Access Issues:** Standard SNMP connectivity problems (credentials, ACLs).
    *   **M2:** Rely on the robustness of the underlying SNMP communication module. Log errors clearly.
*   **R3: MIB Variations:** Minor variations in CISCO-CDP-MIB across IOS versions (though generally stable).
    *   **M3:** Test against common IOS/IOS-XE/NX-OS versions. Prioritize universally available OIDs.

**12. Open Questions**

*   How to best map `cdpCacheCapabilities` (a bitmap) to a useful string or array in the `metadata` field of `topology_discovery_events`? (Suggest parsing it into a comma-separated string or array of strings like "Router", "Switch").
*   What's the strategy if a device reports both LLDP and CDP neighbors? (Publish both to `topology_discovery_events` with respective `protocol_type`. The graph DB sync service can handle deduplication or merging logic if needed).
