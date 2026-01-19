## 1. Discovery config + data model
- [x] 1.1 Define Ash resources for mapper discovery jobs, seed inputs, and credential stores (SNMP + API).
- [x] 1.2 Add AshCloak-backed encryption for sensitive credential fields and redaction behavior for API responses.
- [x] 1.3 Implement migration from legacy KV `config/mapper.json` to the new Ash resources (one-time).

## 2. Agent config compilation + delivery
- [x] 2.1 Extend the agent config compiler to emit mapper discovery config from Ash resources.
- [x] 2.2 Add/extend agent-gateway/core-elx gRPC endpoints to serve mapper config to agents (config_type = mapper).
- [x] 2.3 Update agent to load mapper config from gateway (with cache + no-change semantics).

## 3. Mapper execution + results ingestion
- [x] 3.1 Embed mapper discovery execution within `serviceradar-agent` and wire job scheduling.
- [x] 3.2 Add gRPC result submission for mapper discovery (PushResults) and core ingestion routing.
- [x] 3.3 Ingest mapper interface and topology results into CNPG (Ash resources + storage).
- [x] 3.4 Project mapper topology data into an Apache AGE graph with idempotent upserts.
- [x] 3.5 Add observability around mapper job status and errors for UI consumption.

## 4. Web UI
- [x] 4.1 Add Settings → Networks → Discovery tab for mapper jobs.
- [x] 4.2 Build job editor for seeds, intervals, partitions/agents, and discovery mode (SNMP/API).
- [x] 4.3 Add UI support for Ubiquiti API discovery settings.
- [x] 4.4 Ensure credential fields are masked and persisted safely without clobbering secrets.

## 5. Remove mapper deployment artifacts
- [x] 5.1 Remove `cmd/mapper` binary, Bazel build targets, and docker image wiring.
- [x] 5.2 Remove Helm/Compose mapper manifests, SPIFFE IDs, and service accounts.
- [x] 5.3 Update config registry entries and docs to remove mapper service references.

## 6. Tests + docs
- [x] 6.1 Add/adjust tests for mapper config compilation and gRPC delivery.
- [x] 6.2 Add UI tests or smoke coverage for discovery job CRUD and credential masking.
- [ ] 6.3 Update docs/runbooks to reflect agent-based discovery and mapper removal.
