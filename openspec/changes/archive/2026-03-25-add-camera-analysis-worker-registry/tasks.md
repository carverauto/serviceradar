## 1. Registry
- [x] 1.1 Add a platform-owned camera analysis worker registry.
- [x] 1.2 Support registering workers with identity, endpoint, adapter, and capability metadata.
- [x] 1.3 Support resolving a worker by explicit id or simple capability match for relay-scoped analysis branches.

## 2. Dispatch Integration
- [x] 2.1 Integrate worker resolution into the existing analysis dispatch path.
- [x] 2.2 Preserve relay session, branch, and worker provenance through result ingestion and telemetry.
- [x] 2.3 Surface unavailable or mismatched worker selection as explicit bounded failures.

## 3. Verification
- [x] 3.1 Add focused tests for worker registration, selection, and dispatch resolution.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-registry --strict`.
