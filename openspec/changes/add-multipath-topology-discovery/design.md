# Design: Multipath Topology Discovery

## Context
Standard discovery tools often fail to capture the complexity of modern networks that use ECMP. Diamond-Miner (D-Miner) introduced an efficient algorithm for discovering these topologies by using statistical bounds to determine how many probes are needed at each hop (TTL) to discover all interfaces with high confidence.

## Goals
- Efficiently discover internal multipath topologies.
- Re-use existing high-performance scanning infrastructure in `serviceradar-agent`.
- Integrate results into the Apache AGE graph for visualization.

## Decisions

### 1. Probing Engine
We will implement a new `MultipathScanner` in `pkg/scan` that builds upon the existing `ICMPSweeper` and `SYNScanner`.
- **Protocol**: Support both UDP and ICMP Echo probes. UDP is often preferred as routers more consistently hash on destination ports.
- **Flow Identification**: 
    - For UDP: Vary the destination port.
    - For ICMP: Vary the ICMP sequence number or Identifier (depending on platform support for hashing).
- **TTL Strategy**: Adaptive TTL probing. Instead of a linear sweep, we will use the D-Miner algorithm to determine the number of flows to probe at each TTL.

### 2. D-Miner Algorithm Adaptation
- **Initial Probes**: Start with 6 flows per TTL (which provides ~95% confidence for discovering 2-way ECMP).
- **Iteration**: For each TTL, if $n$ interfaces are discovered with $k$ probes, use the MDA (Multipath Detection Algorithm) stopping condition to decide if more probes are needed.
- **Randomization**: Use randomized flow identifiers to ensure uniform coverage of the hash space.

### 3. Data Schema
- **TopologyLink**: Extend with `FlowID` (e.g., source/dest port) and `ProbeType` (UDP/ICMP).
- **Apache AGE**: Use the `FlowID` as a property on the edge. Represent multiple paths as separate edges between the same nodes if they belong to different flows.

### 4. Integration with Mapper
The `Mapper` will orchestrate the discovery jobs. A new `DiscoveryTypeMultipath` will trigger the `MultipathScanner`. The mapper will collect `ICMP Time Exceeded` responses and `ICMP Destination Unreachable` (for the final hop) to reconstruct the paths.

## Risks / Trade-offs
- **Network Load**: Multipath discovery requires significantly more probes than standard traceroute. We must allow users to configure the `probing_rate` to avoid overwhelming network devices or triggering IDS.
- **Router Support**: Some routers might not respond to probes with high TTLs or might rate-limit ICMP messages.
- **Graph Complexity**: Multipath topologies can result in very dense graphs. The UI must provide effective ways to collapse or expand these "diamonds".

## Migration Plan
1. Add the new types and scanners.
2. Update the Elixir core to support the new job type.
3. Deploy the updated agent.
4. Existing discovery jobs will remain unaffected.
