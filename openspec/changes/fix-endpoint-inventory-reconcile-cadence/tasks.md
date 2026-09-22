## 1. Producer cache policy
- [x] 1.1 Split collection-skip from reconcile-upload in `go/pkg/endpointinventory`.
- [x] 1.2 Replay a cached full changed upload when collection can be skipped and reconcile is outstanding.
- [x] 1.3 Wire the shared decision into the legacy collector and the ScaLibr runner.
- [x] 1.4 Tests: collection skip remains true during reconcile; full scan skip stays false; reconcile replay uploads changed+SBOM with cached hashes and does not require source mtime change; cadence skip still emits unchanged when no reconcile is outstanding.

## 2. Agent ack order
- [x] 2.1 Apply upload successes before reconcile directives.
- [x] 2.2 Ignore a reconcile-floor directive on a response that acknowledges a full changed upload.
- [x] 2.3 Tests for ack-then-directive and ignore-on-full-upload-ack.

## 3. Core ingest directives
- [x] 3.1 Emit `reconcile_floor` only when this observation newly crosses the floor.
- [x] 3.2 Duplicate/short-circuit ingest SHALL NOT re-send the directive for a row that is already due.
- [x] 3.3 Tests covering first crossing (directive present) and a later duplicate (directive absent).

## 4. Add-on version
- [x] 4.1 Bump `scalibr-endpoint-inventory` (0.1.7 -> 0.1.8 on top of skip-dirs).

## 5. Validation
- [x] 5.1 `openspec validate fix-endpoint-inventory-reconcile-cadence --strict`
- [x] 5.2 Focused Go tests for `endpointinventory`, `scalibrinventory`, and agent upload-ack
