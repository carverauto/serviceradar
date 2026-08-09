## 1. Bazel and Make configuration
- [x] 1.1 Point `build:cache_proxy` at the public `grpcs` endpoint and preserve the upstream
      bytestream URI prefix.
- [x] 1.2 Keep default build/test profiles unchanged and add inherited
      `build-workspace-cache` / `test-cache` Make targets.

## 2. Operational contract
- [x] 2.1 Update the BuildBuddy runbook and values comments for the public TLS/private Service
      boundary, native authentication, and secret custody.
- [x] 2.2 Remove the obsolete ClusterIP workflow probe and document the staged authenticated
      canary without enabling the workflow opt-in.
- [x] 2.3 Document client-first rollback while preserving the direct executor cache path.

## 3. Drift prevention and verification
- [x] 3.1 Add a Bazel static test covering the TLS endpoint, bytestream prefix, profile isolation,
      remote-rc precedence, inherited Make targets, and disabled workflow opt-in.
- [x] 3.2 Run the focused Bazel test and dry-run both normal and cache-enabled Make targets.
- [x] 3.3 Run `openspec validate route-bazel-cache-through-shared-edge --strict`.
- [x] 3.4 Run `git diff --check` and review the final scoped diff.
