## Product Requirements Document: ServiceRadar BGP Discovery Engine

**Version:** 1.0
**Date:** 2024-07-15
**Author:** AI Assistant (based on user requirements)
**Status:** Proposed

**1. Overview**

This document defines the requirements for a BGP NNetworkServicee as part of ServiceRadar. This engine will use SNMP to query BGP-specific MIBs on network devices (routers) to discover BGP peerings (neighbors). The primary goal is to gather information about Layer 3 adjacencies, which is crucial for understanding the routing topology and enriching the network graph in ArangoDB.

**1.1 Purpose**
To design and implement a BGP discovery engine that can:
*   Identify BGP-speaking devices and their configured BGP parameters (local AS, Router ID).
*   Discover BGP peers, including their IP address, AS number, and current session state.
*   Publish this BGP peering information to ServiceRadar's `topology_discovery_events` Proton stream.

**1.2 Goals**
*   Develop a module using `gosnmp` to query standard BGP MIBs (e.g., BGP4-MIB) on network devices.
*   Provide flexible seeding mechanisms for initiating BGP discovery (typically on devices identified as routers).
*   Accurately extract and structure BGP peer data.
*   Ensure seamless integration with the `topology_discovery_events` stream.
*   Complement L2 discovery (LLDP/CDP) with L3 routing adjacency information.

**1.3 Non-Goals**
*   Discovery of BGP routing tables (prefixes advertised/received) – this is a much larger scope, potentially for a future "BGP Monitoring Engine."
*   Real-time BGP session monitoring beyond initial state discovery (though state changes could be future events).
*   Configuration of BGP on devices.
*   Directly writing to ArangoDB.
*   SNMP Trap handling for BGP events (e.g., peer up/down).

**2. Target Users**

*   **Network Architects/Engineers:** Will use discovered BGP peerings to verify routing design, understand AS connectivity, and troubleshoot routing issues.
*   **SREs/Operations Teams:** Will leverage BGP adjacency information in the graph DB for advanced impact analysis related to routing paths.

**3. User Stories**

*   As a Network Admin, when an SNMP-enabled router is discovered, I want the engine to query its BGP tables to find all configured BGP peers.
*   As a Network Admin, for each BGP peer, I want to know its IP address, remote AS number, the local router's AS and BGP identifier, and the current BGP session state (e.g., Established, Idle).
*   As an SRE, I want BGP-discovered peer relationships to be published to the `topology_discovery_events` stream with `protocol_type` as 'BGP' so it can be added to the ArangoDB graph.
*   As an Operator, I want to enable or disable BGP-specific discovery globally or per device/subnet.

**4. Functional Requirements**

**4.1 SNMP Communication Core (gosnmp)**
*   FR1.1: Utilize existing SNMP v2c and v3 capabilities to access BGP MIBs.

**4.2 Seeding and Triggering**
*   FR2.1: BGP discovery should primarily be triggered for devices already identified as SNMP-enabled and likely to be routers (e.g., based on `sysServices`, `sysObjectID`, or LLDP/CDP capabilities).
*   FR2.2: Allow explicit seeding of IPs/subnets for targeted BGP discovery runs.
*   FR2.3: Configuration for BGP discovery (e.g., specific SNMP credentials if different, target lists) should be manageable (file or KV store).

**4.3 Data Collection Scope (Primarily BGP4-MIB)**
*   FR3.1: **Local BGP Information (BGP4-MIB):**
    *   `bgpLocalAs` (BGP4-MIB::bgpLocalAs.0) - The local device's Autonomous System number.
    *   `bgpIdentifier` (BGP4-MIB::bgpIdentifier.0) - The local device's BGP Router ID.
*   FR3.2: **BGP Peer Information (from `bgpPeerTable` in BGP4-MIB):** For each BGP peer:
    *   `bgpPeerIdentifier` (BGP4-MIB::bgpPeerIdentifier) - The BGP Router ID of the remote peer.
    *   `bgpPeerState` (BGP4-MIB::bgpPeerState) - Current state of the BGP FSM (e.g., idle, connect, active, openSent, openConfirm, established).
    *   `bgpPeerRemoteAs` (BGP4-MIB::bgpPeerRemoteAs) - The AS number of the remote peer.
    *   `bgpPeerRemoteAddr` (BGP4-MIB::bgpPeerRemoteAddr) - The IP address of the remote peer.
    *   `bgpPeerLocalAddr` (BGP4-MIB::bgpPeerLocalAddr) - The local IP address used for this peering session.
    *   `bgpPeerAdminStatus` (BGP4-MIB::bgpPeerAdminStatus) - Desired state (start, stop).
    *   (Optional but useful for metadata): `bgpPeerInUpdates`, `bgpPeerOutUpdates`, `bgpPeerFsmEstablishedTime`.

**4.4 Data Output and Storage (Proton Integration)**
*   FR4.1: Discovered BGP peer relationships must be published to the `topology_discovery_events` Proton stream. Data must conform to the existing schema:
    *   `timestamp`: Time of discovery.
    *   `agent_id`: ID of the discovery engine instance.
    *   `poller_id`: (If applicable) ID of poller tasking discovery.
    *   `local_device_ip`: Management IP address of the device reporting the BGP information.
    *   `local_device_id`: `bgpIdentifier` (local BGP Router ID) of the device reporting.
    *   `local_ifIndex`: (Difficult to map directly, can be null or derived if `bgpPeerLocalAddr` is mapped to an interface).
    *   `local_ifName`: (Difficult to map directly, can be null or derived).
    *   `protocol_type`: Hardcoded to "BGP".
    *   `neighbor_chassis_id`: Null (not directly applicable as BGP is L3, `bgpPeerIdentifier` is more specific).
    *   `neighbor_port_id`: Null.
    *   `neighbor_port_descr`: Null.
    *   `neighbor_system_name`: `bgpPeerIdentifier` (remote BGP Router ID, often a hostname).
    *   `neighbor_management_address`: `bgpPeerRemoteAddr` (this is the peering IP, which might also be a management IP).
    *   `neighbor_bgp_router_id`: `bgpPeerIdentifier` (remote BGP Router ID).
    *   `neighbor_ip_address`: `bgpPeerRemoteAddr`.
    *   `neighbor_as`: `bgpPeerRemoteAs`.
    *   `bgp_session_state`: `bgpPeerState` (e.g., "established", "idle").
    *   `metadata`: A map to store additional BGP information:
        *   `local_as`: `bgpLocalAs`.
        *   `local_router_id`: `bgpIdentifier` (local).
        *   `local_peering_ip`: `bgpPeerLocalAddr`.
        *   `peer_admin_status`: `bgpPeerAdminStatus`.
        *   Optionally, `fsm_established_time`, `in_updates`, `out_updates`.
*   FR4.2: Information about the *local* BGP-speaking device (its AS, Router ID), if not already comprehensively discovered, can be published to `snmp_results` (feeding `devices`). `discovery_source` can be "bgp_context".

**4.5 Configuration**
*   FR5.1: Ability to enable/disable BGP discovery globally.
*   FR5.2: Configuration for mapping BGP states (integer from MIB) to string representations (e.g., 6 -> "established").
*   FR5.3: Configurable schedule/interval for BGP checks (likely tied to general SNMP discovery schedule).

**4.6 Engine Operation**
*   FR6.1: When a device is targeted for discovery:
    1.  Establish SNMP connectivity.
    2.  Query local BGP information (`bgpLocalAs`, `bgpIdentifier`).
    3.  Query the `bgpPeerTable` to retrieve all peer entries.
    4.  For each peer, format and publish a `topology_discovery_events` record.

**4.7 Error Handling and Logging**
*   FR7.1: Log attempts to query BGP MIBs.
*   FR7.2: Log if BGP MIBs are not populated or BGP is not configured/enabled for SNMP on a device.
*   FR7.3: Log successfully discovered BGP peerings and their states.

**5. Non-Functional Requirements**

*   **NFR1: Performance:** Querying BGP tables on a device should generally be efficient. For routers with very large numbers of BGP peers (e.g., internet core routers), this could take longer, but for typical enterprise routers, it should be within 10-20 seconds.
*   **NFR2: Accuracy:** Information mapped to `topology_discovery_events` must accurately reflect the BGP peer data.
*   **NFR3: Integration:** Data must flow correctly into the `topology_discovery_events` stream using the defined schema.

**6. System Architecture & Data Flow**

*   **Discovery Engine Placement:** The BGP Discovery Engine will likely be a module within the broader SNMP Discovery Engine or `serviceradar-core`.
*   **Data Flow:**
    1.  General SNMP Discovery identifies a device (likely a router).
    2.  If configured, the BGP module is invoked for that device.
    3.  BGP module uses SNMP to query `BGP4-MIB`.
    4.  Collected BGP peer data is formatted.
    5.  Formatted data is published primarily to the `topology_discovery_events` Proton stream.

```mermaid
graph TD
    subgraph "SNMP/BGP Discovery Process"
        Config[Configuration<br>(Seeds, Credentials, BGP Enabled?)] --> SNMPAuth[SNMP Authentication Module]
        SNMPAuth -->|SNMP Session| TargetDevice[Network Device (Router)]
        TargetDevice -->|BGP MIB Data via SNMP| BGPQueryLogic[BGP MIB Query Logic<br>(gosnmp)]
        BGPQueryLogic --> DataProcessor[Data Processor/Formatter]
        DataProcessor --> TopologyEventsPublisher[Proton: topology_discovery_events]
        DataProcessor -->|Local Device Context| OtherProtonPublishers[Proton: snmp_results]
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
    *   Example `metadata` for BGP:
        ```json
        {
          "local_as": 65001,
          "local_router_id": "192.0.2.1",
          "local_peering_ip": "10.0.0.1",
          "peer_admin_status": "start", // e.g., "start" or "stop"
          "fsm_established_time_seconds": 3600, // if available
          "in_updates": 1500, // if available
          "out_updates": 1200 // if available
        }
        ```
*   **Contextual Output (Optional):**
    *   `snmp_results` (for basic local device info like BGP AS and Router ID).

**8. API (Internal)**
No external API for v1. BGP discovery is an internal capability.

**9. Success Metrics**

*   **Coverage:** Successfully retrieves BGP peer data from &gt;95% of known routers configured for SNMP and BGP.
*   **Accuracy:** &gt;99% accuracy in mapping BGP MIB fields to the `topology_discovery_events` stream fields.
*   **Integration:** All discovered BGP peerings correctly populate `topology_discovery_events`.
*   **State Reporting:** BGP session states are accurately reported (e.g., "established", "idle").

**10. Future Considerations**

*   Discovery of BGP session attributes (timers, authentication, capabilities exchanged).
*   Support for IPv6 BGP peers (`bgpPeerRemoteAddr` can be IPv6).
*   Discovery of BGP peers within specific VRFs (requires vendor-specific MIBs or context indexing).
*   Correlating `bgpPeerLocalAddr` to a specific local `ifIndex` and `ifName` (requires additional IF-MIB lookups).

**11. Risks & Mitigations**

*   **R1: BGP Not Enabled for SNMP:** Devices may not expose BGP MIBs via SNMP.
    *   **M1:** Log this. The engine cannot discover what's not available.
*   **R2: SNMP Access Issues:** Standard SNMP connectivity problems.
    *   **M2:** Rely on the robustness of the underlying SNMP communication module. Log errors clearly.
*   **R3: Large `bgpPeerTable`:** On routers with many peers, walking this table can be slow.
    *   **M3:** Optimize SNMP walks. Allow configuration of timeouts. Consider if `GETBULK` can be used effectively.
*   **R4: VRF Complexity:** Standard BGP4-MIB is typically for the default routing instance. Discovering peers in VRFs often requires vendor-specific MIBs.
    *   **M4:** For v1, focus on the default instance. Log if multiple instances are suspected. VRF support can be a future enhancement.

**12. Open Questions**

*   What is the preferred string representation for `bgpPeerState` values (e.g., "Established", "Idle", "Connect")? (Use standard strings as per RFC 4271).
*   How to handle BGP peers where `bgpPeerIdentifier` (remote router ID) is 0.0.0.0 (can happen before fully established)? (Report as is, or potentially use `bgpPeerRemoteAddr` as a fallback for `neighbor_system_name`).
*   For `local_device_id` in `topology_discovery_events`, should we use the `bgpIdentifier` (local router ID) or the device's `sysName`? (Local BGP Router ID is more specific for BGP context).
