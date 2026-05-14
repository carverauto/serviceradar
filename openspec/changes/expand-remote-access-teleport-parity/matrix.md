# Remote Access Internal Capability Matrix

ServiceRadar has an agent-routed remote access foundation. It does not yet have full remote-access product parity. This OpenSpec note is an internal capability matrix for remaining work and source-reuse decisions. It is not public product documentation.

The active OpenSpec change is `expand-remote-access-teleport-parity`.

## Status Terms

- `Implemented`: available in ServiceRadar today.
- `Planned`: accepted as a ServiceRadar capability, but not implemented yet.
- `Separate proposal required`: too large or sensitive for opportunistic implementation; requires protocol threat model, route model, custody model, recording/export policy, validation plan, and demo proof path.
- `License blocked`: current Teleport implementation path has AGPL headers or an AGPL transitive package path and cannot be imported into ServiceRadar.
- `Reference only`: useful for understanding behavior, but not approved for copying or vendoring.
- `Out of scope`: not currently planned for ServiceRadar.

## Capability Matrix

| Teleport feature area | ServiceRadar status | Next ServiceRadar slice | Source reuse decision |
| --- | --- | --- | --- |
| SSH browser terminal | Implemented foundation | Hardening and UX polish | ServiceRadar-owned implementation. Current Teleport server paths are license blocked. |
| OpenSSH user certificates | Implemented foundation | Authentik/OpenSSH smoke coverage and richer trait mapping | ServiceRadar-owned SSH CA code. Teleport v14 architecture is reference only. |
| Agent-routed private-network access | Implemented foundation | Route observability, operational docs, and failure diagnostics | ServiceRadar-owned. Teleport reverse tunnel code is not approved for import. |
| Host key trust and TOFU lifecycle | Implemented foundation | More operator review and rotation workflows | ServiceRadar-owned. Teleport behavior may inform tests only. |
| Proxmox PVE host shell | Implemented as SSH-backed console | Native VM/LXC console connector later | ServiceRadar-owned provider adapter. |
| Native Proxmox VM/LXC console | Planned | Separate Proxmox console proposal | Do not use Teleport source; use Proxmox API docs and ServiceRadar adapter boundary. |
| SFTP file transfer | Implemented | Demo hardening and SCP compatibility only if it can share the same policy, quota, recording, and audit manager | Implemented as ServiceRadar-owned clean-room code using `github.com/pkg/sftp`. Current Teleport `lib/sshutils/sftp`, `session/sftputils`, `lib/sshutils/scp`, and server dependencies remain license blocked. |
| SCP file transfer | Planned | Separate compatibility slice after SFTP matures | Do not import Teleport SCP paths. Any SCP implementation must map into the same file-transfer manager and policy surface as SFTP. |
| Application and TCP access | Separate proposal required | Registered upstreams, SSRF controls, origin isolation, TLS policy | Current Teleport `lib/srv/app` and reverse-proxy paths are license blocked. Clean-room implementation required. |
| Database access | Separate proposal drafted | `add-remote-access-database`: short-lived DB credentials or mTLS, query/session audit, byte/result policy | Current Teleport `lib/srv/db` path is license blocked. Clean-room implementation required. |
| Kubernetes API, logs, exec, port-forward | Separate proposal drafted | `add-remote-access-kubernetes`: identity impersonation or short-lived client certificates, namespace/resource/verb scope | Current Teleport Kubernetes proxy path is license blocked. Clean-room implementation required. |
| Desktop/RDP | Separate proposal drafted | `add-remote-access-desktop-rdp`: renderer, redirection controls, bandwidth quotas, recording policy | Current Teleport `lib/srv/desktop` path is license blocked. Evaluate protocol libraries separately. |
| vSphere console and cloud console/API | Separate proposal required | Provider-specific route, credential, and demo proof path | Treat Teleport cloud/provider access code as reference only until individually scanned. |
| MCP access | Separate proposal required | Target registry, tool/session policy, audit semantics | Current Teleport MCP paths are license blocked. Clean-room implementation required. |
| Access requests and approvals | Implemented foundation | External approval integrations and richer reviewer policy | ServiceRadar-owned resources. Teleport approval UX is reference only. |
| Per-session MFA | Planned | Identity-governance proposal | Current Teleport MFA/auth packages are license blocked by transitive dependencies. Clean-room integration with ServiceRadar auth/IdP required. |
| SCIM/provisioning, identity locks, device trust | Planned | Enterprise identity-governance proposal | Current Teleport identity/device-trust packages are not approved for import. |
| Live session inventory and forced termination | Planned | Collaboration/moderation proposal | Current Teleport moderation/session-control paths are license blocked. Clean-room implementation required. |
| Session sharing and reviewer join | Planned | Collaboration/moderation proposal | Current Teleport moderation/session-control paths are license blocked. Clean-room implementation required. |
| Session replay and transcript export | Implemented foundation for policy-gated event storage/API/UI | Search, summaries, SIEM export, storage hardening | ServiceRadar-owned recording model. Current Teleport recording/event packages are license blocked. |
| Enhanced recording: command/file/network telemetry | Implemented foundation and procfs fallback; production BPF planned | ServiceRadar-owned cilium/ebpf probes, kernel matrix, high-volume loss tests | Current Teleport `lib/bpf` is license blocked. Teleport v14 BPF can be architecture reference only unless a future vendoring review approves a small isolated subset. |
| Windows/Desktop enhanced events | Planned | Requires platform-specific proposal and test environment | No approved Teleport source reuse. |
| OT protocols such as CEA-852/CN-IP | Out of scope until representative test data exists | Passive/read-only OT proposal only after test data | No Teleport source relevance. |

## Source Reuse Rules

Before any Teleport import, copy, or vendoring:

1. Record the exact Teleport checkout, tag, commit, and file paths.
2. Scan direct and transitive Teleport package directories. Direct file headers are not enough.
3. Record the scan command and summarized output in the ServiceRadar change.
4. Do not copy, translate, or mechanically port AGPL Teleport implementation source.
5. Prefer current Apache-clean packages for small utility surfaces.
6. Use old Apache-era Teleport source only when it is small, isolated, maintainable, and explicitly reviewed.
7. Default to clean-room ServiceRadar code for large server, proxy, recording, BPF, and protocol-adapter subsystems.

The scanner is:

```bash
scripts/check-teleport-license-paths.sh <go-import-path> [...]
```

Set `TELEPORT_SRC=/path/to/teleport` to scan a different clone. Set `TELEPORT_REF=<tag-or-commit>` to scan a detached worktree without mutating the local Teleport checkout.

## Current Teleport Evidence

Local Teleport checkout:

```text
path: ~/src/teleport
remote: git@github.com:gravitational/teleport.git
current ref: master
current commit: 42a4eaafeefee26e52bbd32ceec9699de1e9040c
describe: api/v19.0.0-prealpha.2-769-g42a4eaafee
```

Apache-era baseline used for comparison:

```text
tag: v14.4.0
commit: 8113e07dc94cf2977247346d5ec28ca0d5753c54
commit date: 2025-05-20 19:20:37 +0000
repository LICENSE at tag: Apache License 2.0
```

Current checkout scan command:

```bash
scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/api/ssh \
  github.com/gravitational/teleport/api/observability/tracing/ssh \
  github.com/gravitational/teleport/lib/srv \
  github.com/gravitational/teleport/lib/srv/ssh \
  github.com/gravitational/teleport/lib/srv/db \
  github.com/gravitational/teleport/lib/srv/app \
  github.com/gravitational/teleport/lib/kube/proxy \
  github.com/gravitational/teleport/lib/bpf
```

Current checkout result summary:

```text
exit=1
api/ssh: AGPL transitive directories, including api/utils/iterutils, api/gen/proto/go/teleport/hardwarekeyagent/v1, api/types.
api/observability/tracing/ssh: AGPL transitive directories, including api/utils/iterutils, api/gen/proto/go/teleport/hardwarekeyagent/v1, api/types.
lib/srv: many AGPL direct and transitive directories, including lib/srv, lib/bpf, lib/sshutils/sftp, session/sftputils, lib/sshutils/scp, recording/event/session packages, auth packages, and service config packages.
lib/srv/ssh: AGPL direct and transitive directories, including lib/srv/ssh.
lib/srv/db: AGPL transitive directories across auth, service config, DB, cloud, event, and inventory packages.
lib/srv/app: AGPL direct and transitive directories, including lib/srv/app, app common, reverse proxy, MCP utilities, and service config packages.
lib/kube/proxy: AGPL transitive directories across auth, service config, proxy, app, cloud, and event packages.
lib/bpf: AGPL direct files in lib/bpf.
```

`v14.4.0` scan command:

```bash
TELEPORT_REF=v14.4.0 scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/api/ssh \
  github.com/gravitational/teleport/api/observability/tracing/ssh \
  github.com/gravitational/teleport/lib/srv \
  github.com/gravitational/teleport/lib/srv/ssh \
  github.com/gravitational/teleport/lib/srv/db \
  github.com/gravitational/teleport/lib/srv/app \
  github.com/gravitational/teleport/lib/kube/proxy \
  github.com/gravitational/teleport/lib/bpf
```

`v14.4.0` result summary:

```text
exit=1
api/ssh: UNKNOWN, package unavailable or go list failed at v14.4.0.
api/observability/tracing/ssh: OK, no AGPL headers found in Teleport dependency directories.
lib/srv: OK, no AGPL headers found in Teleport dependency directories.
lib/srv/ssh: UNKNOWN, package unavailable or go list failed at v14.4.0.
lib/srv/db: OK, no AGPL headers found in Teleport dependency directories.
lib/srv/app: OK, no AGPL headers found in Teleport dependency directories.
lib/kube/proxy: OK, no AGPL headers found in Teleport dependency directories.
lib/bpf: OK, no AGPL headers found in Teleport dependency directories.
```

The old-tag scan proves some v14 package trees did not contain AGPL headers in the scanned dependency directories. It does not approve copying them. For large stale subsystems such as SSH server, SFTP/SCP, app proxy, database proxy, Kubernetes proxy, and BPF, the default ServiceRadar path remains clean-room implementation unless a future proposal records exact files, headers, dependency graph, maintenance risk, and approval.

## Next Implementation Order

1. Application/TCP access for registered upstreams only.
2. Database adapters with short-lived credentials or mTLS and query/session audit.
3. Kubernetes API/logs/exec/port-forward with actor-preserving identity.
4. Live session inventory, forced termination, reviewer join, and moderation.
5. Production recording search/export/SIEM pipeline and redaction maturation.
6. Production cilium/ebpf command/file/network probes and kernel support runbook.
7. SCP compatibility only if it can share the SFTP file-transfer policy and audit model.
