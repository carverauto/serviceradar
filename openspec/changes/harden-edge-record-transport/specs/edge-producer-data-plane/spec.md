# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Finite routing survives contract and credit pressure
The deployment SHALL keep the route map finite and the lanes independently pooled under pressure, so that neither contract count nor a blocked lane degrades the others.

The finite route-profile and traffic-class enums are frozen by the edge record v1
wire ABI. This requirement owns their operational consequences: lane, subject,
physical stream, connection, consumer, process, and RAFT-group cardinality SHALL
NOT grow with payload kind, package, plugin, integration, or output-contract count.
V1 SHALL begin with disjoint bulk/interactive physical streams; another profile
requires an explicit benchmarked platform change.

#### Scenario: A package defines many output contracts
- **WHEN** thousands of approved contracts share the durable record plane
- **THEN** the trusted binary contract envelope SHALL dispatch them over the
  finite route map
- **AND** the deployment SHALL NOT create thousands of lanes, subjects, streams,
  consumers, connections, processes, or RAFT groups

#### Scenario: Bulk transport is blocked
- **WHEN** a bulk lane exhausts its HTTP/2, publisher, stream, or database credits
- **THEN** separately pooled interactive and recovery lanes SHALL continue
- **AND** no unresolved bulk sequence SHALL be skipped or promoted

