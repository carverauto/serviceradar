## 1. Boombox Adapter
- [x] 1.1 Add a Boombox-backed analysis adapter in `core-elx`.
- [x] 1.2 Bind the adapter to relay-scoped analysis branches without duplicate upstream camera pulls.
- [x] 1.3 Keep adapter load bounded and subordinate to viewer playback.

## 2. Result Integration
- [x] 2.1 Normalize Boombox-backed worker outputs through the existing analysis result contract.
- [x] 2.2 Preserve relay session, branch, and worker provenance through observability ingestion.

## 3. Verification
- [x] 3.1 Add focused tests for the Boombox adapter lifecycle and bounded behavior.
- [x] 3.2 Validate the change with `openspec validate add-boombox-camera-analysis-adapter --strict`.
