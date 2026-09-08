## 1. Inventory and Datasvc API
- [x] 1.1 Add a datasvc object metadata listing RPC with prefix/domain filters, bounded page size, and pagination.
- [x] 1.2 Implement list support in `go/pkg/datasvc` without returning payload bytes.
- [x] 1.3 Add RBAC coverage and tests for object metadata listing.
- [x] 1.4 Add Elixir sync client support for the new list RPC.

## 2. Agent Release Retention
- [x] 2.1 Build an agent release artifact inventory from `AgentRelease.metadata["storage"]["artifacts"]` and datasvc object listing under `agent-releases/`.
- [x] 2.2 Implement a reference-aware planner that keeps the newest configured release count, defaulting to 5.
- [x] 2.3 Protect objects referenced by active/non-terminal rollouts, rollout targets, and current rollback paths.
- [x] 2.4 Delete eligible release objects through datasvc and record summary logs.

## 3. Plugin Package Retention
- [x] 3.1 Extend plugin storage with backend-level inventory for filesystem and JetStream storage.
- [x] 3.2 Build a plugin blob retention planner from `PluginPackage.wasm_object_key`, assignments, target policies, status, and backend inventory.
- [x] 3.3 Protect staged/approved packages and any package referenced by assignments or policies.
- [x] 3.4 Delete eligible denied/revoked/orphaned blobs through `Storage.delete_blob/1` and record summary logs.

## 4. Scheduling and Operations
- [x] 4.1 Add Oban maintenance worker(s) with uniqueness, dry-run support, and manual enqueue support.
- [x] 4.2 Add configuration for retention enablement, dry-run mode, schedule, release keep count, and plugin orphan grace period.
- [x] 4.3 Surface the cleanup jobs in the job catalog where supported.
- [x] 4.4 Document object namespaces, retention defaults, dry-run output, and production cleanup workflow.

## 5. Verification
- [x] 5.1 Add unit tests for datasvc object listing and RBAC.
- [x] 5.2 Add Elixir tests for release retention planning and protected rollout references.
- [x] 5.3 Add Elixir tests for plugin retention planning and protected assignment/policy references.
- [x] 5.4 Run focused Go and Elixir test suites.
- [x] 5.5 Run `openspec validate add-object-store-retention --strict`.
- [x] 5.6 Run `git diff --check`.
