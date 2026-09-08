## 1. Design And Dependency Review
- [x] 1.1 Review candidate SFTP library license, transitive dependencies, Bazel/module impact, and maintenance status.
- [x] 1.2 Define file-transfer frame types and payload schemas for request, progress, data, ack, error, and outcome.
- [x] 1.3 Define durable transfer resource/event schemas and retention behavior.
- [x] 1.4 Define content-audit artifact storage as explicitly disabled by default.

## 2. Policy, RBAC, And API
- [x] 2.1 Add file-transfer RBAC permissions for list, download, upload, manage, approve, and export.
- [x] 2.2 Add policy evaluation for operation allowlists, path rules, symlink behavior, quotas, approval, and redaction.
- [x] 2.3 Add browser/API endpoints that accept only bounded transfer intent fields.
- [x] 2.4 Reject route, agent, gateway, target host, credential rule, custody, recording, quota, and approval overrides from client requests.

## 3. Routing And Agent Adapter
- [x] 3.1 Add gateway/agent transfer routing over the selected remote-access session route.
- [x] 3.2 Add agent-side SFTP adapter using existing SSH custody and host-key trust paths.
- [x] 3.3 Enforce policy and quotas in the agent before and during target file operations.
- [x] 3.4 Advertise `remote_access.file_transfer` and `remote_access.sftp` only when policy enforcement is available.

## 4. Recording, Audit, And Replay
- [x] 4.1 Persist transfer lifecycle metadata without file contents by default.
- [x] 4.2 Emit replay events for request, start, progress, completion, denial, and failure.
- [x] 4.3 Add audit events for allowed, denied, canceled, failed, and quota-exhausted transfers.
- [x] 4.4 Add content-audit artifact references only when explicit policy enables retention.

## 5. UI And Demo Proof
- [x] 5.1 Add operator/user UI for listing directories and launching allowed uploads/downloads.
- [x] 5.2 Add approval UI hooks for sensitive transfer requests.
- [x] 5.3 Add demo proof against an OpenSSH target configured with `TrustedUserCAKeys`.

## 6. Validation
- [x] 6.1 Add unit tests for policy, path rules, symlink behavior, quota exhaustion, approval, and redaction.
- [x] 6.2 Add API/channel tests proving client override fields are rejected.
- [x] 6.3 Add gateway/agent route-binding tests for transfer frames.
- [x] 6.4 Add agent adapter tests for list, download, upload, mutation operations, cancellation, and partial transfer cleanup.
- [x] 6.5 Add recording/replay/audit tests proving file contents are not persisted by default.
- [x] 6.6 Run focused Go and Elixir tests for touched packages plus OpenSpec validation.
