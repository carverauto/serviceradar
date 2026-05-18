## Context

The remote-access stack ServiceRadar is building is a bastion: a single, trusted control plane that brokers human operators into customer infrastructure (Windows desktops, SSH hosts, Proxmox consoles, Kubernetes APIs, databases, TCP applications, file transfers) using actor-preserving identity, short-lived credentials, audit/recording, and policy gates. It directly inherits Teleport's threat model (a compromised bastion is catastrophic) without inheriting Teleport's code (license-blocked).

The scope of this review is everything that ships under "remote access" today:

- Branch `codex/remote-access-desktop-rdp` (current; ~623 commits ahead of staging).
- The `codex/teleport-agent-routed-remote-access` work already merged into staging (PR #3275) which established broker, SSH adapter, SSH CA, file transfer, recording, eBPF, and Elixir core resources.

## Tenancy Model (clarified post-review)

ServiceRadar's remote-access deployment model today is **predominantly single-tenant** — each customer install owns its own ServiceRadar control plane, agent gateway, and CNPG database (the `@prefix "platform"` schema-prefix observed in migrations is for ServiceRadar-internal namespace separation, not for hosting multiple customers in one schema).

This means the multi-tenant gaps the reviewers flagged (notably 4.1, 4.6, parts of 6.5) drop in severity *for the current deployment posture*, but stay on the books because:
- The codebase explicitly aspires to multi-tenant via Ash's tenant attribute strategy (`CLAUDE.md`).
- Bastion code touching cross-customer credential material and recordings is exactly where a future single→multi tenant migration is most likely to leak.
- "Single-tenant" still means "single customer with many actors, many targets, many recordings" — within-tenant IDOR is the real concern (see 5.4 recording playback).

Re-scoring under the single-tenant model:

- 4.1 — drops from `C?` to `M` (defence-in-depth + multi-tenant readiness).
- 4.6 — drops from `M` to `L` (forward-compat hardening).
- 6.5 — stays **C** because `agent_id` / `partition_id` collision *within* a single tenant is still a cross-agent media-injection primitive.
- 4.4 — stays **H** for the same reason (within-tenant agent impersonation).
- 5.4 — stays **H** (IDOR within a single tenant is the headline class of finding under this model).

## Goals / Non-Goals

Goals:
- Catalogue every security-relevant defect, weak default, RBAC gap, missing input validation, license/dep risk, panic-in-production, and credential-handling smell across the remote-access surface.
- Decide for each finding: fix in this PR or batch into a named remediation cluster (`C-A`…`C-V`) tracked in `tasks.md` §8.
- Codify, in `edge-architecture`, the cross-cutting security contracts protocol adapters must meet (so future protocol slices inherit them without rediscovery).

Non-Goals:
- Implementing fixes — this change is review + capture only. Implementation happens in follow-up commits on this branch or upstream PRs against staging.
- Performance review (covered separately).
- UX / accessibility review.
- Auditing non-remote-access code paths even when adjacent (e.g. general identity, general device inventory).

## Methodology

Each capability slice is reviewed against this checklist:

1. **Authentication & Authorization**
   - Caller authn (mTLS, JWT, session cookie, agent identity).
   - Authz: RBAC policy enforced before any action; verify policy is applied per-action, not only at module load.
   - Tenant isolation: every read/write scoped by `tenant_id` (or equivalent); cross-tenant joins?
   - Object capability: can the caller see/act on this specific row?

2. **Credentials & Secrets**
   - In-memory residency: zeroised on session close? `Drop` for sensitive structs in Rust?
   - At rest: encryption envelope, key rotation, blast radius.
   - In transit: mTLS verified (CA + name), no TLS-downgrade path, no plaintext fallback.
   - Logging: any chance of secret in logs, traces, error messages, telemetry?
   - SSH CA / cert issuance: principal mapping authoritative, TTL bounded, revocation reachable.

3. **Input Handling**
   - Untrusted bytes from agents / browsers / target servers parsed safely.
   - Bounded sizes everywhere (frame lengths, header sizes, file lengths, redirection caps).
   - Reject-on-trailing-bytes, reject-on-unknown-flag, reject-on-stale-nonce semantics.
   - Path traversal / injection (SSH command, SQL, Kubernetes verb, shell) at every boundary.

4. **Protocol & Transport**
   - TLS settings: rustls config, allowed cipher suites, hostname verification, CA pinning.
   - mTLS: client cert validated and bound to identity.
   - Kerberos/CredSSP/KDC paths: replay protection, ticket binding, no downgrade.
   - WebSocket / gRPC channel: origin checks, auth on every message, backpressure / timeouts.

5. **Data Lifecycle**
   - Recording integrity: append-only, hash-chained, tamper-evident; deletion gated.
   - File transfer: scan/quota/policy applied, paths normalised, symlinks rejected.
   - Multi-tenant migration: any schema lacking tenant_id, or with composite key that allows cross-tenant collisions.

6. **Failure & Reliability**
   - Panics / unwraps in production code paths (Rust `unwrap`, Elixir `!` calls, Go `panic`).
   - Resource leaks on error paths (open sockets, file descriptors, child processes).
   - DoS surface: unbounded buffers, slowloris, malformed RDP/SSH frames, eBPF ring loss.
   - Race conditions: TOCTOU around target/session/grant lookups.

7. **Build, Dependency & License**
   - Crates / Go modules pulled in for the bastion path: maintained, no known CVEs, license-clean.
   - Transitive AGPL / GPL paths (Teleport scan must remain green for any new imports).
   - CI: do release/publish workflows leak secrets, accept unsigned artifacts, or skip checks?

8. **Browser-side**
   - LiveView / JS hooks: XSS in target labels, recordings transcript, error messages.
   - WebRTC / WebCodecs renderer: origin isolation, CSP, sandbox.
   - CSRF on JSON APIs that mutate sessions/targets/grants.

## Severity Rubric

- **Critical**: bastion-wide compromise, cross-tenant escape, credential exfiltration, RCE on agent or browser. Must fix before this branch merges, or block-listed.
- **High**: actor-preserving identity defeat, recording bypass, RBAC bypass for a single action, persistent secret-in-log. Must fix this PR.
- **Medium**: DoS, partial input-validation gap behind another control, weak default that requires admin misconfiguration to be unsafe. Fix this PR if cheap; else schedule.
- **Low**: hardening opportunity, defence-in-depth, documentation. Schedule.

## Decisions

- **Single proposal, capability-grouped tasks** (chosen by user). Avoids fragmenting the audit; per-capability follow-ups only when remediation is its own multi-week project.
- **All tracking in this proposal** (chosen by user after triage). Originally considered filing forgejo issues for staging-rooted findings — rejected to keep a single source of truth. Remediation that targets staging code ships as its own focused PR but is checked off against the relevant cluster in §8.
- **No new normative spec until findings are triaged**: deltas in `specs/edge-architecture/spec.md` are written after the review finishes so they reflect what we actually need to guarantee, not a guess.
- **Remote-access LiveViews render untrusted text only through HEEx interpolation**: hostnames, agent IDs, fingerprints, labels, metadata-derived fields, and target-supplied values must stay out of `raw/1`, JavaScript strings, and manually concatenated HTML. Tests should include representative XSS payloads whenever a remote-access screen renders future operator-set or agent-observed fields.

## Risks / Trade-offs

- **Review-only proposal grows stale**: if remediation drags, the file:line references rot. Mitigation: each task includes the SHA observed at review time so reviewers can `git blame` reliably.
- **Severity calls are subjective**: rubric above is the appeal record.
- **Single-tracker concentration**: all findings live here, so this proposal becomes the only thing reviewers / future-me / on-call need to know about — but tasks.md grows large (~1500 lines). Index discipline (§8.5 rollup) keeps it navigable.

## Open Questions

- Should desktop/RDP findings block the parent PR merge, or merge with feature-flag off?
- Does the existing `redact_desktop_target_policy` change cover PII redaction in recording artefacts, or only in target metadata?
- Is the SSH CA root rooted in HSM / KMS or only at-rest encrypted in CNPG?
