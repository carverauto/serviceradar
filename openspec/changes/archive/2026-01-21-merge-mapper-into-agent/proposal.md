# Change: Merge mapper discovery into serviceradar-agent

## Why
Running a standalone mapper service increases deployment complexity and splits discovery configuration across multiple control paths. Merging mapper discovery into the agent reduces operational overhead and lets the control plane manage discovery jobs via the same agent-gateway gRPC channel used for other checks.

## What Changes
- **BREAKING** Remove the standalone `serviceradar-mapper` binary, container, Helm/Compose manifests, and Bazel build targets.
- Add agent-embedded mapper discovery execution with gRPC-based config delivery from core-elx via agent-gateway.
- Add gRPC result submission for mapper discovery jobs (PushResults) routed through agent-gateway to core ingestion.
- Extend mapper ingestion to persist discovered interfaces and topology links, and project them into an Apache AGE graph in CNPG.
- Introduce Ash resources for mapper discovery jobs and credentials, stored in CNPG with AshCloak encryption.
- Add Settings → Networks → Discovery UI for creating and scheduling mapper jobs, including seeds and SNMP/API credentials (Ubiquiti).
- Update documentation to reflect the new discovery workflow and deployment changes.

## Impact
- Affected specs: `agent-config`, `edge-architecture`, new `network-discovery`
- Affected code: `cmd/mapper`, `pkg/mapper`, `cmd/agent`, agent-gateway/core-elx gRPC APIs, `web-ng` settings UI, Helm/Compose/Bazel build targets, docs
