## Context
The SSH remote-access foundation already provides the route, session, browser attach ticket, credential custody, SSH certificate, user-present credential, central grant, approval, host-key trust, recording, replay, and enhanced-recording boundaries needed for interactive terminals.

File transfer should be the next protocol expansion because it can reuse that foundation. It still needs its own proposal because file transfer adds direct data movement, path policy, quotas, content audit, and replay/export sensitivity that terminal streams do not fully cover.

## Goals
- Provide SFTP-style list, download, upload, and file-management operations for registered remote-access targets.
- Keep each transfer bound to one actor, one session or transfer intent, one selected agent/gateway route, one target, one protocol, and one credential grant.
- Reuse existing SSH custody modes without introducing agent-local reusable secrets.
- Enforce RBAC, approval, path policy, and quotas before the agent opens or mutates a target file handle.
- Record transfer lifecycle metadata for audit and replay without storing file contents by default.
- Keep SCP as compatibility only; SFTP is first because it exposes structured operations.

## Non-Goals
- Do not provide arbitrary agent-side file browsing by client-supplied host, route, or credential rule.
- Do not store file contents in session recordings by default.
- Do not add recursive sync, rsync-style delta transfer, or large artifact pipelines in the first slice.
- Do not implement SCP unless it maps into the same transfer manager and policy path.
- Do not import current Teleport SFTP/SCP implementation code.

## Architecture
File transfer uses the existing remote-access route:

```text
browser/API
  -> web-ng remote access file-transfer API
  -> core policy/session/approval/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream
  -> agent SFTP adapter
  -> target SSH/SFTP subsystem
```

The browser/API request accepts only narrow intent:

- target or existing remote-access session reference
- operation: `list`, `stat`, `download`, `upload`, `mkdir`, `rename`, `remove`, `chmod`, `chown`
- path intent and optional destination path
- transfer direction
- optional client-side filename metadata for display

The browser/API must not accept route, agent, gateway, target host override, credential rule, custody mode, approval override, recording policy, content-audit policy, quota, or upstream SSH configuration. Those values come from trusted inventory, remote-access policy, and the approved session or transfer intent.

## RBAC
Planned permissions:

- `devices.remote_access.files.list`: directory listing and metadata reads.
- `devices.remote_access.files.download`: file reads from the target.
- `devices.remote_access.files.upload`: file writes to the target.
- `devices.remote_access.files.manage`: mkdir, rename, remove, chmod, chown, and similar mutating operations.
- `devices.remote_access.files.approve`: reviewer workflow for transfers that policy marks as sensitive.
- `devices.remote_access.files.export`: export retained content-audit artifacts when artifact retention is explicitly enabled.

## Policy
Policy gates are evaluated centrally before dispatch and revalidated by the agent before file handles are opened:

- operation allowlists by actor, role, target, protocol, and custody mode
- path allow/deny rules
- path redaction rules for UI, audit, and replay
- symlink behavior: deny, follow inside root, or explicit allow
- realpath validation and root containment
- upload overwrite behavior
- executable-bit and ownership mutation policy
- byte quotas, file-count quotas, single-file size limits, recursive-depth limits, transfer-rate limits, and concurrent-transfer limits
- approval requirements for risky operations or sensitive paths
- optional content audit: hashing, malware/DLP hook, artifact retention, and export controls

Fail closed when a path cannot be normalized, a symlink cannot be resolved according to policy, quota state is unavailable, approval is missing, or target capability is unknown.

## Durable Model
The first implementation should add a typed transfer record such as `RemoteAccessFileTransfer`, or an equivalent typed event stream if that better matches the existing recording model.

The durable record should include:

- transfer ID
- remote access session ID or transfer intent ID
- actor ID
- target device/ref
- selected agent and gateway route
- operation and direction
- target path, redacted path, or path hash according to policy
- destination path for rename/copy-like operations
- byte count and file count
- SHA-256 when enabled
- policy snapshot and decision
- quota counters
- approval reference when required
- content-audit artifact reference when explicitly retained
- status, failure reason, start/end timestamps, and retention expiry

Replay should show lifecycle events such as `transfer_requested`, `transfer_started`, `transfer_progress`, `transfer_completed`, `transfer_denied`, and `transfer_failed`. Replay and audit payloads must not include file contents by default.

## Agent Enforcement
The selected agent must enforce the final policy too, because it is the process that sees target filesystem semantics. Agent enforcement includes:

- validating operation and direction
- resolving and normalizing paths according to policy
- enforcing symlink behavior before open or mutation
- enforcing quotas during transfer, not only before transfer
- calculating hashes when enabled
- emitting progress and final status frames
- stopping transfers on session close, approval expiry, quota exhaustion, or policy cancellation

Agents advertise `remote_access.file_transfer` and `remote_access.sftp` only when they can enforce these rules locally. `remote_access.scp` remains absent until SCP compatibility exists through the same manager.

## Source Reuse
Current Teleport SFTP/SCP implementation paths are not approved for import:

- Current `~/src/teleport` commit `42a4eaafeefee26e52bbd32ceec9699de1e9040c` scans show AGPL direct or transitive paths for `lib/srv`, `lib/srv/ssh`, `lib/sshutils/sftp`, `session/sftputils`, and `lib/sshutils/scp`.
- Teleport `v14.4.0` scans are useful historical evidence but do not approve copying stale server subsystems.

Default implementation path:

- use ServiceRadar-owned clean-room file-transfer manager and protocol frame model
- use `github.com/pkg/sftp` for the Go SFTP client adapter after dependency import:
  - latest reviewed version: `v1.13.10`, published 2025-10-22
  - license: BSD-style permissive license, compatible with Apache-2.0 distribution
  - runtime dependency impact: `github.com/kr/fs` plus existing `golang.org/x/crypto`/`golang.org/x/sys` family; test-only deps from upstream do not need to enter ServiceRadar runtime packages
  - maintenance note: `github.com/kr/fs v0.1.0` is a dormant transitive shim from `github.com/pkg/sftp`; keep it only through the SFTP dependency path and re-review it on every `github.com/pkg/sftp` bump
  - Bazel impact: add `github.com/pkg/sftp` to `go.mod`, refresh `go.sum`, add `com_github_pkg_sftp` and `com_github_kr_fs` to `MODULE.bazel` after `bazel mod tidy`, and add the adapter dependency to `go/pkg/agent/remoteaccess/BUILD.bazel`
- keep Teleport source as behavior reference only unless a future exact-file vendoring review is approved

## Validation
Required validation before implementation is considered complete:

- policy unit tests for operations, path rules, symlink behavior, quotas, approval gates, and redaction
- API/channel tests proving browser requests cannot supply route, credential, custody, recording, quota, approval, or host override fields
- gateway/agent tests proving transfer frames are accepted only from the session-owning selected route
- agent adapter tests for list, download, upload, mkdir, rename, remove, chmod/chown where supported, quota exhaustion, partial transfer, and cancellation
- recording/replay tests proving metadata is retained and file contents are not persisted unless content-audit policy explicitly enables artifact retention
- audit tests proving denials and failures are redacted
- demo proof path using an OpenSSH target configured for ServiceRadar SSH CA authentication
