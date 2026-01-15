## 1. Documentation updates
- [ ] 1.1 Update `docs/docs/architecture.md` to reflect core-elx, agent-gateway, and agent push/streaming ingestion as the baseline architecture.
- [ ] 1.2 Refresh architecture diagrams (Mermaid) to match the new component topology and data flow.
- [ ] 1.3 Update `README.md` component list and architecture overview to match current services (core-elx, agent-gateway, web-ng).
- [ ] 1.4 Update installation guidance to prefer Kubernetes or Docker Compose, and clarify standalone support is limited to edge agents/checkers.
- [ ] 1.5 Remove multi-tenancy mentions from architecture documentation while keeping isolation/identity wording accurate.
- [ ] 1.6 Update docs that describe config delivery to reflect gRPC config compilation and filesystem-only collectors.

## 2. Spec deltas
- [ ] 2.1 Update edge-architecture spec delta.
- [ ] 2.2 Update agent-connectivity spec delta.
- [ ] 2.3 Update agent-configuration spec delta.
- [ ] 2.4 Update kv-configuration spec delta.

## 3. Validation
- [ ] 3.1 Run `openspec validate update-architecture-docs --strict`.
