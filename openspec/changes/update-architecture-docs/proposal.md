# Change: Update architecture documentation for core-elx and edge ingestion

## Why
The current platform architecture (core-elx, agent-gateway ingestion flow, and configuration delivery paths) is not reflected consistently in the documentation. This proposal aligns the documentation with the current control plane and edge data flow, and removes outdated references that confuse deployment guidance.

## What Changes
- Update architecture docs to describe core-elx, agent-gateway, and gRPC push/streaming flows.
- Clarify the agent’s consolidated capabilities and data paths.
- Clarify configuration delivery: agents/checkers use gRPC config from core-elx via agent-gateway; collectors rely on filesystem config.
- Refresh architecture diagrams and README component lists to match the current services.
- Clarify install guidance: Kubernetes and Docker Compose are preferred; standalone installs are limited to edge components.
- Remove multi-tenancy references from architecture documentation language while preserving isolation concepts.

## Impact
- Affected specs: edge-architecture, agent-connectivity, agent-configuration, kv-configuration.
- Affected docs: docs/docs/architecture.md, README.md, and installation/overview docs describing deployment and component topology.
