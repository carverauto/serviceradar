### **Product Requirements Document: eBPF-based Network Monitoring Service**

**1. Introduction**

This document specifies the requirements for a new eBPF-based, on-demand network monitoring and capture service. This service will integrate with the existing ServiceRadar observability platform, leveraging its gRPC-based plugin architecture. The primary objective is to provide deep, process-centric visibility into network traffic on monitored hosts. This allows engineers to diagnose a wide range of issues, from application latency and unexpected network chatter to anomalous bandwidth consumption, by capturing granular network event data with minimal performance overhead.

**2. Core Objective**

While the platform has excellent data from network infrastructure (NetFlow, SNMP, Syslog), it lacks the crucial link to the specific processes on a host that are generating or receiving the traffic. When an issue is detected—whether it's an application exhibiting high latency, a security alert from a firewall log, or an anomalous traffic pattern identified by NetFlow—engineers need to answer the question: **"Which process is responsible, and what exactly is it doing on the network?"**

This service will provide the capability to dynamically start a "capture" on a specific host, filtered by process ID (PID), network port, or other criteria. It will collect and stream detailed network event data (e.g., connections, DNS requests, data transfer summaries) for analysis.

**3. Architecture & Workflow**

The architecture will mirror the eBPF Profiler, establishing a new, distinct service for network monitoring that the existing Agent communicates with.

**High-Level Workflow:**

1.  **Trigger Event:** A trigger event occurs. Examples include:
    *   An alert on a high-CPU process that is known to be network-bound.
    *   A NetFlow record showing anomalous traffic to/from a specific server IP.
    *   A syslog message indicating a potential security event (e.g., repeated connection attempts).
    *   A manual trigger by an operator investigating an issue.
2.  **Capture Command:** The platform directs the `Poller` to initiate a network capture on the target host, specifying the capture parameters (e.g., filter by PID, capture duration).
3.  **Command Relay (Poller -> Agent):** The `Poller` invokes a new `TriggerNetworkCapture` gRPC endpoint on the `Agent`, passing the capture parameters.
4.  **Command Relay (Agent -> eBPF Service):** The `Agent` relays this request by calling the `StartCapture` gRPC endpoint on the local `eBPF Network Monitor Service`.
5.  **eBPF Network Monitoring:** The `eBPF Network Monitor Service` (written in Rust with Aya) attaches eBPF probes to relevant kernel tracepoints and network stack functions (e.g., `tcp_connect`, `udp_sendmsg`, `security_socket_sendmsg`, and kernel functions for DNS). It collects network event metadata and stores it efficiently in eBPF maps.
6.  **Results Polling:** The `Poller` is configured to poll for a new service type, `network_capture`. It calls the `StreamResults` gRPC endpoint on the `Agent`.
7.  **Data Retrieval (Agent -> eBPF Service):** The `Agent`'s `StreamResults` implementation calls the `GetCaptureResults` endpoint on the `eBPF Network Monitor Service`.
8.  **Data Streaming:** The `eBPF Network Monitor Service` streams the structured network event data back to the `Agent`. The `Agent` uses its existing streaming and chunking logic to forward the data to the `Poller`.
9.  **Correlation & Analysis:** The central platform receives the data. It can enrich this data by correlating IP addresses with device information from the Network Mapper, providing a complete end-to-end view of the communication path.

---

**4. Feature Requirements**

**FR-1: eBPF Network Monitor Service**

*   **Technology:** A new standalone gRPC service written in Rust using the `aya-rs` framework.
*   **Functionality:**
    *   Attach eBPF probes to kernel functions to monitor network activity. This includes, but is not limited to:
        *   `connect`, `accept`, `close` syscalls to track connection lifecycles.
        *   TCP state transitions (`inet_sock_set_state`).
        *   Send/receive functions (`tcp_sendmsg`, `udp_sendmsg`) to capture traffic volume and associate it with a PID.
        *   Kernel-level DNS snooping to capture DNS requests/responses without relying on user-space libraries.
    *   Aggregate network data in eBPF maps, tracking flows by 5-tuple (source IP, dest IP, source port, dest port, protocol) and associating them with a PID and process name.
    *   On a `GetCaptureResults` call, read the aggregated data and format it into structured `NetworkEvent` messages for streaming.

**FR-2: gRPC Interface & Protobuf Definitions**

**A. New `network_monitor.proto` File:**

This proto will define the gRPC contract for the Rust-based network monitor service.

```protobuf
syntax = "proto3";

package network_monitor;

option go_package = "github.com/carverauto/serviceradar/proto/network_monitor";

// The eBPF Network Monitoring Service
service NetworkMonitorService {
    // Starts a new network capture session
    rpc StartCapture(StartCaptureRequest) returns (StartCaptureResponse) {}

    // Retrieves the results of a capture session as a stream of network events
    rpc GetCaptureResults(GetCaptureResultsRequest) returns (stream NetworkCaptureChunk) {}
}

message CaptureFilter {
    int32 process_id = 1;        // Optional: Filter by a specific PID
    int32 port = 2;              // Optional: Filter by a specific source or destination port
    string source_ip = 3;        // Optional: Filter by source IP address
    string destination_ip = 4;   // Optional: Filter by destination IP address
}

message StartCaptureRequest {
    CaptureFilter filter = 1;      // The filter to apply to the capture
    int32 duration_seconds = 2;    // How long to run the capture
    string session_id = 3;         // A unique ID for this capture session
}

message StartCaptureResponse {
    bool success = 1;
    string message = 2;
}

message GetCaptureResultsRequest {
    string session_id = 1;
}

// Represents a single observed network event
message NetworkEvent {
    int64 timestamp_ns = 1;     // Nanosecond timestamp of the event
    int32 process_id = 2;       // PID of the process
    string process_name = 3;    // Command name of the process
    string source_addr = 4;     // Source IP:Port
    string dest_addr = 5;       // Destination IP:Port
    int64 bytes_sent = 6;       // Bytes sent during the event/flow
    int64 bytes_received = 7;   // Bytes received during the event/flow
    string event_type = 8;      // "CONNECT", "ACCEPT", "DATA", "DNS_QUERY", "DNS_RESPONSE"
    string extra_info = 9;      // e.g., DNS query name or response IPs
}

message NetworkCaptureChunk {
    repeated NetworkEvent events = 1; // A chunk of network events
    bool is_final = 2;                // True if this is the last chunk
    int32 chunk_index = 3;            // The index of this chunk
}
```

**B. Modifications to `proto/monitoring.proto`:**

The existing `AgentService` will be extended to allow the `Poller` to trigger network captures.

```protobuf
// In service AgentService { ... }
// New RPC to start a network capture session via the agent
rpc TriggerNetworkCapture(TriggerNetworkCaptureRequest) returns (TriggerNetworkCaptureResponse) {}

// New Messages
message TriggerNetworkCaptureRequest {
    string agent_id = 1;
    string poller_id = 2;
    int32 process_id = 3;       // Optional: Filter by a specific PID
    int32 port = 4;             // Optional: Filter by a specific port
    int32 duration_seconds = 5; // How long to run the capture
}

message TriggerNetworkCaptureResponse {
    bool success = 1;
    string message = 2;
    string session_id = 3; // The unique ID for this capture session
}
```

**FR-3: Agent Integration (`pkg/agent`)**

*   The agent's configuration will be updated to include the address of the `eBPF Network Monitor Service`.
*   **Implement `TriggerNetworkCapture`:** The `AgentService` will implement this new RPC. It will call the `NetworkMonitorService.StartCapture` endpoint and return the session ID to the poller.
*   **Update `StreamResults`:** The method will be enhanced to handle `req.ServiceType == "network_capture"`. It will extract the `session_id` from the request and call the `NetworkMonitorService.GetCaptureResults` streaming RPC, proxying the data back to the poller using the existing chunking infrastructure.

**FR-4: Data Correlation & Enrichment**

*   The data collected by the eBPF service (IPs, ports) is valuable, but its value is multiplied when correlated with existing platform data.
*   The `NetworkEvent` data should be sent to a central processing pipeline that can:
    *   Use the **Network Mapper** data to translate a destination IP into a known device name, interface, and location (e.g., "10.1.1.1" -> "core-switch-01:Gi1/0/24").
    *   Correlate flow data with **NetFlow** records to see if a process-level flow matches a larger, anomalous pattern observed on the network fabric.
    *   Cross-reference event timestamps with **Syslog** and **OTEL** logs to provide a holistic view of an incident.

**5. Non-Functional Requirements**

*   **Performance:** The eBPF programs must be highly efficient, adding negligible latency to network operations on the monitored host.
*   **Security:** Communication between the `Agent` and the `eBPF Network Monitor Service` must be secured with mTLS, reusing the existing `SecurityConfig` framework.
*   **Data Volume:** The service must handle high-volume network events. The aggregation in eBPF maps is key to this, as is the streaming and chunking mechanism for returning results.

**6. Out of Scope**

*   The UI for triggering captures and visualizing network data (e.g., flow diagrams, tables).
*   Deep Packet Inspection (DPI) of encrypted (TLS/IPsec) traffic payloads. This service focuses on connection metadata and unencrypted protocol data like DNS.
*   Automated, rule-based triggering logic. The initial implementation will rely on manual or simple API-based triggers.