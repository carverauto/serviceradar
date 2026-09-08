## Context
ServiceRadar now has a native agent-routed access foundation, but Teleport covers a much larger product surface: SSH, Kubernetes, databases, applications/TCP, desktops/RDP, cloud/API access, file transfer, session sharing, per-session MFA, identity governance, recording search/summaries, audit export, and production enhanced recording.

This change intentionally keeps that work out of the foundation PR. The goal is to sequence parity work into smaller proposals that are possible to review, test, and deploy independently.

## Goals
- Maintain a clear capability matrix between Teleport and ServiceRadar.
- Add missing parity features incrementally without weakening the certificate-first, route-bound, no-shared-bastion-credential model.
- Keep each protocol adapter scoped to registered targets, selected agents, explicit RBAC, approval policy, and per-session credential grants.
- Continue using ServiceRadar-owned implementations unless a Teleport package or copied Apache-era source passes direct and transitive license review.

## Non-Goals
- Do not block merge of the existing SSH/agent-routed foundation on every Teleport-like feature.
- Do not create a generic arbitrary TCP bounce through the agent.
- Do not copy AGPL Teleport implementation code.
- Do not merge a protocol adapter without a protocol-specific threat model and demo proof path.

## Sequencing
Recommended order:

1. Build and maintain the Teleport capability matrix.
2. Land SFTP/SCP-style file transfer because it is closest to SSH and can reuse the current route, custody, recording, and approval primitives.
3. Add application/TCP and database adapters only for registered upstreams with explicit SSRF/exfiltration controls.
4. Add Kubernetes access after identity impersonation or short-lived client-certificate behavior is designed.
5. Add desktop/RDP only after renderer, redirection controls, recording policy, and bandwidth limits are defined.
6. Add live session collaboration/moderation and richer identity-governance controls across the implemented protocols.

## Maintained Matrix
The internal capability matrix lives in `openspec/changes/expand-remote-access-teleport-parity/matrix.md`. It is planning context, not public product documentation, and is the current source of truth for:

- Teleport feature area to ServiceRadar status.
- Next ServiceRadar implementation slice.
- Source-reuse decision for each feature area.
- Current Teleport checkout and Apache-era baseline evidence.
- Direct/transitive license scan command summaries.

Current evidence recorded there:
- `~/src/teleport` current `master` commit `42a4eaafeefee26e52bbd32ceec9699de1e9040c` has AGPL direct or transitive package directories for the scanned remote-access server/API/BPF paths.
- Teleport `v14.4.0` commit `8113e07dc94cf2977247346d5ec28ca0d5753c54` has an Apache-2.0 repository license and scans clean for several sampled package trees, but this is reference evidence only. It does not approve copying large stale subsystems without a future exact-file vendoring review.

## Guardrails
- Browser APIs must not accept client-selected agent, gateway, route, target host, credential rule, recording policy, or adapter-specific upstream overrides unless a deployment explicitly enables that behavior for testing.
- All target access remains tied to one actor, one session, one selected agent/gateway route, one protocol, one target, and one bounded credential grant.
- Protocol credentials must stay out of persisted session metadata unless the data is non-secret policy metadata.
- Recording and export features must treat transcripts, enhanced events, and file-transfer metadata as sensitive data with retention and RBAC.
- Enhanced recording stays behind the shared ServiceRadar cilium/ebpf runtime so the agent does not grow multiple BPF loaders or policy paths.
