# Tasks

This file tracks remediation work surfaced by the deep-dive review. Each finding entry follows:

```
<unchecked> N.M [SEV] <one-line summary>
      Where: <file:line>  (commit: <sha-or-"working tree">)
      Why: <impact in one sentence>
      Fix: <intended remediation>
```

Severity: **C**ritical / **H**igh / **M**edium / **L**ow (see `design.md`).
Triage for every finding lives in §8 (in-branch fix, remediation cluster `C-A`…`C-V`, accept-with-note, closed, or spec-delta). The `**FILE FORGEJO**` markers that originally appeared in some `Fix:` lines were stripped during triage — they were historical artefacts from the review process, not action items. The §8.5 rollup is the authoritative routing.

## 0. Review Execution

- [x] 0.1 Define scope, baseline (`staging`), and severity rubric (`design.md`).
- [x] 0.2 Scaffold proposal directory.
- [x] 0.3 Run six parallel capability reviews (RDP, SSH/CA, file transfer + recording/eBPF, Elixir core resources, web-ng surface, agent gateway + build/CI).
- [x] 0.4 Consolidate findings into sections 1–6 below.
- [x] 0.5 Triage each finding into `in-branch fix`, remediation cluster, accept-with-note, closed, or spec-delta. (See §8.)
- [x] 0.6 Draft `specs/edge-architecture/spec.md` deltas reflecting the cross-cutting guarantees the findings prove we need.
- [x] 0.7 `openspec validate harden-remote-access-security --strict`.

## 1. RDP / Desktop Adapter (Rust + Go helper)

- [x] 1.1 [H] Actor ID in credential grant not validated to match calling principal
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:658-670` (working tree)
      Why: `actor_id` in `DesktopCredentialGrant` is parsed but never checked against the authenticated caller; a compromised agent could submit a grant naming another actor for impersonation.
      Fix: Assert `grant.actor_id == authenticated_caller_id` before passing to backend; failing call must zeroise the grant and log.

- [x] 1.2 [H] `SensitiveString::expose()` silently coerces invalid UTF-8 to empty string
      Where: `rust/rdp-adapter/src/protocol.rs:292` (working tree)
      Why: `.unwrap_or("")` masks credential corruption — an empty password is then handed to the RDP backend which may treat it as a guest/anonymous attempt.
      Fix: Return `Result<&str, Utf8Error>` (or panic-free `Err`) and propagate so the session fails closed.

- [x] 1.3 [M] CA-bundle size limit enforced post-deserialisation, not during
      Where: `rust/rdp-adapter/src/protocol.rs:99` (field), `:727` (check) (working tree)
      Why: A 256 KiB allocation is already done by serde before validation rejects it; repeated bursts amplify into helper-level memory pressure.
      Fix: Custom serde deserialiser (or `serde_bytes` + len-prefixed reader) that aborts past the byte cap; reject before allocation.

- [x] 1.4 [M] Frame parser does not reject trailing bytes after declared payload
      Where: `rust/rdp-adapter/src/lib.rs:480-511` (`read_frame`) (working tree)
      Why: Wire framing is the contract boundary; silently accepting extra bytes between frames hides protocol-confusion attempts and breaks the "reject-unknown" guarantee.
      Fix: After reading `payload_length`, peek for a valid next-header magic or EOF; otherwise error and close the channel.
      Resolution: closed as spec-delta. The current helper protocol is a length-prefixed stream with no magic byte; bytes after a payload are either the next valid frame or an invalid next header, which existing tests reject before payload allocation. Add a frame magic/version field before implementing stronger desync detection.

- [x] 1.5 [M] Pointer-bounds check off-by-one at screen edge
      Where: `rust/rdp-adapter/src/protocol.rs:641-642` (working tree)
      Why: Uses `>` instead of `>=`, allowing `x == max_width`, `y == max_height` which are 1-past-the-end for 0-indexed coordinates and can probe out-of-canvas regions.
      Fix: Change both comparisons to `>=`.

- [x] 1.6 [L] `harden_process_for_secrets()` is opt-in, not invoked at helper start
      Where: `rust/rdp-adapter/src/lib.rs:176-178` (working tree) — also requires reading `src/main.rs`
      Why: If the Go adapter forgets to call it, core dumps stay enabled and credential-bearing memory can leak to disk.
      Fix: Invoke in helper `main` unconditionally; remove the public opt-in.

- [x] 1.7 [L] CA-bundle ID/PEM presence check accepts whitespace-only values
      Where: `rust/rdp-adapter/src/protocol.rs:732-734` (working tree)
      Why: `.trim().is_empty()` lets `"   "` pass the both-or-neither check, creating an unusable grant at runtime.
      Fix: Use raw `.is_empty()` on the original string.

- [x] 1.8 [L] ACK credit cap is per-frame, not per-session or per-window
      Where: `rust/rdp-adapter/src/protocol.rs:33, 707-708` (working tree)
      Why: 1000× 4 MiB ACKs exhaust buffers without any single frame violating the cap.
      Fix: Track accumulated credit per session (rolling window) and refuse beyond a session-scoped budget.

**Positives (RDP):**
- Credential-grant `Drop` zeroises password / secret_ref.
- Session ID re-checked on every INPUT / ACK / CLOSE frame.
- Terminal reason strings normalised to strip control bytes.
- Frame size caps applied before payload allocation.
- `serde(deny_unknown_fields)` on all wire payload structs.

**Coverage notes (RDP):**
- Fully read: `lib.rs`, `protocol.rs`, `process_hardening.rs`, `backend.rs`, Go adapter + protocol files.
- Partially read: `backend_ironrdp.rs` (4722 lines — sampled credential/session-binding paths via grep).
- Not read: `media_frame.rs`, RDP test files, `rdp-connector-probe/` body.
- Recommend follow-up Review A2 covering the rest of `backend_ironrdp.rs`, `rdp-connector-probe/src/lib.rs` (1867 lines, includes KDC/CredSSP/TLS routing), and tests.

### 1.A2 Coverage Follow-Up (backend_ironrdp + connector-probe + media_frame + tests)

- [x] 1.A2.1 [C] CA-bundle parser falls back to raw bytes when PEM markers absent
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:1394-1397` (working tree)
      Why: A grant whose `ca_bundle_pem` is binary / corrupt / DER bytes is accepted as-is and handed to rustls, which fails opaquely later — opens MITM where the operator sees only a generic connector error and may retry with redirections relaxed.
      Fix: Strict PEM parse; reject if zero certificates parsed; surface a structured "ca_bundle_invalid" reason.

- [x] 1.A2.2 [H] `actor_id` in `DesktopCredentialGrant` is parsed but ignored by `build_memory_user_credential`
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:658-670` + `:2339-2359`; field at `protocol.rs:127` (working tree)
      Why: Strengthens 1.1 — even after assertion is added to the open path, the credential build also has to consume the authenticated actor id or the impersonation gap reopens at backend layer.
      Fix: Thread authenticated `actor_id` into `RdpBackend::open` and require equality with `grant.actor_id` before constructing the credential; emit audit on mismatch.

- [x] 1.A2.3 [M] connector-probe test helpers clone the password as bare `String` (no `Zeroizing`)
      Where: `rust/rdp-connector-probe/src/lib.rs:580, 611, 641, 713, 768` (working tree)
      Why: Test-only today, but copy-paste into production KDC paths would silently regress the main-backend zeroisation discipline.
      Fix: Wrap the password copies in `Zeroizing::new(...)` even in tests; add a clippy lint or doctest banning bare `String` for password types in this module.

- [x] 1.A2.4 [M] `media_frame.rs::validate_desktop_media_frame` doesn't reject NUL / control bytes in string fields
      Where: `rust/rdp-adapter/src/media_frame.rs:172-200` (working tree)
      Why: `session_binding_id`, `media_session_id`, `encoding` accept any UTF-8 — NUL/control bytes can corrupt downstream framing or get logged into the recorder/UI.
      Fix: Reject any control byte except whitespace; reject NUL; cap length explicitly per-field; add regression test in `media_frame.rs:250+`.

- [x] 1.A2.5 [M] TLS handshake completion not explicitly asserted before `peer_certificates()` consumption
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:1234-1249` (working tree)
      Why: A server alert leaves the connection in a failed state but the error maps to `CONNECTOR_NOT_IMPLEMENTED`, hiding the real cause from audit and from operators trying to diagnose MITM/cert problems.
      Fix: Assert `!tls_stream.conn.is_handshaking()` (or surface the rustls error detail) before reading peer certs.

- [x] 1.A2.6 [M] `ServerName` constructed from arbitrary string — no IDNA / DNS-label / IP-literal rejection
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:1231` (working tree)
      Why: A grant supplying `"[::1]"` or punycode forms can produce surprising ServerName matches against the cert SAN list.
      Fix: Pre-validate against `[A-Za-z0-9.-]+` (ASCII LDH), reject any input that parses as an IP literal; document rule in `protocol.rs` next to the field.

- [x] 1.A2.7 [L] Single hardcoded 10-s timeout for both TCP dial and KDC RPCs
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:42` + `ServiceRadarKdcNetworkClient::new` (working tree)
      Why: DCs under load legitimately take >10 s; the failure mode hides which stage timed out.
      Fix: Per-stage timeout, configurable in grant metadata with a hard cap; log which stage tripped.

- [x] 1.A2.8 [L] Kerberos config snapshot in handoff is never re-validated across phases
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:118, 153` (working tree)
      Why: Defence-in-depth — a metadata-mutation MITM between begin-handoff and finalize wouldn't be caught.
      Fix: Compare `kerberos_config` against the grant's KDC/realm on every phase transition; refuse on drift.

- [x] 1.A2.9 [L] `bytes_contain_secret` is a naive `windows().any(...)` byte scan
      Where: `rust/rdp-adapter/src/backend_ironrdp.rs:2014-2020` (working tree)
      Why: Useful as test-visibility heuristic but easy to mistake for a real boundary; encoded or framed passwords slip past silently.
      Fix: Add a comment marking it test-only; if ever used as enforcement, swap for structured PDU inspection.

**Positives (RDP A2):**
- `Zeroizing<String>` used uniformly in `backend_ironrdp.rs:614-625` for username/password/domain.
- `RedactedSecret` `Debug` impl redacts password in logs (`:639-645`).
- No `unwrap()` in credential paths in production code.
- TLS resumption explicitly disabled for CredSSP (`:1358`).
- All redirections (clipboard, drives, printers, audio, smart-card, file-copy) forced off in connector-probe at `:546-558`.
- PDU-emit tests assert `!contains_cleartext_password` for every redirection / capability case (`:2743, :2785, ...`).

**Coverage notes (RDP A2):**
- Fully read: `backend_ironrdp.rs` (4722 lines), `rdp-connector-probe/src/lib.rs` (1867 lines), `media_frame.rs` (349 lines), `rdp-adapter/tests/connector_live_probe.rs` (11 lines).
- Not read: Go helper side (covered in Review A); `rdp-connector-probe/Cargo.toml` audit deferred to Review G.

**Cross-refs to §1:**
- 1.A2.1 supersedes the more-cautious framing in 1.3 — promote CA-bundle handling to a structured, single-source parser with one error path.
- 1.A2.2 strengthens 1.1; both must land together to close the actor-impersonation surface.
- 1.A2.3 echoes 1.2's zeroisation theme but in test scaffolding — preventive, not in-prod.
- 1.A2.4 is a new sibling to 1.4 (frame-level input hardening) — same rule, different field set.

## 2. SSH Adapter, SSH CA & Certificate Issuance (Go + Elixir)

- [x] 2.1 [H] Proxmox console SSH error leaks raw `err.Error()` into the PTY stream
      Where: `go/pkg/agent/proxmox_console_ssh.go:120` (commit: staging)
      Why: `err.Error()` may contain hostnames, authentication failure detail, or transport secrets; rendered to the operator's terminal it also gets recorded.
      Fix: Return a generic "SSH console unavailable" to the terminal; log full error server-side with audit context

- [x] 2.2 [M] TOCTOU between `File.write` / `File.chmod` and `System.cmd` in CA command signer
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_ca_command_signer.ex:83-91` (commit: staging)
      Why: Symlink/hardlink swap window on a shared temp dir lets a local attacker substitute payload before the signer reads it.
      Fix: Open with `[:write, :exclusive]` (atomic create) or use a `mkstemp`-style helper rooted in a per-process directory

- [x] 2.3 [L] Cert extension policy permits `force-command` / `source-address` without server-side validation
      Where: `go/pkg/remoteaccess/sshca/sshca.go:242-245` (commit: staging)
      Why: Callers can inject dangerous extensions; Elixir policy doesn't currently constrain them.
      Fix: Deny-list dangerous extensions in the Go signer unless the Elixir policy explicitly approves; document the contract

- [x] 2.4 [M] No per-actor rate limit / cap on certificate issuance
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_certificate_policy.ex` (commit: staging)
      Why: Allows credential-stuff-then-issue spam to overwhelm audit, mask compromise, or backdoor via short-cert blizzard.
      Fix: Token-bucket per-actor (e.g. 10/min) backed by ETS/Redis; emit metric and audit on throttle

- [x] 2.5 [L] CA command signer launches via `/bin/sh -c` with positional substitutions
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_ssh_ca_command_signer.ex:103-109` (commit: staging)
      Why: Fragile; one careless edit to the shell template reintroduces injection. Use `exec` rather than shell.
      Fix: `System.cmd/3` with explicit binary path + arg list, no shell

- [x] 2.6 [L] CA private key custody is env-var / file with no HSM/KMS path documented
      Where: `go/cmd/tools/sshca-signer/main.go:89-106`; `docs/ansible/remote-access-ssh-ca/README.md` (commit: staging)
      Why: A compromise of the host (or a leaked process dump) reveals the bastion-wide signing key.
      Fix: Add an OpenBao/Vault/KMS backend option and document rotation procedure; emit audit on key load
      Resolution: ServiceRadar's external command signer is the production KMS/HSM boundary: operators can replace the bootstrap file/env signer with an OpenBao/Vault Transit, cloud KMS, or HSM-backed signer that implements the same bounded JSON contract. The bootstrap `serviceradar-sshca-signer` now exposes CA public-key fingerprint/source metadata in its response and supports `--audit-file` / `SERVICERADAR_SSHCA_AUDIT_FILE` for JSONL key-load audit without polluting stdout. Operator docs now cover custody, signer wrapping, and overlapping CA rotation.

- [x] 2.7 [L] Signer accepts any parsed key type — no explicit allowlist of algorithms
      Where: `go/pkg/remoteaccess/sshca/sshca.go:85-105` (commit: staging)
      Why: Relies on `golang.org/x/crypto/ssh` defaults; a future regression could re-enable SHA-1.
      Fix: Explicit allowlist (Ed25519, ECDSA-P256+); reject RSA <4096; refuse SHA-1 signatures

**Positives (SSH / SSH CA):**
- Principal validation both sides — Elixir `valid_principal?` and Go client refuse `,`/`:`/control chars; 128-byte cap.
- RBAC checked before any cert mint; Ash system-actor bypass used consistently.
- Host-key verification defaults to known_hosts; TOFU append is mutex-guarded.
- Request/response size bounds enforced (65 KiB cert/key, 128-byte refs).
- Audit trail captures actor, target, principals, TTL, fingerprint for both success and denial.

**Coverage notes (SSH / SSH CA):**
- All scoped files read fully; integration test path verified end-to-end.
- 2.4 is a design gap, not introduced by staging — but the policy module lives in staging.
- Proxmox Wasm plugin has a sibling `console_ssh_go.go` with the same `skip_verify` pattern in local-only contexts; out of scope here.
- No panic/Fatal in signer paths; no hardcoded credentials beyond the env-var custody documented in 2.6.

## 3. File Transfer + Enhanced Recording / eBPF (Go + Elixir)

- [x] 3.1 [H] Upload stream uses `context.Background()`, discarding session lifecycle
      Where: `go/pkg/agent/remote_file_transfer.go:55` (and goroutine at :154-169) (commit: staging)
      Why: When the parent session terminates the upload goroutine keeps writing — unbounded disk fill + no cancellation propagation.
      Fix: Thread the caller's session context through `HandleFileTransferFrame`; cancel goroutine on session end

- [x] 3.2 [H] `destroy` action on recordings (and file transfers) lacks user-actor RBAC, default-on
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_recording.ex:109-111`; same pattern in `remote_access_file_transfer.ex:139-141` (commit: staging)
      Why: `defaults [:read, :destroy]` plus only a system-actor policy means any path that injects/bypasses scope reaches a successful destroy — recording tamper-evidence floor not enforced.
      Fix: Replace defaults with explicit `:destroy` action gated on a `recording.delete` RBAC permission and an audit log row

- [x] 3.3 [M] Recording-event read policy missing per-recording / per-session ownership filter
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_recording_event.ex:71-83` (commit: staging)
      Why: Index on `[session_id, sequence]` is non-unique with no FK; events can be enumerated even when the parent recording is unreadable to the actor.
      Fix: Add `filter expr(recording.actor_can_read)` (or equivalent join policy); add FK + ON DELETE CASCADE on `session_id`

- [x] 3.4 [M] eBPF kernel events stored without validation of `Argc`, NULs, UTF-8
      Where: `go/pkg/agent/remoteaccess/enhanced_recording_ebpf.go:40-80`; `enhanced_recording_linux.go:110+` (commit: staging)
      Why: Kernel→userspace bytes are not part of the trust boundary that downstream JSON serialisation assumes; a malicious / buggy probe can poison the recording stream.
      Fix: Bound `Argc`, strip control bytes from `cString`, validate UTF-8 with replacement; add a fuzz target

- [x] 3.5 [M] File-transfer approval snapshot not re-validated at agent completion
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_file_transfers.ex:329, 499` (commit: staging)
      Why: An approval revoked mid-transfer still lets the agent finalise the write because policy is captured once at request time.
      Fix: Require the agent to echo `approval_id` in the completion frame; core re-checks approval state before persisting bytes / metadata

- [x] 3.6 [L] eBPF ring-buffer / channel-drop losses not surfaced in-band
      Where: `go/pkg/agent/remoteaccess/enhanced_recording_ebpf_loss.go:75-90`; `enhanced_recording_linux.go:350-360` (commit: staging)
      Why: Operator only sees the loss counter on stop; ongoing recording can silently lose enhanced events.
      Fix: Emit periodic loss events when drop rate crosses threshold; expose to recording metadata

- [x] 3.7 [L] Symlink containment silently succeeds when `RealPath` fails
      Where: `go/pkg/agent/remoteaccess/file_transfer_policy.go:196-207`; failure path in `sftp.go:209` (commit: staging)
      Why: `follow_inside_root` mode returns nil-error with empty `ResolvedPath`, bypassing the containment check.
      Fix: Treat `RealPath` failure as policy violation; reject the transfer.

**Positives (file transfer / recording / eBPF):**
- Monotonic sequence enforcement on upload data frames (`file_transfer.go:273-279`).
- Path normalisation via `path.Clean` and rejection of relative paths (`file_transfer_policy.go:263-275`).
- Policy evaluation precedes SFTP operation; decisions captured immutably at request time (`sftp.go:193-216`).
- Recording event migration uses ON DELETE CASCADE on session_id (sequence-only — see 3.3 for FK gap).
- BPF capability validation on platform_linux startup gate (`enhanced_recording_platform_linux.go:45-66`).

**Coverage notes (file transfer / recording / eBPF):**
- `go/pkg/agent/ebpf/probes` not in scope — assumes verifier/privilege checks delegated to agent startup.
- `github.com/pkg/sftp` not CVE-scanned in this pass.
- Recording storage backend (`datasvc_object_store`) encryption/isolation delegated; treat 3.2 as recording-layer guarantee, separate from storage-layer guarantee.
- Content audit retention (`content_audit_retained`, `content_artifact_ref`) is off-by-default; no review of object-store path performed.

### 3.H Coverage Follow-Up (audit storage, recording object store, ticket entropy, registry binding, path leakage)

- [x] 3.H.1 [H] PaperTrail `store_action_inputs? true` on session + request resources persists `credential_rule_id` / `approval_id` / `metadata` in `*_versions` rows
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_session.ex:75`; `remote_access_request.ex:69` (commit: staging)
      Why: Audit table accumulates indirect-credential pointers that survive the lifetime of the source rows; if 4.8 / 3.H.3 turn out to be replayable refs, the audit log itself becomes a credential-replay corpus.
      Fix: Flip to `store_action_inputs? false` (preferred) or add `credential_rule_id`, `approval_id`, `metadata` to `ignore_attributes`; mirror the `attach_ticket_hash` exclusion

- [x] 3.H.2 [M] Recording API + LiveView leak `storage_backend` / `storage_bucket` / `object_key` to the client
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_recording_controller.ex:88-106` (`:94-96`); `live/settings/remote_access_recordings_live.ex:169` (commit: staging)
      Why: Exposes the bastion's storage topology and encourages clients to construct direct object-store URLs — undermines 5.4 / 5.8 by giving the attacker an out-of-band path even if the controller is fixed.
      Fix: Strip these fields from the JSON view + LiveView render; only the controller-issued pre-signed URL (short-lived, per-actor) should reach the browser
      Resolution: Recording controller responses now omit storage fields from both the recording object and exported manifest, and the recordings LiveView no longer renders storage backend/bucket/object-key details. Regression tests assert the fields and default storage strings do not reach the browser.

- [x] 3.H.3 [M] `SecretRefs.network_credential_ref/1` is plain prefix + UUID — no HMAC, no TTL, no nonce
      Where: `elixir/serviceradar_core/lib/serviceradar/plugins/secret_refs.ex:120-123`; consumed at `remote_access_central_credential_grants.ex:114` (commit: staging)
      Why: Confirms what 4.8 suspected — the credential ref is a static, replayable handle. Any log line / temp file / audit row (see 3.H.1) carrying the ref is exfilable into an indefinite credential.
      Fix: Replace with HMAC-signed token over `(secret_id, exp, nonce)` with sub-minute TTL; verify signature + exp on dereference, single fix.
      Resolution: Remote-access central credential grants now issue `credentialref:network-credential-grant:` refs signed with HMAC over `secret_id`, expiry, nonce, and grant-binding claims; deref verifies signature and expiry before returning the secret id, and the signed ref TTL is capped at 60 seconds. Legacy static refs remain readable for persisted plugin assignment/test-plan compatibility but are no longer emitted by the remote-access central broker grant path.

- [x] 3.H.4 [L] Recording events have `payload_sha256` but no chain linkage (`prior_event_hash`)
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_recording_event.ex:99-103` (commit: staging)
      Why: Closes the offline tamper-evidence gap from 3.2 — sequence numbers + per-event hash without chaining still let a hostile holder of write access excise an event silently.
      Fix: Add `prior_event_hash`; expose an integrity root in the export manifest; verify chain on export.
      Resolution: Added `prior_event_hash` to `platform.remote_access_recording_events`, compute each event's prior link from the canonical integrity hash of the previous event, and verify the chain during export. Export manifests now include `event_chain_verified` and `event_chain_root`; regression coverage asserts event linkage and the exported integrity root.

- [x] 3.H.5 [L] No retention / purge policy on PaperTrail versions; no `ON DELETE CASCADE` on FK to parent
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_session.ex:77` (`create_version_on_destroy? false`); migrations `20260515192000_create_remote_access_desktop_targets.exs:127-129` (commit: staging)
      Why: Orphaned audit rows accumulate indefinitely and (per 3.H.1) carry credential pointers; "no version on destroy" doesn't prune prior versions.
      Fix: Add `ON DELETE CASCADE` on PaperTrail FKs; schedule an Oban job to purge versions > N days (per-resource policy)
      Resolution: Added cascading PaperTrail source FKs for remote access session/request/desktop-target/host-key version tables, plus a daily maintenance Oban worker with per-table retention settings. Regression coverage asserts session/request version rows cascade when their parent rows are removed.

- [x] 3.H.6 [L] Broker registry registration not bound to caller pid on re-register
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_broker_registry.ex:17-29` (commit: staging)
      Why: Complements 4.4 — even if frames are signed, a different process re-registering under the same `session_id` can intercept future routes.
      Fix: First register stashes pid; subsequent register for same session_id requires matching pid (or explicit takeover audit); log + emit metric on mismatch.

- [x] 3.H.7 [L] Attach-ticket hash comparison is timing-safe (custom constant-time XOR in `crypto.ex:170-180`)
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_sessions.ex:731, 739` → `crypto.ex:170-180` (commit: staging)
      Why: Confirmed by Review M — Elixir-side comparison uses a constant-time XOR-reduction; lookup path is timing-safe.
      Fix: **CLOSED — no action required.** Add a regression test to lock the invariant (per 7.I row 3.H.7).

**Positives (audit / object store / tickets / registry):**
- `attach_ticket_hash` correctly excluded from PaperTrail (`remote_access_session.ex:77`).
- Recording events have unique `(recording_id, sequence)` (`remote_access_recording_event.ex:177`).
- Desktop-target redaction excludes action_inputs (`remote_access_desktop_target.ex:56`).
- Attach ticket has 256 bits of entropy and is never persisted in plaintext.
- Broker registry monitors the registered pid for liveness — frees the entry on crash even though it doesn't gate re-register (see 3.H.6).

**Coverage notes (audit / object store / tickets / registry):**
- PaperTrail audited on session/request/host_key/desktop_target; recording + file_transfer don't use it (storage delegated).
- Object-store bucket policy / encryption config was not reachable from the bastion side — verify on the `datasvc` deployment.
- Did not measure Postgres query plan for ticket lookup; the timing-safety claim in 3.H.7 is theoretical until tested.

**Cross-refs:**
- 3.H.1 + 3.H.3 + 4.8 all want one merged fix: HMAC-signed refs + audit-exclusion of those refs.
- 3.H.4 closes the spirit of 3.2 (recording tamper-evidence) — pair them.
- 3.H.6 pairs with 4.4 (frame-signature) — same threat (broker hijack), different layer.
- 3.H.2 strengthens 5.4 + 5.8 (recording IDOR) — even a perfect controller doesn't help if the bucket/key are in the page.

## 4. Elixir Core Remote-Access Resources (broker, sessions, targets, host keys, grants, migrations, policies, tenancy)

> Tenancy model (resolved): ServiceRadar deployments are predominantly **single-tenant** today; `@prefix "platform"` is internal namespace separation. Findings 4.1 and 4.6 are downgraded from C/M to M/L respectively — they remain on the list as defence-in-depth + multi-tenant readiness, not as ship-blockers. See `design.md` for the rescoring rationale.

- [x] 4.1 [M] Sessions resource has no explicit tenant scoping at the Ash layer (multi-tenant readiness)
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_session.ex` (no tenant_id attribute / multi-tenancy block); migration `20260509090000_create_remote_access_sessions.exs` (commit: staging)
      Why: Isolation depends entirely on Ash policy + schema prefix. If a policy is bypassed or actor lacks a tenant binding, cross-tenant reads become possible. Same concern applies to broker/target/grant lookups built on session_id.
      Fix: Confirm tenancy model (attribute vs prefix-per-tenant). If attribute: add `tenant_id` + multitenancy block + include it in unique indexes. If prefix: add a regression test that proves cross-prefix queries fail closed and document the model in `design.md`
      Resolution: Accepted-with-note under C-V. ServiceRadar is a single-deployment system and the repo guardrails explicitly reject application-level multitenancy; schema-prefix isolation is the current boundary. Reopen only if ServiceRadar adopts shared-schema multi-tenancy.

- [x] 4.2 [C] Session attach ticket is single-window but not single-use
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_sessions.ex:107-134` (commit: staging)
      Why: Lookup uses `attach_expires_at > now()` only; a stolen plaintext ticket can be replayed inside the TTL window. Combined with the broker frame-trust gap (4.4) this is a session hijack primitive.
      Fix: Transition to `:attached` on first consume inside an Ash transaction; reject any second consume with audit

- [x] 4.3 [H] Self-approval of access requests not enforced at the policy layer
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_requests.ex:129, 266-270, 293-300` (commit: staging)
      Why: `reviewer_policy.allow_self_approval` defaults false but is not encoded as an Ash policy bypass — a requester holding a generic review permission could approve their own request via the `approve` action.
      Fix: Add `forbid_if expr(approver_id == requested_by)` to the approve policy unless `allow_self_approval` is true and explicit

- [x] 4.4 [H] Broker accepts agent frames using string equality on `session_id` / `agent_id` — no cryptographic binding
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_broker.ex:185-248` (`owns_remote_access_frame?`) (commit: staging)
      Why: A compromised or impersonating agent that knows / guesses an active `(session_id, agent_id)` pair can inject control / media frames; broker has no per-frame signature.
      Fix: Mint a per-session HMAC key when the broker accepts an agent; require every frame carry an HMAC over `(session_id, agent_id, seq, payload_hash)`; verify before routing
      Resolution: Broker open frames now include a per-session `frame_auth` HMAC key, agent-to-broker `ConsoleFrame` messages carry `seq`, `payload_sha256`, and `signature`, and the broker verifies route binding, monotonic sequence, payload hash, and HMAC before routing terminal, file-transfer, enhanced-recording, or close frames. The Go agent signs remote-access console and file-transfer responses with the same session signer.

- [x] 4.5 [H] Host-key `:conflict` keys can be manually promoted to `:trusted` without rotation audit
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_host_keys.ex:145-176`; `remote_access_host_key.ex:131-134` (commit: staging)
      Why: TOFU correctly detects rotation but the admin "trust this new key" path has no irreversible `:rejected` state or rotation linkage — a key-swap attacker who also captures admin creds defeats TOFU silently.
      Fix: Add `:rejected` terminal state, require the rotation acceptance to record `superseded_by` linkage to the previous trusted key, and emit an audit event with diff
      Resolution: Host keys now support terminal `:rejected` state with operator/reason metadata, direct trust of `:conflict` keys is refused, rotation is the only path that can trust a conflicted replacement, and accepted replacements persist `supersedes_host_key_id` while the old key records `replacement_host_key_id`. Trust/reject/rotate audit details include both linkage fields.

- [x] 4.6 [L] Host-key unique index omits `tenant_id` (multi-tenant readiness)
      Where: `elixir/serviceradar_core/priv/repo/migrations/20260512110000_create_remote_access_host_keys.exs:66-72` (commit: staging)
      Why: Current isolation appears to be schema-prefix, but a future move to shared-schema multi-tenancy would silently collide host-key rows across tenants.
      Fix: Add `tenant_id` to the unique index now; safe under both isolation models
      Resolution: Accepted-with-note under C-V. ServiceRadar is a single-deployment system and the repo guardrails explicitly reject application-level multitenancy; no `tenant_id` column should be added under the current model. Reopen only if ServiceRadar adopts shared-schema multi-tenancy.

- [x] 4.7 [M] `bind_session` for approvals is not atomic with the state check
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_requests.ex:148-161` (commit: staging)
      Why: Concurrent attach attempts on the same approval can both pass the state check before the partial unique constraint catches the second write; the loser may have already triggered side effects (session creation, audit row).
      Fix: Wrap in Ash transaction with `pg_advisory_xact_lock` keyed on approval_id, or use a strict state transition with optimistic locking on `consumed_at`

- [x] 4.8 [M] Credential grant `secret_ref` not provably signed/short-lived
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_central_credential_grants.ex:114` (commit: staging)
      Why: The ref is sent in the open-frame metadata and could be replayed if any layer logs it; spec doesn't guarantee it's HMAC-signed with a sub-minute TTL.
      Fix: Verify `SecretRefs.network_credential_ref/1` returns an HMAC-signed, timestamped opaque token; refuse deref on replay or expiry. If not, switch implementation
      Resolution: Closed by 3.H.3. Remote-access central credential grants now emit HMAC-signed `credentialref:network-credential-grant:` refs with expiry, nonce, binding claims, replay rejection, and a maximum 60-second TTL.

- [x] 4.9 [M] Desktop-target redaction uses field-allowlist `@fields`; new fields default to un-redacted
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/changes/redact_desktop_target_policy.ex:34-44` (working tree)
      Why: A future contributor adding a credential-bearing field forgets to update the allowlist → secret returns via read action.
      Fix: Invert to a denylist + structural rule: strip everything matching the credential redactor heuristic, plus any field not on an explicit non-secret allowlist. Add property-based test.
      Resolution: Desktop target policy redaction now evaluates every changed attribute. Known non-secret fields still pass through the credential redactor, structured policy maps are recursively redacted, and unlisted future fields are stripped by default to a marker/empty value. Regression tests cover known policy redaction, unknown-field stripping, and change-payload minimization.

- [x] 4.10 [L] Broker silently ignores unknown frame types
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_broker.ex:185-231` (commit: staging)
      Why: Hides protocol-confusion attempts; future frame types added agent-side land in production with no operator visibility.
      Fix: Log at WARN with `(session_id, agent_id, frame_type)`; emit a metric; reject on a hard-protocol-violation list

**Positives (Elixir core remote-access):**
- Attach tickets stored SHA-256 hashed (`remote_access_session.ex:183`).
- Session state machine has irreversible transitions (requested → active → closed/failed).
- Host-key TOFU correctly *detects* conflict (its enforcement story is the gap — see 4.5).
- `paper_trail` is configured and action_inputs are explicitly excluded for sensitive resources (`remote_access_desktop_target.ex:56`).
- Credential material is never persisted — grants are reference-only (`central_credential_grants.ex:5-7`).

**Coverage notes (Elixir core remote-access):**
- Migrations all use `@prefix "platform"` — schema-prefix tenancy. Reconcile 4.1/4.6 against that model before remediating.
- Did not audit `paper_trail` storage / retention; if action_inputs ever start including grant refs, 4.8 reopens.
- Broker process registration via `ProcessRegistry` cross-node lookup not audited for signature binding (probably overlaps 4.4 fix).

## 5. Web-NG HTTP / WebSocket / LiveView / JS Surface

- [x] 5.1 [C] Remote-access *settings* LiveViews mounted without `AuthorizeHook` — no per-action RBAC
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:687-816` (routes at 763-768) vs the `:require_authenticated_user_with_permit` session at 818-842 (commit: staging)
      Why: `RemoteAccessHostKeysLive`, `RemoteAccessDesktopTargetsLive`, `RemoteAccessRecordingsLive` only require authentication. JSON-API siblings (`admin_show`, `admin_create`, …) gate on `require_permission(conn, @manage_permission)`, but the LiveViews skip per-event RBAC entirely; any authenticated user can `enable_target`, `disable_target`, `save_target`.
      Fix: Move the routes into `:require_authenticated_user_with_permit` (matches the catalog convention) OR add explicit permission checks in `mount/3` and every `handle_event/3`
      Resolution: Remote-access host-key and desktop-target LiveViews now re-authorize with a fresh RBAC lookup on every handle_params and mutation/form event, and recordings re-authorize view/export permissions on params changes. Regression tests revoke cached permissions after mount and assert host-key/desktop-target mutation events redirect without changing state.

- [x] 5.2 [H] WebSocket stream handler does not re-authorize after `attach`
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/channels/remote_access_stream_handler.ex:69-114` (attach), 117-150 (handle_in) (commit: staging)
      Why: Ticket validated once; permission revocation between attach and the next frame is never seen. Idle/absolute timeouts exist but no revocation-driven close.
      Fix: Periodically re-check actor permission (or subscribe to a permission-revocation pubsub topic that closes affected sockets)
      Resolution: The remote-access WebSocket state now carries an authorization module and periodic reauth timer. After attach, every browser input frame re-checks the protocol-specific open permission, and the periodic timer closes idle sockets with `permission_revoked` if RBAC no longer allows the actor. Tests cover both next-frame and timer-driven revocation.

- [x] 5.3 [H] Browser-supplied SSH session metadata bypasses denylist for non-listed keys (host/port override)
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_session_controller.ex:331-372, 411, 455, 470, 525-558` (commit: staging)
      Why: `drop_client_controlled_metadata` filters known keys + suffix heuristics, but SSH `target_host` / `target_port` overrides are gated only by feature flag — if the flag is on, a user can pivot to arbitrary upstreams via the JSON API.
      Fix: Move target_host/target_port override behind explicit RBAC ("remote-access.ssh.target.override") plus per-tenant allowlist of upstream hosts; the feature flag alone is insufficient
      Resolution: SSH `target_host` / `target_port` overrides now require the deployment flag plus the explicit `devices.remote_access.ssh.target.override` RBAC permission. Host overrides additionally fail closed unless the requested upstream matches `:remote_access_target_host_override_allowlist`; `target_host` and `target_port` are also stripped from client-controlled metadata.

- [x] 5.4 [H] IDOR on recording playback — permission is "can view any SSH recording" not "can view *this* recording"
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_recording_controller.ex:178-187`; `live/settings/remote_access_recordings_live.ex:342-344` (commit: staging)
      Why: Both layers map recording → protocol → permission key. Any actor with `remote-access.ssh.open` can stream/export *every* SSH recording in the tenant, regardless of whether they were ever a party to the session.
      Fix: Scope read on `RemoteAccessRecording` via session → target → actor's device-level permission; deny if actor wasn't the original session actor unless an explicit `recordings.view_all` is held
      Resolution: Recording API show/events/export and the recordings LiveView now load the backing session and require the actor to match `session.requested_by`, unless the actor has `devices.remote_access.recordings.view_all`. Existing protocol-specific open permissions still gate protocol visibility, and cross-user misses return not-found to avoid exposing recording IDs.

- [x] 5.5 [H] CSRF protection on mutating JSON APIs relies on convention, not enforcement
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:307-379` (api_auth pipeline); `:880` `skip_csrf_protection_for_bearer_auth` (commit: staging)
      Why: Cookie-auth POSTs are covered by `:protect_from_forgery` only if every mutating endpoint lives in `:api_auth`. A pipeline mistake silently disables CSRF.
      Fix: Add a CI lint (or a runtime guard) that fails the build if a `post|put|patch|delete` route on the remote-access surface isn't routed through a pipeline that includes `:protect_from_forgery`
      Resolution: Added a static router regression test that parses `router.ex`, asserts `:api_auth` still includes `:protect_from_forgery`, and fails if any mutating `/remote-access...` API route is declared outside the `:api_auth` pipeline.

- [x] 5.6 [M] Host-key fingerprints / target labels rendered in EEx assumed safe
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/remote_access_host_keys_live.ex:230, 242, 310, 323` (commit: staging)
      Why: Today's values are colon-hex; a future schema addition (operator-set label / comment) interpolated the same way becomes stored XSS.
      Fix: Audit + add a property-based test that asserts every host-key field rendered is HTML-escaped; document the rule in `design.md`.
      Resolution: Host-key table rendering remains plain HEEx interpolation, backed by a property-style LiveView test that injects XSS payloads into rendered host-key text fields and asserts raw payloads do not appear while escaped values do. `design.md` now records the remote-access LiveView rule: untrusted hostnames, fingerprints, labels, metadata, and target-observed text stay out of `raw/1`, JS strings, and manually concatenated HTML.

- [x] 5.7 [M] File-transfer controller accepts paths containing `..` / `.`
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_file_transfer_controller.ex:186-197, 209-221` (commit: staging)
      Why: Length and absolute-path checks pass, but `/tmp/../etc/passwd` is forwarded to the broker; the broker is *supposed* to canonicalise but defence-in-depth at the edge is missing.
      Fix: Reject any segment containing `..` or `.` after split; reject NUL / control bytes
      Resolution: `path` and `destination_path` normalization now rejects ASCII control bytes, NUL bytes, and `.` / `..` path segments before permission checks or broker dispatch. Controller tests cover traversal and control-byte inputs for both source and rename destination paths.

- [x] 5.8 [M] Recording export only checks export permission, not view permission
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/remote_access_recording_controller.ex:50-73`; LiveView export button at `:77` (commit: staging)
      Why: An actor holding `recordings.export` but not `recordings.view` can still pull the bytes; should require both. Combined with 5.4 this widens the IDOR.
      Fix: Add `require_recording_view_permission(conn, recording)` before export
      Resolution: Covered by the 5.4 recording authorization fix. API export now requires `devices.remote_access.recordings.export` and then runs the same per-recording view check used by show/events; the LiveView export button is shown only for a selected recording that passed `ensure_recording_allowed/2`.

- [x] 5.9 [L] SSH hook parses `data-props` JSON without prop allowlist
      Where: `elixir/web-ng/assets/js/hooks/RemoteAccessSSHConsole.js:24-33` (commit: staging)
      Why: Defence-in-depth — if a future LiveView interpolates user data into the props dataset, malformed JSON becomes a vector.
      Fix: Validate parsed object against an explicit prop schema; reject unknown keys.
      Resolution: `RemoteAccessSSHConsole` now schema-validates dataset props, rejects non-object JSON, unknown keys, and wrong primitive types, and only forwards known string/boolean props plus the internally supplied terminal module loader. Added a focused Vitest hook test and included it in the asset test script.

- [x] 5.10 [L] Stream handler silently drops unknown messages
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/channels/remote_access_stream_handler.ex:117-150, 144-148` (commit: staging)
      Why: Hides probing / protocol-confusion attempts and forward-compat surprises.
      Fix: Log at warn with `(topic, message_type, actor_id)` and emit a metric.
      Resolution: Unknown browser text/binary stream messages and unexpected server info messages now log at warning level without payload bytes and emit `[:serviceradar, :remote_access, :stream, :unknown_message]` telemetry with count, topic, session_id, actor_id, message_type, and source. Regression coverage asserts the warning and telemetry for an unknown browser message.

- [x] 5.11 [L] Browser stream timeout hardcoded, not session-derived
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/channels/remote_access_stream_handler.ex:568-587`; controller `:70-79`, `:13` (commit: staging)
      Why: Policy can demand shorter sessions; the browser path won't honour them today.
      Fix: Derive from `RemoteAccessSession` policy or per-target config.
      Resolution: The remote access stream controller now fetches the target `RemoteAccessSession` before upgrading, authorizes against the permission implied by the session protocol, and passes WebSockAdapter the shorter of configured browser stream timeout or session idle/absolute timeout policy. Focused controller coverage asserts session-derived timeout selection, configured shorter-timeout precedence, and protocol-specific permission gating.

**Positives (web-ng surface):**
- Input validation (path length, integer ranges, UUID/enum) consistently applied at controller entry.
- Short-lived attach tickets rather than persistent session IDs limit replay window.
- WebSocket frames capped at 65 KiB decoded.
- Metadata denylist actively filters known policy-controlled fields (gap is only "unknown keys" — see 5.3).
- Scope (user + permissions) consistently threaded through every request.

**Coverage notes (web-ng surface):**
- Controller / channel test files exist but were not read — would let us assert each finding has a regression test, recommend follow-up.
- RDP WebRTC signalling (offer/answer/ICE) not in scope here — should be added to Review A2 or a new slice covering SDP/ICE SSRF surface.
- Storage backend / bucket / object_key returned to clients — confirm those strings cannot leak internal infrastructure paths (defer to Review F).
- Session ticket generation not in scope — assumed cryptographically secure (verify in Review D follow-up).

### 5.E2 Coverage Follow-Up (RDP WebRTC + WebCodecs renderer + browser hardening)

Overall: the browser path is well-built — frame parsing fail-closed, DataChannel-only transport (no WebSocket fallback for media), CSP + Permissions-Policy in place, RBAC gate before signalling. Findings are mostly L / defence-in-depth.

- [x] 5.E2.1 [L] SDP offer accepted without client-side media-type / codec allowlist
      Where: `elixir/web-ng/assets/js/lib/remote_desktop/webrtc_client.js:159` (working tree)
      Why: Server-side `Membrane.WebRTC.Signaling` is the assumed filter; if it ever drops a codec restriction the browser swallows whatever SDP arrives.
      Fix: Defensive allowlist (`avc1`, `vp8`, `vp09`, `av01`) on the offer parse before `setRemoteDescription`; document the contract.
      Resolution: The browser validates remote desktop SDP offers before `setRemoteDescription`, permits only `application` and `video` media sections, and restricts video RTP codecs to H264/VP8/VP9/AV1 plus RTP repair codecs. Tests cover allowed offers and fail-closed rejection before applying a bad remote description.

- [x] 5.E2.2 [L] ICE candidates not filtered for private/loopback/link-local on the browser → server hop
      Where: `elixir/web-ng/assets/js/lib/remote_desktop/webrtc_client.js:243-252` (working tree)
      Why: RTCPeerConnection blocks mDNS/loopback by default but not all internal ranges; server filtering is the primary gate (verify in Membrane). Defence-in-depth on the browser is cheap.
      Fix: Reject candidates matching `^127\.|^169\.254\.|^fe80::|^::1|\.local$` before POST; document the server contract on `/candidates`.
      Resolution: Browser ICE handling now parses candidates and rejects `.local`, loopback, link-local, RFC1918, CGNAT, multicast/reserved IPv4, and blocked IPv6 ranges before any POST to the server. Tests assert unsafe candidates are dropped and safe candidates still post.

- [x] 5.E2.3 [M] `VideoDecoder.configure({codec})` accepts untrusted `frame.encoding` via lenient `normalizeCodec`
      Where: `elixir/web-ng/assets/js/lib/remote_desktop/renderer_runtime.js:172` (working tree)
      Why: A compromised RDP server (or man-in-the-middle inside the desktop-media frame) can ship `"h264; x-invalid"`-style codec strings; today they pass through unfiltered.
      Fix: Strict allowlist (`['avc1','vp8','vp09','av01']`); empty return → fail rendering and close the session.
      Resolution: WebCodecs renderer configuration now uses a strict `avc1`/`vp8`/`vp09`/`av01` codec-string allowlist and throws on disallowed encodings; the React session component closes the viewer when renderer frame application fails. Tests cover normalization and rejected codec strings.

- [x] 5.E2.4 [L] CSP doesn't explicitly set `media-src 'none'` / `frame-ancestors 'none'`
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:16-27` (working tree)
      Why: `default-src 'self'` covers media-src by inheritance; explicit `'none'` is defence-in-depth and prevents accidental relaxation.
      Fix: Add `media-src 'none'; frame-ancestors 'none'; display-capture 'none'` (Permissions-Policy) to the desktop-session response.
      Resolution: Browser and API-doc CSP policies now include explicit `media-src 'none'` and `frame-ancestors 'none'`; the default Permissions-Policy now denies `display-capture=()`. Header tests assert the new CSP and Permissions-Policy directives.

- [x] 5.E2.5 [L] Decoded `VideoFrame` not validated against canvas dimensions before `drawImage`
      Where: `elixir/web-ng/assets/js/lib/remote_desktop/renderer_runtime.js:142-147` (working tree)
      Why: drawImage is safe by clamping, but a dimension mismatch can mask a tampered frame from operator view.
      Fix: Optional assert on `displayWidth/displayHeight` vs configured target size; close session on drift > threshold.
      Resolution: WebCodecs output now verifies decoded `VideoFrame.displayWidth/displayHeight` against the canvas render target before `drawImage`; mismatches throw, close the decoded frame, and are surfaced through the same renderer-error close path. Regression coverage asserts mismatch rejection.

- [x] 5.E2.6 [L] TURN credential freshness not validated at runtime
      Where: `elixir/web-ng/lib/serviceradar_web_ng/remote_desktop_webrtc.ex:89-127` (working tree)
      Why: Static TURN creds embedded in app config are an exfil/replay primitive if the config leaks.
      Fix: Either enforce time-bound usernames (`<unix-ts>:<actor>`) at config-load, or document that TURN credentials must be rotated by a deployment-layer process; emit warning at startup if rotation marker absent.
      Resolution: Remote desktop WebRTC ICE server normalization now warns once when configured TURN/TURNS credentials are static or expired by the `<unix-ts>:<actor>` username convention, while accepting fresh time-bound usernames without warning. Tests cover static-warning and fresh-username paths.

**Positives (E2):**
- Frame parser validates magic, version, flag allowlist, reserved bytes, length bounds and trailing-bytes; throws on any error and the call-site closes the session — model implementation of the "fail closed on malformed media" commit (`1ad1907c4`).
- Media + control flow only via DataChannels (no WebSocket fallback), authenticated HTTPS signalling.
- VideoDecoder isolated per-session; renderer doesn't use `transferControlToOffscreen` / SharedArrayBuffer (smaller attack surface today).
- CSP `default-src 'self'`, no `unsafe-eval`, Permissions-Policy denies `camera`/`microphone`.
- Frame validated once at ingress, then trusted (correct one-boundary pattern).

**Coverage notes (E2):**
- Read fully: `webrtc_client.js` (527 lines), `renderer_runtime.js` (263 lines), `media_frame.js` (420 lines), `remote_desktop_webrtc_controller.ex` (344 lines), `security_headers.ex` (128 lines), `renderer_state.js` (~600 lines), router CSP block.
- Not reached: server-side `Membrane.WebRTC.Signaling` SDP/ICE validation — dependency risk; deferred to Review G for the Membrane dep itself.
- Rust/Go RDP media adapter covered in §1 / §1.A2.

**Cross-refs to §5/§6:**
- 5.E2.3 strengthens 1.A2.4 (frame field hardening) — both are "untrusted string from media frame reaches a sink that doesn't constrain it"; pair the fixes.
- 5.E2.2 is orthogonal to 5.2 (post-attach reauth): different threat (browser-as-SSRF pivot vs revoked-actor still streaming).
- Browser path's fail-closed model partially closes the spirit of 3.6 (loss surfacing) — adopt the same "throw + caller closes" pattern for backend losses too.

### 5.K Coverage Follow-Up (Membrane.WebRTC server-side signalling)

Result: the server is **mostly a pass-through** — the codec / fingerprint / ICE / TURN / renegotiation filters E2 assumed exist on the server do not. This promotes 5.E2.1, 5.E2.2, 5.E2.6 (browser-side mitigations were "defence-in-depth"; with no server gate they're the *only* gate).

- [x] 5.K.1 [H] SDP codec allowlist not applied server-side — full delegation to browser + ExWebRTC
      Where: `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/remote_desktop/webrtc_signaling_manager.ex:149-152` (working tree)
      Why: `Signaling.signal()` forwards SDP unchanged. A compromised browser or MITM can negotiate a codec the renderer doesn't sanitise, bypassing 5.E2.3.
      Fix: Parse the answer SDP, allowlist `[h264, vp8, vp09, av01]`, reject on unknown codec / repeated media sections.

- [x] 5.K.2 [M] DTLS fingerprint algorithm not explicitly allowlisted; assumed enforced by ExWebRTC
      Where: `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/remote_desktop/data_channel_provider.ex:123` (working tree)
      Why: `set_remote_description()` delegates parsing entirely to ExWebRTC; if a future version regresses (or a compat shim accepts md5/sha1), the bastion follows.
      Fix: Parse `a=fingerprint` from SDP; require `sha-256` or stronger; document the contract.

- [x] 5.K.3 [H] ICE candidates not filtered before forwarding (no private / loopback / link-local / CGNAT / multicast rejection)
      Where: `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/remote_desktop/webrtc_signaling_manager.ex:161-176` (working tree)
      Why: Server hands candidates straight to the peer. Combined with 5.E2.2 (browser also doesn't filter), the SSRF surface is fully open in both directions.
      Fix: Parse `a=candidate` lines; reject any address in RFC1918 / 127/8 / 169.254/16 / 100.64/10 / 224/4 / IPv6 ULA / link-local; emit metric on drop.

- [x] 5.K.4 [L] `.local` mDNS candidates assumed handled by ExWebRTC
      Where: `data_channel_provider.ex:127-130` (working tree)
      Why: Unverified delegation; mDNS-name leakage from the agent network is a low-volume info leak today.
      Fix: Confirm ExWebRTC rejects unresolved `.local`, or add an explicit filter.

- [x] 5.K.5 [H] TURN credentials read from app config — no per-session ephemeral / TTL enforcement
      Where: `elixir/web-ng/lib/serviceradar_web_ng/remote_desktop_webrtc.ex:74-127` (working tree)
      Why: Static creds embedded in `RTCConfiguration` reach every browser; if any session/log leaks the config block, TURN is exfilable. Promotes 5.E2.6.
      Fix: Mint per-session HMAC TURN creds (`<exp>:<actor>` username, HMAC-SHA1 over a server-side key) with TTL ≤ 1 h; rotate signing key on a schedule.

- [x] 5.K.6 [M] DataChannel created with `ordered: true` but no `max_message_size` / `max_channels`
      Where: `data_channel_provider.ex:160-162` (working tree)
      Why: Unbounded channel proliferation or oversized message → resource exhaustion on the gateway.
      Fix: Set `max_message_size: 16 * 1024 * 1024` (matches RDP media frame cap), `max_channels: 4`; refuse extras.

- [x] 5.K.7 [M] SDP renegotiation not state-machine-gated — multiple offers accepted
      Where: `webrtc_signaling_manager.ex:285-304` (working tree)
      Why: A second `:sdp_offer` adds media sections to an already-attached session; can introduce new codecs / candidates mid-stream undetected by RBAC.
      Fix: After first offer/answer pair lands, transition to `:answered` state and refuse further offers; require a fresh session for renegotiation.

**Positives (Membrane signalling):**
- Per-session `viewer_session_id` UUID auth before offer generation (60s TTL).
- DataChannel uses ordered delivery + a JSON control protocol with `type` validation at `:182`.
- mTLS still terminates upstream of the signalling layer (agent → gateway), so the WebRTC offer source is at least authenticated.

**Coverage notes (Membrane signalling) — explicit answers:**
- M1 codec allowlist: **REFUTED** — no server-side filter.
- M2 fingerprint algorithm: **PARTIAL** — assumed via ExWebRTC, not asserted.
- M3 ICE filtering: **REFUTED** — pass-through.
- M4 mDNS handling: **UNCONFIRMED** — assumed via ExWebRTC.
- M5 TURN ephemeral: **REFUTED** — static config.
- M6 DataChannel limits: **PARTIAL** — ordered yes, size/count no.
- M7 SDP renegotiation: **REFUTED** — additional offers accepted.

**Cross-refs:** 5.E2.1 → 5.K.1 (promote M to H since browser filter is sole gate). 5.E2.2 → 5.K.3 (same). 5.E2.6 → 5.K.5 (now both sides confirm the gap).

### 6.K Coverage Follow-Up (agent ↔ gateway gRPC API)

Result: gRPC layer is **strong** — mTLS enforced at boot, per-RPC identity re-validation, no admin methods on the agent listener, no reflection in prod. Real gaps are message-size / backpressure / credential logging.

- [x] 6.K.4 [H] No `max_message_length` / `max_concurrent_streams` / `keepalive_params` set on the gRPC server
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/endpoint.ex:1-17`; boot at `application.ex:189` (working tree)
      Why: Relies on library defaults; a single compromised or buggy agent can open unbounded streams or push oversized frames and DoS the gateway, which then drops legitimate agents.
      Fix: Set `max_message_length: 16 MiB` (match RDP media cap), `max_concurrent_streams: 100`/agent, keepalive 30 s idle + 10 s TTL; reject overruns with a structured error.
      Resolution: Set Cowboy HTTP/2 caps for `max_concurrent_streams`, `max_connections`, `max_frame_size_received`, `idle_timeout`, and `inactivity_timeout`; added env-bounded overrides and regression coverage.

- [x] 6.K.6 [M] No per-stream credit / backpressure on server-side streaming RPCs
      Where: `go/pkg/agentgateway/gateway_client.go:299-344` (`StreamStatus`) — server handler in `agent_gateway_server.ex` (commit: staging)
      Why: Slow consumer → unbounded send-buffer on the server → memory pressure → cascading failure.
      Fix: Track queued bytes per stream; pause send above threshold; require receiver ACK before resuming. Document the protocol contract.
      Resolution: `StreamStatus` is client-streaming, so no server-to-client per-chunk ACK exists without a protobuf break. The agent now refuses streams above a 16 MiB chunk / 64 MiB stream window before opening the RPC, and the gateway independently enforces the same encoded protobuf byte budgets while processing chunks synchronously under gRPC flow control.

- [x] 6.K.7 [H] `GRPC.Server.Interceptors.Logger` registered at INFO — logs full RPC request/response bodies
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/endpoint.ex:11` (working tree)
      Why: Frame payloads (media, control), credential grant refs (4.8 / 3.H.3), Kerberos config blobs land in plain Logger output; if those logs reach Sentry / log aggregation, every secret on the bastion bus is exfilable.
      Fix: Replace with a project-local interceptor that emits **method + duration + status + actor**; redact bodies entirely. INFO logs must never contain RPC payloads.

**Positives (gRPC):**
- mTLS enforced at boot (`verify_peer`, `fail_if_no_peer_cert`); app refuses to start without certs (`application.ex:241-254`).
- `enforce_component_identity!()` runs on `hello / config / control_stream_message`, comparing cert subject to request agent_id — body-supplied agent_id is never trusted.
- Agent listener only exposes the agent-scoped service set; admin / core methods on a different listener.
- gRPC reflection not registered → unauthenticated enumeration blocked even if the port leaks.
- Client-side exponential backoff + keepalive prevent reconnect storms.

**Coverage notes (gRPC) — explicit answers:**
- G1 mTLS required + cert validation: **CONFIRMED**; revocation by short-TTL rotation, no CRL/OCSP.
- G2 cert subject re-validated per RPC: **CONFIRMED**.
- G3 per-method authz, no admin on agent listener: **CONFIRMED**.
- G4 message-size / stream / deadline limits: **REFUTED** — see 6.K.4.
- G5 reflection disabled: **CONFIRMED**.
- G6 streaming backpressure: **REFUTED** — see 6.K.6.
- G7 sensitive logging: **REFUTED** — see 6.K.7.

**Cross-refs:** 6.K.7 is the *upstream* of why 4.8 / 3.H.1 / 3.H.3 matter so much — fix this first or every credential ref ends up in Logger. 6.K.4 pairs with 5.K.6 (matching media frame cap).

### 3.L Coverage Follow-Up (eBPF probe programs)

Result: eBPF surface is **clean**. Stable tracepoints only (no kprobes/uprobes), strict safe-helper allowlist, fixed-size ringbuf events, `bpf2go` compile-in (no runtime load path), default-off via env var. Two small operational gaps:

- [x] 3.L.1 [M] No explicit minimum kernel-version gate; silent partial loss on older kernels
      Where: `go/pkg/agent/ebpf/runtime_linux.go:54-78` (commit: staging)
      Why: If ringbuf or tracepoint-types aren't supported, verifier rejects and the agent reports `ReasonSelfTestFailed` — operator may not realise telemetry just stopped.
      Fix: Parse `/proc/sys/kernel/osrelease` at startup; require ≥5.8; emit a loud warning + structured `ReasonKernelTooOld` instead of leaving it to verifier failure semantics.
      Resolution: Linux runtime checks now parse `/proc/sys/kernel/osrelease`, record the kernel release/minimum in capability details, and emit structured `kernel_too_old` when the host is below 5.8.

- [x] 3.L.2 [L] No `CAP_BPF` / `CAP_PERFMON` precheck before probe load attempt
      Where: `go/pkg/agent/ebpf/runtime_linux.go:84-116` (commit: staging)
      Why: Agent attempts load and relies on kernel `EPERM`; the operator sees a generic permission failure rather than "missing capability X".
      Fix: Use `capabilities` lib to inspect bounding set; emit `ReasonCapabilityMissing` with the specific cap name in helm/runbook output.
      Resolution: Linux runtime checks now inspect `/proc/self/status` `CapEff` before feature probes and emit structured `capability_missing` with the missing capability names for `CAP_BPF` and/or `CAP_PERFMON`.

**Positives (eBPF):**
- Tracepoints only (`sys_enter_execve`, `sys_enter_connect`, `sys_enter_openat`/`access`/`faccessat`) — stable kernel ABI.
- Helper allowlist is the minimum required (`bpf_probe_read_user{,_str}`, `bpf_ringbuf_{reserve,submit,discard}`, context getters, `bpf_ktime_get_ns`); no kernel-memory reads, no perf events, no unbounded loops.
- All loops `#pragma unroll`-bounded (max 16 iters); each program ~50 lines — far from verifier complexity limits.
- Fixed-size ringbuf event structs (`sr_command_event` 56 B, `sr_network_event` 40 B, `sr_file_event` 300+ B); overflow discarded + counted.
- BPF objects compiled at build via `bpf2go` and embedded in the Go binary — no runtime file-load integrity risk.
- Default-off behind `SERVICERADAR_AGENT_EBPF_ENABLED`; off-state checked before any load.

**Coverage notes (eBPF) — explicit answers:**
- E1 probe types: tracepoints only. E2 maps: ringbuf 1 MiB + 3-entry counter array, default pinning. E3 helpers: safe allowlist. E4 verifier: well below limits. E5 user-influenced params: none. E6 privilege model: needs `CAP_BPF`+`CAP_PERFMON`, no precheck (see 3.L.2). E7 loader: `bpf2go` embedded. E8 output validation: fixed struct sizes. E9 disable: env-var-gated, off by default. E10 kernel version: not enforced (see 3.L.1).

**Cross-refs:** 3.4 (user-space struct decoding bounds) stays open — the BPF side is safe; the *consumer* in `enhanced_recording_ebpf_loss.go` still needs the bounds checks 3.4 called for.

### 6.L Coverage Follow-Up (agent mTLS cert + partition_id derivation)

Result: cert *shape* and *bind* are correct — partition_id is issuer-derived, embedded in CN + SPIFFE SAN, validated only after TLS chain success, no body-echo. Real gaps: **TTL is 365 days**, **no revocation mechanism at all**, and **per-partition authz on the issuer endpoint is conditional**.

- [x] 6.L.1 [H] Default agent certificate TTL is **365 days**
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/cert_issuer.ex:12, 69` (working tree)
      Why: A compromised agent private key has a 365-day window. Bastion best practice is hours to a few days. Combined with 6.L.2 (no revocation) this is the single biggest credential-blast-radius lever on the agent side.
      Fix: Default `validity_days: 1` (or 3); require `--allow-long-ttl` flag for anything longer; emit audit on issuance with TTL > 7 days.
      Resolution: Default is now 1 day; issuer rejects invalid TTLs and values above 30 days unless `allow_long_ttl?: true`; long-TTL opt-ins emit a warning and tests cover defaults, rejections, and explicit override.

- [x] 6.L.2 [H] No revocation mechanism (no CRL, no OCSP, no in-memory denylist)
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/cert_issuer.ex`; gateway TLS at `application.ex:241-254`; `go/pkg/grpc/cert_manager.go` (working tree)
      Why: A stolen agent cert is valid until TTL expiry. Pairs with 6.L.1: today that's up to a year of impersonation; even with the short-TTL fix you still need a kill switch for the active TTL window.
      Fix: Short-term — add an in-memory revocation list (ETS) consulted by the gRPC interceptor; surface a `cert revoke <component_id>` admin endpoint. Medium-term — CRL or OCSP-stapling.
      Resolution: Agent gateway now supervises an ETS-backed `AgentCertificateRevocation` denylist keyed by component id, certificate fingerprint, or serial. `ComponentIdentityResolver` extracts certificate fingerprint/serial and rejects revoked identities before gRPC handlers accept the request. web-ng exposes `POST /api/admin/gateways/:gateway_id/agent-certs/:component_id/revoke`, which RPCs to the selected gateway and inserts the component-id revocation.

- [x] 6.L.3 [M] Per-partition authz on the cert issuer endpoint is conditional on external auth
      Where: `cert_issuer.ex:16-26` (working tree); upstream caller in web-ng/admin RPC
      Why: `partition_id` is a function argument; if the calling endpoint authenticates but doesn't enforce "caller is authorized for *this* partition", an attacker with admin creds can reissue any agent's cert into any partition.
      Fix: Add an `authorize_partition(actor, requested_partition)` check inside the issuer (defence in depth); audit each issuance with `{actor, requested_partition, granted_partition, ttl}`
      Resolution: Gateway-cert issuance now carries `authorized_partition_id` from the web-ng actor context when present. `OnboardingPackages.create_with_gateway_cert/2` rejects requests whose `site`/partition does not match the actor partition before RPC, and `CertIssuer.issue_agent_bundle/4` repeats the partition check before loading CA files.

**Positives (agent cert):**
- `partition_id` and `agent_id` baked into CN + SPIFFE URI SAN by the issuer; never echoed from request body.
- Gateway extracts identity **only after** TLS chain validates (`agent_gateway_server.ex:889-912`).
- CN parsing is exact 3-segment split; no comma/multivalue injection.
- Bootstrap token is Ed25519-signed and single-use; partition is server-derived from the signed payload.
- Cert+SPIFFE SAN gives two layers of identity (CN partition vs SPIFFE component type) — defence in depth.

**Coverage notes (agent cert) — explicit answers:**
- C1 partition issuer-derived: **CONFIRMED**.
- C2 single-value extension: **CONFIRMED**.
- C3 validation after chain verify: **CONFIRMED**.
- C4 TTL bounded: **REFUTED** (365 d, see 6.L.1).
- C5 revocation: **REFUTED** (see 6.L.2).
- C6 reissuance partition-locked: **CONDITIONAL** — depends on caller-side authz (see 6.L.3).
- C7 bootstrap single-use signed token: **CONFIRMED**.

**Cross-refs:** 6.5 (cross-agent media injection) — the *cert* binding is correct; the per-frame check 6.5 demands is the missing piece. 6.L.1 + 6.L.2 are the cert-lifecycle pair; fix together or partial mitigation only.

### 3.J Coverage Follow-Up (datasvc object-store backend)

**Architecture clarified:** the object store is **NATS JetStream Object Store** (no S3, no MinIO, no KMS, no pre-signed URLs). datasvc (`go/cmd/data-services`) is a gRPC wrapper around JetStream, called over mTLS by the bastion + agents. A single shared NATS credential authorises *all* writes / reads / deletes; there is no per-object identity binding.

This makes several earlier findings load-bearing in a new way: 3.H.2 (storage fields leaked to client) is worse than first scored because the storage layer has *no* second authz gate to fall back on; recordings IDOR (5.4 / 5.8) collapses to "any cluster pod with a valid mTLS cert reads any recording".

- [x] 3.J.1 [H] No encryption at rest on the recording object store
      Where: `go/pkg/datasvc/nats.go:885-893` (`objectStoreConfig`); `helm/serviceradar/templates/datasvc.yaml` (commit: staging)
      Why: JetStream stores recording bytes plaintext on the datasvc PVC. PVC snapshot/backup leak or node-disk theft → every recording readable.
      Fix: Layer 1 (infra) — encrypted PVC storage class. Layer 2 (app) — per-recording AEAD (ChaCha20-Poly1305 / AES-256-GCM) with a KMS-wrapped data key stored on the recording row; datasvc only sees ciphertext
      Resolution: Closed for both layers used today. Helm now fails closed to `global.storage.encryptedStorageClassName` for CNPG (current recording rows), NATS JetStream (object-store backing storage), and optional datasvc local data PVCs unless `global.storage.allowInsecureStorage=true` is set explicitly. Current Postgres-backed recording manifests and terminal payload text are also encrypted at the application layer with AshCloak/ServiceRadar.Vault (`encrypted_manifest`, `encrypted_payload_text`), while normal authorized reads still receive decrypted values. Reopen for per-object datasvc AEAD/envelope encryption if the datasvc recording writer is enabled.

- [x] 3.J.2 [M] Object keys are deterministic and enumerable (`remote-access/sessions/{session_id}/recording.jsonl`)
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_recordings.ex:17-19, 267-274` (commit: staging)
      Why: Anyone who knows / guesses a session_id can construct the key; combined with 3.H.2 and 3.J.3, full IDOR.
      Fix: Random 128-bit `object_key` minted at recording-create and stored on the row; never derived from session_id; remove the storage fields from the JSON view (see 3.H.2)
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; storage fields have already been removed from client-visible JSON/LiveView surfaces. Reopen when datasvc-backed recording storage is activated.

- [x] 3.J.3 [H] No per-actor / per-recording authz at the datasvc layer — single shared NATS credential
      Where: `go/pkg/datasvc/nats.go:145-151`; gRPC handlers `go/pkg/datasvc/server.go:268-428`; coarse RBAC `go/pkg/datasvc/rbac.go` (commit: staging)
      Why: Any process with an mTLS cert valid for datasvc can call `UploadObject` / `DownloadObject` / `DeleteObject` for *any* key. The bastion's recording RBAC is bypassed at the storage tier.
      Fix: Carry actor / recording-id in the gRPC call context (signed by the bastion) and enforce in datasvc; or front datasvc with a thin bastion proxy that re-authorises every request
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; reopen as branch-blocking when datasvc-backed recording storage is activated.

- [x] 3.J.4 [H] Object delete has no retention enforcement, no audit, no soft-delete
      Where: `go/pkg/datasvc/server.go:419-428`; recording resource `remote_access_recordings.ex:276-280` (`retention_expires_at` advisory only) (commit: staging)
      Why: Tamper-evidence floor (3.2) fails at this layer — a compromised mTLS-bearing pod can hard-delete any recording with no trace. `retention_expires_at` is metadata only.
      Fix: Soft-delete model — `DeleteObject` writes a tombstone with `{deleted_at, actor, reason}` and refuses hard-delete until `retention_expires_at + grace`; emit audit event into the standard pipeline; cron job hard-deletes after grace + second sign-off
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; reopen when datasvc-backed recording storage is activated. Postgres recording deletion now uses a `:deleted` terminal state with audit.

- [x] 3.J.5 [M] No integrity proof on download — `ObjectInfo.sha256` hint isn't signed or verified server-side
      Where: `go/pkg/datasvc/server.go:359-416` (commit: staging)
      Why: Compromise of JetStream storage or a privileged datasvc operator can rewrite bytes; the SHA256 hint doesn't bind to a trust root.
      Fix: HMAC-sign the recording manifest (key sealed in the recording row, KMS-wrapped); compute HMAC during download and refuse on mismatch. Pairs with 3.H.4 (Merkle chain over events).
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; Postgres-backed recording manifests are now HMAC-signed and bound to event-chain integrity. Reopen for datasvc download verification when datasvc-backed recording storage is activated.

- [x] 3.J.6 [L] datasvc Upload / Download / Delete not wired into the audit pipeline
      Where: `go/pkg/datasvc/server.go` (commit: staging)
      Why: Bastion-side audit covers what the *bastion* did with recordings; the actual storage I/O — which is the security-relevant boundary — is invisible.
      Fix: On each handler, emit a structured audit event with `{actor (from gRPC ctx), object_key, action, recording_id (from metadata)}` via the same audit sink core-elx uses.
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; reopen when datasvc-backed recording storage is activated.

- [x] 3.J.7 [L] No WORM / object-lock equivalent on JetStream
      Where: `go/pkg/datasvc/nats.go:885-893` (commit: staging)
      Why: Compliance-grade tamper-evidence (governance vs compliance retention modes) doesn't exist on JetStream; mutations cannot be physically refused.
      Fix: Application-layer WORM — sign the manifest on completion, refuse any subsequent write that doesn't carry a fresh signed-delete proof; combined with 3.J.4's tombstone model gives an audit-replayable history
      Resolution: Accepted-with-note under C-U. Recording bytes currently live in Postgres and the datasvc object-store writer is dormant; reopen when datasvc-backed recording storage is activated.

**Positives (datasvc object store):**
- Storage path is *cluster-internal gRPC over mTLS* — not internet-exposed; no S3-style anonymous bucket misconfiguration risk class.
- Per-upload size cap (`ObjectMaxBytes`) prevents naive disk-exhaustion DoS.
- NATS creds mounted as K8s Secret, not in env/config — no obvious leak vector in normal logs.
- Recording manifest stores `object_key`, so the audit story has a join point once 3.J.6 is implemented.

**Coverage notes (datasvc object store) — answers to Q1–Q7:**
- **Q1 implementation**: Go gRPC service `go/cmd/data-services` + `go/pkg/datasvc/server.go` wrapping NATS JetStream ObjectStore on port 50057.
- **Q2 encryption at rest**: **plaintext** on JetStream PVC (see 3.J.1).
- **Q3 isolation**: single bucket, single key namespace, no per-tenant/recording ACL (see 3.J.2, 3.J.3).
- **Q4 pre-signed URLs**: not implemented; bastion + agents call datasvc directly over gRPC; the web-ng controller currently hands raw `(bucket, key)` to clients (3.H.2).
- **Q5 retention**: advisory metadata only; no enforcement, no audit on delete (see 3.J.4).
- **Q6 IAM**: shared NATS creds file mounted via K8s Secret; rotation manual via secret update + pod restart; not exfilable from bastion (which only speaks gRPC).
- **Q7 enumeration**: yes — object keys deterministic from session_id (see 3.J.2).

**Cross-refs:** 3.J.2 + 3.J.3 are why 3.H.2 (storage fields leaked) is a *real* IDOR primitive, not just a leak. 3.J.4 is the missing storage-tier complement of 3.2 (recording destroy RBAC). 3.J.5 + 3.J.7 pair with 3.H.4 (recording integrity chain). 3.J.6 is the missing audit hop that makes 6.K.7 (Logger leak) less dangerous — once payload bodies are scrubbed from gRPC logs, the structured audit event is the only record of who touched what.

> **⚠ Reconciliation with Review O (end-to-end walk):** Review O found *no Elixir call sites that write recording data to datasvc* — recordings (manifest **and** events) are persisted as Postgres rows (`remote_access_recordings`, `remote_access_recording_events`), not in the JetStream Object Store. The `storage_backend` / `storage_bucket` / `object_key` columns exist on the schema but are **vestigial / planned**. This **rescopes §3.J**:
>
> - 3.J.1 — re-targets to **Postgres at-rest encryption** (CNPG storage class) for the recording-row content.
> - 3.J.2 — N/A while datasvc is unused; *but* the leaked path strings (3.H.2) are misleading future maintainers — see new 3.O.14 below.
> - 3.J.3 — N/A while datasvc isn't in the recording write path; remains valid for *file-transfer artefacts* (different consumer of datasvc) — needs a separate confirm.
> - 3.J.4 — N/A for recordings as currently wired; relevant when/if the datasvc backend is enabled.
> - 3.J.5, 3.J.6, 3.J.7 — relevance follows: become live findings the moment the datasvc writer is wired in.
>
> Action: confirm whether the datasvc recording backend is *planned-near-term* (then keep 3.J findings active as a pre-merge gate) or *speculative* (then drop the vestigial fields per 3.O.14 and reopen §3.J only when the writer lands).

### 6.N Coverage Follow-Up (agent provisioning + cert reissuance authz)

**Verdict on 6.L.3: STILL OPEN — and the path is broader than first thought.** The issue isn't just inside `cert_issuer.ex` — it starts at `OnboardingPackage.create_with_gateway_cert/1`, which accepts a `site` (== `partition_id`) attribute from the operator with no authz binding to the operator's own partition. The package then drives `GatewayCertificateIssuer.issue_agent_bundle/4`, which RPCs into `CertIssuer.issue_agent_bundle/4`, all the way to a signed cert bound to the operator-chosen partition. *Any operator role can mint a cert for any partition.*

For the current single-tenant deployment, "partition" maps to sites/locations within a single customer — so this is a within-tenant escalation primitive (operator at site A mints a cert pretending to be site B's agent → routes operator traffic through site B's targets). For any future multi-tenant deployment, this is a Critical cross-tenant primitive.

- [x] 6.N.1 [H] Operator can mint an agent cert for any `partition_id` via OnboardingPackage flow
      Where: `elixir/web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex:173` → `gateway_certificate_issuer.ex:15-23` → `agent_gateway/cert_issuer.ex:16-26` (commit: working tree)
      Why: Single primary finding underpinning 6.L.3; the `site`/`partition_id` field is operator-controlled with only `is_operator()` role check, no `actor.partition_id == requested_partition_id` enforcement, no per-partition RBAC. Promotes to **C** in any multi-tenant deployment.
      Fix: Add a `partition_matches()` policy on the `OnboardingPackage` create action; add a defence-in-depth check inside `CertIssuer` so even a bug upstream can't bypass
      Resolution: Closed for partition-scoped actors without adding multitenancy fields. web-ng enforces actor partition equality on `create_with_gateway_cert/2`, forwards the authorized partition to the gateway RPC, and the agent-gateway issuer rejects mismatches independently. Unscoped system/admin actors remain allowed for deployment-wide administration.

- [x] 6.N.2 [H] `OnboardingPackage` lacks a typed `partition_id` field — uses `site: :string` as a proxy
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/onboarding_package.ex:252` (`site: :string`); policies at `:183-209` (commit: staging)
      Why: The Ash `partition_matches()` macro can't be wired because the resource has no `partition_id` attribute — it has a free-text `site`. Type-rename is a prereq for 6.N.1's policy fix.
      Fix: Rename `site` → `partition_id`; FK to the partition (if a resource exists); migrate data
      Resolution: Closed by adding a typed `partition_id` attribute and migration on `platform.edge_onboarding_packages`, backfilling existing `site` values and indexing the canonical field. Package creation, token partition checks, gateway certificate issuance, and bundle generation now prefer `partition_id`; `site` remains a write-through compatibility alias for older API clients and bundle metadata.

- [x] 6.N.3 [H] `/api/admin/edge-packages/:id/download` runs Ash actions with `authorize?: false`
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex:195-214, 227` (commit: staging)
      Why: Token-gated path, but skipping Ash policies means a leaked download token + a *guessed* package id grants delivery for any partition's package — combined with 6.N.7 (no single-use) this is replayable.
      Fix: `authorize?: true` with a `token_actor` (the token's payload carries an actor identity bound to the partition); reject if `package.partition_id != actor.partition_id`
      Resolution: Public download and bundle delivery now decode the signed onboarding token into a scoped token actor carrying `role: :operator` and the token partition, then execute `OnboardingPackages.deliver/3` with `authorize?: true`. The unauthorised package lookup remains only as the pre-delivery token verification step and still requires signed package-id and partition equality before any secret is decrypted.

- [x] 6.N.4 [M] Cert issuance not recorded — no `{actor, requested_partition_id, granted_partition_id, ttl, fingerprint}` audit row
      Where: `cert_issuer.ex:16-26` (no audit emit) (working tree)
      Why: OnboardingPackage events log token lifecycle but not the cert mint. If 6.N.1 is exploited, there's no forensic trace tying a cert to the operator who minted it.
      Fix: Emit an audit event with the full mint context; index by `(actor, partition_id)` for compliance review
      Resolution: Gateway cert issuance now emits a shared audit-stream event on every successful mint with actor, component id/type, requested/granted/authorized partition, TTL, CN, SPIFFE ID, and SHA-256 certificate fingerprint. web-ng forwards the package creator actor through the gateway RPC, and tests assert private keys / cert PEM / bundles are excluded from audit metadata.

- [x] 6.N.5 [M] Bootstrap token payload doesn't carry `partition_id` — server-side cross-check missing
      Where: `go/pkg/edgeonboarding/token.go:36-91`; consumer in `edge_controller.ex:195-227` (commit: staging)
      Why: Signed token covers `{pkg, dl, api}` only. Server-side download accepts the token, looks up the package, doesn't verify `token.partition == package.partition_id`. With 6.N.3, a leaked token + guessed package id crosses partitions.
      Fix: Add `partition_id` to the token payload (bump to `edgepkg-v3`); enforce equality on delivery
      Resolution: Added `edgepkg-v3` tokens with `partition_id`; web-ng now verifies signed token package id and partition/site before delivery; Go bootstrap clients send the signed token back with the raw download token.

- [x] 6.N.6 [M] No max cap or admin approval on `validity_days` — default 365 d (see 6.L.1) is operator-overridable upward
      Where: `cert_issuer.ex:12, 69` (working tree)
      Why: Compounds 6.L.1 — an operator can extend their already-too-long cert TTL further with no audit / approval gate.
      Fix: Hard cap (e.g. 30 d) at the issuer; require admin approval above default; audit every override
      Resolution: Issuer now enforces a 30-day cap unless `allow_long_ttl?: true`, rejects any TTL above the default unless `long_ttl_approved_by` is an admin/system actor, and records the approval actor id in the 6.N.4 mint audit details. web-ng forwards the approval context through the gateway RPC for future admin flows.

- [x] 6.N.7 [M] Bootstrap token has TTL but **no single-use enforcement** in DB
      Where: `onboarding_packages.ex:202-244, 399`; no `download_token_consumed_at` column (commit: staging)
      Why: Leaked token usable until TTL expiry; pairs with 6.N.3 + 6.N.5 for replay across partitions.
      Fix: Add `download_token_consumed_at`; deliver action sets it atomically; subsequent attempts rejected
      Resolution: Added `download_token_consumed_at`, required `status == :issued and is_nil(download_token_consumed_at)` on the Ash deliver update, and delayed package secret decryption until after the consume transition succeeds.

- [x] 6.N.8 [H] No per-partition allowlist / quota on package + cert issuance
      Where: `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/edge_package_live/index.ex:158-178` (commit: staging)
      Why: Even with 6.N.1 fixed, no rate cap → mass-mint of valid agent identities by a compromised operator.
      Fix: ETS/Redis token bucket per actor; per-partition quota with admin-override audit
      Resolution: Gateway-backed onboarding now checks the shared cluster-aware rate limiter before package creation / cert issuance, with separate actor and partition buckets. Admin/system quota overrides are explicit via `quota_override_by` and emit a structured audit event; the LiveView surfaces quota denials with retry timing. Focused DB-backed tests cover actor and partition quota enforcement.

- [x] 6.N.9 [M] CSR generated using user-supplied `component_id` / `partition_id` with no policy-binding check
      Where: `cert_issuer.ex:67-92` (working tree)
      Why: Subject-substitution risk — caller dictates the CN / SPIFFE ID that the cert will carry, with no proof the caller is allowed to claim those values.
      Fix: Issuer derives CN / SPIFFE from the *authenticated caller's* identity (gRPC peer cert / actor context); refuses to use caller-supplied fields when they conflict.
      Resolution: The gateway issuer now validates component and partition subject tokens before loading CA files, rejecting dots, slashes, controls, whitespace, empties, and overlong values that would corrupt CN/SPIFFE parsing. It also accepts `authorized_component_id` and `authorized_partition_id` context and refuses mismatches before signing. web-ng forwards the authorized component id alongside the partition context when requesting an agent bundle, and audit details include the authorized component id.

- [x] 6.N.10 [L] No renewal-time revocation of the predecessor cert (pairs with 6.L.2)
      Where: `cert_issuer.ex` (working tree)
      Why: Old + new cert both valid → stolen-old-cert use window equals TTL even after renewal.
      Fix: On renewal, push old serial into the 6.L.2 denylist atomically.
      Resolution: Successful gateway cert issuance can now carry predecessor fingerprint and/or serial metadata; after the new cert is signed, the issuer pushes those predecessor keys into the agent-certificate revocation denylist with a renewal reason and records the predecessor fields in the mint audit event. Tests cover fingerprint and serial revocation on renewal.

**Positives (6.N):**
- Bootstrap token uses Ed25519 signature — no forgery path.
- Token TTL is enforced (`onboarding_package.ex:399`).
- `OnboardingEvents` records token created / delivered / revoked with `{actor, source_ip}`.
- RPC transport is mTLS (node-to-node), so at least the *machine* identity of the RPC caller is bound.
- System-actor bypass is intentional and consistent with project convention.

**Coverage notes (6.N) — explicit answers Q1-Q11:**
- Q1 authn: mTLS at the RPC layer only; no per-user authentication on the RPC side.
- Q2 partition authz: **REFUTED** — `is_operator()` role only; `partition_matches()` exists in `policies.ex:211` but is never invoked here.
- Q3 token issuance: web-ng admin UI, role-based, no partition allowlist.
- Q4 token validation: signature ✓, TTL ✓, single-use ✗ (6.N.7), partition binding ✗ (6.N.5).
- Q5 reissue partition-locked: **REFUTED** — caller can request any partition.
- Q6 renewal grace: no revocation → old cert remains valid (6.L.2 + 6.N.10).
- Q7 audit: package events ✓, cert mint event ✓ (6.N.4).
- Q8 operator escalation: no documented bypass; the role-only authz **is** the bug.
- Q9 bootstrap key custody: env-var `SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY`; rotation procedure not visible.
- Q10 CSR validation: subject from caller-supplied fields, no policy binding (6.N.9).
- Q11 Vault: no integration; local CA, file/env-based custody.

**Cross-refs:** Confirms + extends **6.L.3** (now five findings, not one). Compounds **6.L.1** (long TTL × operator-controlled `validity_days`). Compounds **6.L.2** (no revocation × no single-use × renewal doesn't revoke). 4.3 (role-vs-partition conflation) is the same pattern manifesting in the approvals workflow.

### 3.O Coverage Follow-Up (recording lifecycle end-to-end flow walk)

**Major architectural finding:** recordings (both manifest and events) are persisted as **Postgres rows** in `remote_access_recordings` / `remote_access_recording_events` — the datasvc Object Store is **not** in the recording write path today. The `storage_backend` / `storage_bucket` / `object_key` columns are vestigial. See the §3.J reconciliation note above; this rescopes several J findings and adds 3.O.14 below.

- [x] 3.O.1 [H] `complete_recording/1` reachable twice on broker terminate (no idempotency guard)
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_broker.ex:171-182, 251-260, 421-430` (commit: staging)
      Why: `handle_cast({:close, ...})` calls `complete_recording`, then `terminate/2` calls it again on `:normal`/`:shutdown` — the second run overwrites the sealed manifest's `event_count` / byte counts, destroying tamper-evidence continuity.
      Fix: Track `state.recording_completed?` (or guard on `state.recording != nil`) in `terminate/2`; refuse second seal; audit on attempt
      Resolution: The broker state now tracks `recording_completed?`; completion and failure paths set the flag, repeated complete/fail calls become no-ops, and `terminate/2` skips lifecycle mutation when a recording has already been sealed. Regression coverage asserts the recording complete hook fires once for a remote close.

- [x] 3.O.2 [H] Export accepts recordings in `:active` / `:pending` — partial / mid-stream export possible
      Where: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_recordings.ex:107-131` + `remote_access_recording_controller.ex:50-73` (commit: staging)
      Why: Export builds a manifest with `completed_at: null` and current event count; later events change the recording but the operator already holds a stale export claiming completeness. Combined with 3.O.6, a policy edit can also retro-apply to the still-recording session.
      Fix: Refuse export unless status ∈ `[:completed, :failed, :expired]`; or label the export `partial: true` and force a fresh export after seal
      Resolution: `RemoteAccessRecordings.export/2` now refuses recordings unless their status is sealed (`:completed`, `:failed`, or `:expired`), and the API returns `409 recording_not_exportable` for active/pending exports. Controller regression coverage verifies an active recording cannot be exported.

- [x] 3.O.3 [H] Manifest is plain JSON with no signature / hash binding to the event list
      Where: `remote_access_recordings.ex:160-184` (`finish_attrs`); no `manifest_sha256` / signature column (commit: staging)
      Why: DB-level access can edit events, leaving manifest stale; no offline-verifiable integrity. Pairs with 3.H.4 (event chain) and 3.J.5 (server-side integrity).
      Fix: Compute `manifest_sha256 = HMAC(server_key, canonical_json(manifest) ++ canonical_event_digest)`; persist; verify on export and on integrity-audit cron
      Resolution: Recording completion/failure now seals the manifest with an `hmac-sha256-v1` integrity block using a key derived from the ServiceRadar edge crypto secret. The signed input includes canonical manifest JSON and the event-chain integrity metadata; export verifies signed manifests before returning them and rejects tampered manifests. Legacy unsigned manifests remain exportable but are explicitly labeled `unsigned_legacy_manifest`.

- [x] 3.O.4 [M] Concurrent export of same recording — no lock, no `export_id`, audit row per call
      Where: `remote_access_recordings.ex:114` (commit: staging)
      Why: Two operators export simultaneously → two artefacts, two audit rows, no correlation; if downstream watermarking exists, the watermarks can mix.
      Fix: Optimistic lock on `recording.export_in_progress?`; mint a unique `export_id` per call.
      Resolution: Export now serializes on the recording row with the same `FOR UPDATE` lock used by event/seal writes, reloads the authoritative recording before building the artifact, mints a UUID `export_id`, and stamps that ID into both the export manifest and audit details. Regression coverage asserts manifest/audit export-id correlation and verifies persisted manifest tampering is rejected after the locked reload.

- [x] 3.O.5 [M] Partial-write ghost — manifest row created but first event write swallowed → orphan `:active`/`:pending`
      Where: `remote_access_recordings.ex:25-32` + `remote_access_broker.ex:95, 213-221` (commit: staging)
      Why: No reaper for stuck `:pending` / `:active` recordings; they consume slots and skew retention/quota math.
      Fix: Oban cron — recordings stuck > N hours without event activity flip to `:expired` + audit.
      Resolution: Added `RemoteAccessRecordingReaperWorker` on the maintenance cron plus `RemoteAccessRecordings.expire_stale/1`. The reaper selects pending/active recordings whose row and latest event activity are older than the configured threshold, recomputes actual persisted event counters, expires and signs the manifest under the recording row lock, and emits a `remote_access_recording_expired` audit event. Regression coverage ages recording/event rows and verifies stale active recordings expire with persisted counters.

- [x] 3.O.6 [H] Export reads `recording.policy` live from the row, not from a sealed snapshot
      Where: `remote_access_recordings.ex:533-542` (commit: staging)
      Why: Even though the policy is *initially* snapshotted at create, the export merges the *current* row value back in — an admin who edits the recording policy retro-applies it to the export.
      Fix: Stop merging live `recording.policy` into export manifest; sign the snapshot at finalisation; export uses only that
      Resolution: Completion now computes raw-payload storage from the create-time policy snapshot embedded in the recording manifest, falling back to row policy only for legacy manifests without a snapshot. Regression coverage mutates the row policy before completion and verifies the sealed manifest preserves the original snapshot.

- [x] 3.O.7 [H] No integrity primitive at all today — once 3.O.3 lands, also bind to the canonical event hash
      Where: `remote_access_recordings.ex:160-184` (commit: staging)
      Why: Without binding manifest + events, a future "let's sign the manifest" patch is still bypassable by swapping the event list under it.
      Fix: When 3.O.3 lands, ensure the signing input is `manifest ++ Σ payload_sha256` (already on each event) — single signature covers both.
      Resolution: The sealed manifest signature input includes the verified event-chain root and event count alongside the canonical manifest body. Export recomputes the event chain before verifying the manifest signature, so swapping or truncating events causes export to fail with `:recording_integrity_check_failed` or `:recording_manifest_integrity_check_failed`.

- [x] 3.O.8 [M] `complete` updates manifest and events without a wrapping transaction
      Where: `remote_access_recordings.ex:57-65` (commit: staging)
      Why: Partial failure leaves a manifest claiming `event_count = N` with fewer than N events persisted; export will be silently incomplete.
      Fix: `Ecto.Multi` wrapping the final-batch insert + manifest update; assert event count matches before commit.
      Resolution: Event writes and recording seal operations now serialize on `platform.remote_access_recordings.id FOR UPDATE`, with Ash notifications collected inside the transaction and emitted after commit. Completion/failure reread and verify the event chain under the lock, refuse mismatched manifest/event counts with `:recording_event_count_mismatch`, and only then sign and seal the manifest.

- [x] 3.O.9 [M] Late-arrival events accepted after manifest seal — no fence
      Where: `remote_access_broker.ex:222-229`; event insert path (commit: staging)
      Why: Network reordering between final `data` and `close` frames lets late events land in DB after manifest is sealed; they're then invisible to the export but visible to the operator-facing UI.
      Fix: Either drain in-flight before seal (with bounded wait), or reject inserts where `recording.status` is terminal.
      Resolution: `record_event/3` now reloads the authoritative recording row before writing and refuses any sealed status with `{:error, :recording_sealed}`. Regression coverage completes a recording, then attempts to append through a stale pre-completion struct and verifies no late event is stored.

- [x] 3.O.10 [M] Playback events stream doesn't re-check RBAC per chunk (TOCTOU on permission revoke)
      Where: `remote_access_recording_controller.ex:35-48` (commit: staging)
      Why: Permission revoked mid-stream continues serving until the connection closes.
      Fix: Per-chunk re-check or subscribe to permission-revocation pubsub (mirrors fix proposed for 5.2).
      Resolution: Closed as stale for the current implementation. Recording replay is not a long-lived chunked stream today; `GET /api/remote-access/recordings/:id/events` authorizes each HTTP request with `require_recording_view_permission/2` and then returns a bounded JSON response. Any future streaming replay endpoint must re-open this item and either re-check RBAC per chunk or subscribe to permission-revocation PubSub before serving incremental chunks.

- [x] 3.O.11 [M] No `:deleted` terminal state — playback can race with delete and return raw "object missing" errors
      Where: no delete action in `remote_access_recording_controller.ex` (commit: staging)
      Why: Operator gets a confusing error mid-playback instead of a clean `410 Gone` + audit linkage.
      Fix: Add `:deleted` state; transition before any storage-side removal; playback path checks status first.
      Resolution: Recording deletion is now a soft terminal transition to `:deleted`, exposed through `DELETE /api/remote-access/recordings/:id` with the existing delete permission and ownership/view-all guard. Playback/events and export paths check the terminal deleted state and return `410 Gone` with a stable `remote_access_recording_deleted` error instead of falling through to missing storage/object errors. Regression coverage verifies the API delete marks the row deleted and subsequent events/export calls return gone.

- [x] 3.O.12 [M] `record_event` trusts `attrs["session_id"]` instead of `recording.session_id`
      Where: `remote_access_recordings.ex:90-93` (commit: staging)
      Why: A broker bug or replayed frame could insert an event with a foreign `session_id`; unique constraint `(recording_id, sequence)` doesn't catch it.
      Fix: Always overwrite with `recording.session_id`; ignore the input field.
      Resolution: Current event construction persists `session_id: recording.session_id`; controller regression coverage now records an event with a spoofed `session_id` attr and asserts the API returns the authoritative recording session id.

- [x] 3.O.13 [L] Redaction-decision metadata is captured at record-time; policy edits don't retro-apply (consistency, not security)
      Where: `remote_access_recordings.ex:288-312` (commit: staging)
      Why: Manifest can show stale redaction decisions if the global CredentialRedactor secrets list changes.
      Fix: Document explicitly; optionally version-stamp the redactor snapshot in the recording.
      Resolution: Recording manifests now include a signed `redaction_policy` snapshot with the credential redactor version, `decision_time: record_time`, `policy_edits_retroactive: false`, and the terminal/input/output payload policy booleans. Regression coverage asserts the snapshot is present on created manifests.

- [x] 3.O.14 [M] `storage_backend` / `storage_bucket` / `object_key` columns are vestigial — leak misleading infra hints to clients
      Where: `remote_access_recording.ex:17-19`; serialized by `remote_access_recording_controller.ex:94-96` (commit: staging)
      Why: No code path writes recording bytes to datasvc today; these fields are populated with placeholder values and shipped to the browser (3.H.2). They mislead future maintainers, exaggerate the attack surface in pen tests, and tempt an attacker to attack the implied object store.
      Fix: Either drop the columns + JSON fields entirely OR feature-flag them behind `recording.storage_backend == :datasvc` (default: `:postgres`). Pair with 3.H.2.
      Resolution: The current client-facing surface treats the Postgres recording backend as authoritative: API responses omit storage backend/bucket/object-key fields from both the recording object and export manifest, and the recordings LiveView renders only lifecycle, content, and desktop policy metadata. Controller regressions assert neither the storage fields nor the default placeholder strings are returned.

**Flow diagram (actual call graph from the walk):**

```
session.request_open ─► RemoteAccessSessions.create [:requested]
session.attach (ticket consumed) ─► [:attached]
broker_start (GenServer) ─► RemoteAccessRecordings.ensure_for_session [:pending]
                          └─ INSERT remote_access_recordings + audit
agent "ready" frame ─► session.activate [:active] + RemoteAccessRecordings.activate

while session active:
  agent frame ─► broker.handle_remote_access_frame
                ├─ count input/output
                └─ RemoteAccessRecordings.record_event ─► INSERT remote_access_recording_events

session terminate (3 branches):
  A. agent "close" frame  ─► finish_recording_for_close ─► complete(...) ─► [:completed]
  B. browser timeout/manual ─► handle_cast :close ─► complete(...)  ─┐
                                      └─► terminate :normal ─► complete(...) ◄── DOUBLE-CALL (3.O.1)
  C. error ─► terminate <other> ─► fail_recording ─► [:failed]

operator POST /export ─► (no status check, 3.O.2)
                        ├─ list_events
                        ├─ export_manifest (re-reads recording.policy live, 3.O.6)
                        └─ audit row
operator GET /events ─► RBAC check ─► bounded one-shot JSON list (3.O.10 closed)

operator DELETE /recording ─► mark `:deleted` + audit; later playback/export returns 410 (3.O.11 fixed)
```

**Positives (3.O):**
- 3-branch session termination is exhaustive (close / timeout / error).
- Event sequence + `inserted_at` ordering forbids reorder ambiguity at read time.
- Credential redaction applied at record time, not lazily.
- Manifest *intends* to be policy-snapshotted at create (the gap is the export-time re-merge, 3.O.6).
- Audit rows are written on every state transition + export.

**Coverage notes (3.O):**
- Fully walked: open → create → events → 3 terminate branches → finalize → export → playback.
- Partially walked: delete (no controller path found — likely admin/cron).
- Not walked: any datasvc upload — none exists in the recording path today, see 3.O.14 + §3.J reconciliation.
- Retention purge job not found — see 3.O.5.

**Cross-refs:**
- **Reshapes §3.J** — see reconciliation note above; several J items become N/A or move to "wake up when datasvc writer lands".
- **3.O.3 + 3.O.7 jointly close 3.H.4** — same fix family (signed manifest binding events).
- **3.O.6 strengthens 4.9** (redaction allowlist) — both are "policy data flows back into a sink that re-renders it later".
- **3.O.10 was closed as stale for current recording replay** — re-open only if a future chunked replay stream is added.
- **3.O.14 + 3.H.2 + 3.J.2** — all pull on the same thread: storage-backend hints leak to clients; for now they're meaningless, but they will become live attack surface the moment the writer lands. Fix this *before* the writer.

### 4.M Coverage Follow-Up (cross-cutting Elixir hygiene scan)

**Result: CLEAN.** Scan of all 14 BEAM-specific anti-patterns across the remote-access Elixir surface (~35 files) produced **zero** findings worth filing. The codebase consistently uses the safe variants of every pattern that has both.

| # | Pattern | Hits | Worth flagging | Notes |
|---|---|---:|---:|---|
| 1 | `String.to_atom` / `to_existing_atom` on user input | 2 | 0 | Both guarded — allowlist (`remote_access_desktop_target_controller.ex:329`) or rescue (`remote_access_session_controller.ex:743`) |
| 2 | `:erlang.binary_to_term` on untrusted bytes | 1 | 0 | Uses `Ash.Helpers.non_executable_binary_to_term/2` (`secret_refs.ex:228`); only on already-decrypted vault payload |
| 3 | `Code.eval_*` / `Code.compile_string` | 6 | 0 | All compile-time (`__CALLER__`) — never on request path |
| 4 | `System.cmd` / `:os.cmd` with interpolation | 2 | 0 | Args sourced from `Application.get_env/2` — no request data |
| 5 | `Process.send` / `whereis` with dynamic key | 2 | 0 | Compile-time module atoms only (`remote_access_pubsub.ex:19`, `broker_registry.ex:90`) |
| 6 | `Logger` touching credentials | 3 | 0 | Generic messages; no payload interpolation in remote-access scope (but see 6.K.7 for the gRPC layer above) |
| 7 | Secret comparison via `==` | 1 | 0 | **Custom constant-time XOR** in `crypto.ex:170-180`; closes 3.H.7 |
| 8 | `Phoenix.HTML.raw` on agent/DB-sourced data | 0 | 0 | Not found in remote-access controllers/LiveViews |
| 9 | Idempotency on credit-bearing actions | 3 | 0 | State-machine immutability (`requested → attached → active`) prevents replay |
| 10 | `with ... else _ -> :error end` swallow | 0 | 0 | None in remote-access |
| 11 | `Ecto.Query ^var` with atom from request | 0 | 0 | None found |
| 12 | Runtime `Application.get_env` for security-critical config | 4 | 0 | Boot-time module pluggability only — not allowlists/timeouts |
| 13 | `Task.start` orphans holding credentials | 0 | 0 | All async work is supervised |
| 14 | Ash `default:` on security-relevant attrs | 0 | 0 | Required fields use `allow_nil?: false` |

**Positives (Elixir hygiene):**
- `Crypto.constant_time_equal/2` (`crypto.ex:170-180`) is hand-rolled bitwise XOR — sound and used at the attach-ticket boundary.
- `secret_refs.ex:220-236` decryption pipeline composes Base64 + nil guards + `non_executable_binary_to_term` — the only correct way to do this in Elixir.
- Atom conversion call sites use the *guarded* pattern (allowlist before `to_existing_atom`, not the reverse).
- Broker registry sticks to compile-time module atoms — no pubsub-key hijack surface there.
- State machines on session/request/cert resources naturally serve as idempotency keys without needing a separate column.

**Coverage notes (Elixir hygiene):**
- 35+ source files greppped across `serviceradar_core`, `web-ng`, `agent_gateway`, `palisade`; ~8 high-risk hits read in full context.
- Sentry telemetry integration was out of scope (none in remote-access modules); if added later, re-scan for credential interpolation.

**Cross-refs:**
- **Closes 3.H.7** — attach-ticket comparison confirmed timing-safe; the action items move to "add regression test" only.
- **Confirms 4.10 in spirit** — broker only ignores unknown frames; no Pattern-10 silent-error pattern hides the ignored case.
- **Contrasts with 6.K.7** — Elixir application Logger calls are clean; the *gRPC interceptor* is the layer that leaks. Fix 6.K.7 and the bastion logging surface as a whole is clean.

### 6.P Coverage Follow-Up (Helm / K8s deploy posture)

Result: solid container-level baseline (drop ALL caps, `runAsNonRoot`, no privesc, SPIRE-issued mTLS, secrets-as-files) but several **pod-level** and **NetworkPolicy** gaps. The agent DaemonSet keeps `privileged: true` despite already having `CAP_BPF`+`CAP_PERFMON`.

- [x] 6.P.1 [H] NetworkPolicy template emits **egress only** — ingress is wide-open across the namespace
      Where: `helm/serviceradar/templates/network-policy.yaml:40-92` (`policyTypes: [Egress]` only) (working tree)
      Why: For a *bastion*, any pod in the namespace can speak to core / web-ng / agent-gateway / datasvc — that includes compromised sidecars or co-tenant workloads. Combined with 6.P.11 this is in-namespace cluster takeover.
      Fix: Default-deny ingress + explicit allow ingress edges (`agent → agent-gateway`, `web-ng → core`, `ingress-controller → web-ng`, `core/web-ng/gateway → datasvc`); emit a second NetworkPolicy or extend the template.
      Resolution: The Kubernetes NetworkPolicy now renders both `Ingress` and `Egress`. Ingress defaults to release-namespace-only, with explicit namespace and CIDR allowlists for shared ingress controllers / load balancers; demo allows the shared `serviceradar-system` Gateway namespace.

- [x] 6.P.2 [H] Agent DaemonSet runs `privileged: true` despite already requesting `CAP_BPF`+`CAP_PERFMON`
      Where: `helm/serviceradar/templates/agent.yaml:87` (`privileged: true`) + caps at `:95` (working tree)
      Why: `privileged: true` grants *all* capabilities, write-access to `/dev/*`, and host-device control. With `CAP_BPF` + `CAP_PERFMON` already explicit, this is a *node-level privesc* primitive on every node running the agent.
      Fix: Drop `privileged: true`; rely on the explicit cap set; verify on each supported kernel (≥5.8 per 3.L.1) that the eBPF programs load with caps only. Fall back to `privileged: true` only with a feature flag + audit on use.
      Resolution: Closed by verification against the current chart: `agent.ebpf.privileged` defaults to `false`, and an eBPF-enabled render grants only the configured `BPF`, `PERFMON`, and `SYS_RESOURCE` capabilities without emitting `privileged: true`. The privileged path remains an explicit operator override for kernels/environments that cannot run the probes with scoped caps.

- [x] 6.P.3 [H] datasvc PVC has no `storageClassName` — defaults to whatever the cluster supplies, often unencrypted
      Where: `helm/serviceradar/templates/datasvc.yaml:148-160` (working tree)
      Why: The infra-layer fix for 3.J.1 (recordings plaintext at rest). Without forcing an encrypted storage class, the PVC inherits the cluster default which is rarely encrypted.
      Fix: Default `storageClassName: "encrypted"` (or site-configurable); document the requirement; refuse to install without an encrypted class unless `--values insecure-storage.yaml` opt-in.
      Resolution: Closed by adding `global.storage.encryptedStorageClassName` and `global.storage.allowInsecureStorage`. CNPG, NATS JetStream, and datasvc data PVC templates now default to the encrypted class and only omit/accept insecure storage when the lab/demo override is explicit.

- [x] 6.P.4 [M] Bootstrap Jobs grant `secrets *` verbs with no `resourceNames` scope
      Where: `helm/serviceradar/templates/nats-creds-generator.yaml:30-33`; `secret-generator-job.yaml:30-33` (working tree)
      Why: A compromised Job pod can list/patch every Secret in the namespace including cluster-cookie, admin-password, CNPG creds, OnboardingToken private key. Transient or not, the role is over-privileged.
      Fix: Add `resourceNames: ["<the specific secret>"]` and restrict verbs to `["get","create","patch"]` (no `list`/`delete`/`update`).
      Resolution: Closed for the two cited bootstrap jobs. `get`/`patch` are now scoped to `serviceradar-nats-creds` or the configured `secrets.existingSecretName`, and `list`/`update` were removed. `create` remains unscoped because Kubernetes RBAC cannot enforce `resourceNames` on create for an object that does not exist yet.

- [x] 6.P.5 [M] `readOnlyRootFilesystem: true` not set on any container
      Where: all pod templates (working tree); helper `_helpers.tpl:256-260`
      Why: An RCE foothold writes its own binary into root-fs and persists; with `readOnlyRootFS` + named `emptyDir` mounts the same compromise has no persistence on disk.
      Fix: Flip default to `readOnlyRootFilesystem: true`; declare per-container `emptyDir` (or `emptyDir: { medium: Memory }` for secret scratch like cert generation). eBPF DaemonSet documented exception.
      Resolution: Shared container security-context helpers now set `readOnlyRootFilesystem: true`, explicit inline container contexts were updated, and scratch-writing jobs/stateful workloads mount named `emptyDir` volumes for `/tmp` where needed. Helm render checks cover default, demo, SPIRE-enabled, cert-regenerator, GoBGP, checker-template bootstrap, db-event-writer bootstrap, CNPG client-cert, and eBPF-enabled permutations.

- [x] 6.P.6 [M] Pod-level `securityContext` missing `runAsUser` and `fsGroup`
      Where: `helm/serviceradar/templates/_helpers.tpl:256-260` (pod helper only sets `runAsNonRoot`+`seccompProfile`); call sites: `core.yaml:68`, `agent-gateway.yaml:52`, `datasvc.yaml:34`, `core-migrations-job.yaml:32`, `nats-creds-generator.yaml:78`, `secret-generator-job.yaml:79`, `cert-generator-job.yaml:78` (working tree)
      Why: Reliance on container-level UID override; one forgotten override silently runs root. `fsGroup` absence also breaks volume-write ownership in `restricted` PSA.
      Fix: Add `runAsUser: 65534` (or 1001 to match) and `fsGroup: 1001` (+ `fsGroupChangePolicy: OnRootMismatch`) to the pod helper; containers override only when they need a specific UID.
      Resolution: Closed by updating the shared Helm pod securityContext helper to set `runAsUser: 1001`, `runAsGroup: 1001`, `fsGroup: 1001`, and `fsGroupChangePolicy: OnRootMismatch` alongside `runAsNonRoot` and `RuntimeDefault` seccomp. Containers with explicit runtime needs still override at container scope.

- [x] 6.P.7 [M] Elixir cluster cookie shared via env-Secret; no NetworkPolicy gate on epmd / dist port
      Where: `core.yaml:131-134`, `web.yaml:273-277`, `agent-gateway.yaml:107-111` (`RELEASE_COOKIE` from Secret); no `:4369` allow rule (working tree)
      Why: Erlang distribution is unauthenticated once the cookie matches; any pod that obtains the cookie *and* can reach `epmd` (4369) + a distribution port can join the cluster as a peer. With 6.P.1 (ingress wide-open) this is reachable from any namespace pod.
      Fix: NetworkPolicy ingress allows `:4369` + distribution port range *only* from matching label selector; rotate the cookie on a schedule; document SPIRE mTLS dependency as the primary identity gate.
      Resolution: NetworkPolicy ingress now separates ordinary application ports from ERTS. EPMD `4369/TCP` and distribution `9100-9155/TCP` are allowed only from same-namespace pods matching the configured cluster-member selector (`serviceradar-core`, `serviceradar-web-ng`, `serviceradar-agent-gateway` by default), and the chart README documents the cookie/port boundary.

- [x] 6.P.8 [M] `PHX_CHECK_ORIGIN` defaults to `"false"` in the web-ng pod template
      Where: `helm/serviceradar/templates/web.yaml:203` (working tree)
      Why: This is the *infra* side of Finding 5.5 — even if the application enforces CSRF, the origin check is disabled by default, weakening the WebSocket / LiveView auth posture for any operator deployment that doesn't override.
      Fix: Default to `"true"`; require an explicit `webNg.checkOrigin: false` override with a values comment about risk; add a helm-lint rule.
      Resolution: Closed by changing the chart and values default to `webNg.checkOrigin: "true"` / `PHX_CHECK_ORIGIN=true`; insecure local reverse-proxy debugging now requires an explicit values override and is documented in the chart README.

- [x] 6.P.9 [L] Bastion control-plane pods have no PodDisruptionBudget
      Where: no PDB templates in `helm/serviceradar/templates/` (working tree)
      Why: Node drain or eviction can take all replicas down; operator lockout from the bastion = outage of the audit/control path during the incident.
      Fix: Add `minAvailable: 1` PDBs for `core`, `web-ng`, `agent-gateway`, `datasvc`.
      Resolution: Closed by adding a Helm PDB template for core, web-ng, datasvc, and enabled agent-gateway deployments, controlled by `podDisruptionBudgets.enabled` and `podDisruptionBudgets.minAvailable`.

- [x] 6.P.10 [L] `imageTag` defaults to `latest`; no digest pinning by default
      Where: `helm/serviceradar/values.yaml:15`; `_helpers.tpl:82-84` (working tree)
      Why: Mutable tag means a compromised registry / re-tag silently ships malicious code on the next pull.
      Fix: Default to a versioned tag; expose `image.digests.*` per service; helm-lint or CI gate that refuses `:latest` in production install.
      Resolution: Chart defaults now use the versioned `v1.2.54` tag for first-party ServiceRadar images and document `image.digests.<service>` pins, which the image helper already honors over tags.

- [x] 6.P.11 [L] eBPF agent's `hostPath` mounts lack inline justification
      Where: `helm/serviceradar/templates/agent.yaml:112-120` (`/sys/fs/bpf`, `/sys/kernel/btf`, `/sys/fs/cgroup`) (working tree)
      Why: Reviewers can't tell which mounts are load-bearing vs leftover; pairs with 6.P.2 — once `privileged: true` is dropped, the minimum mount set should be reflected here.
      Fix: Inline comment block per mount with the specific BPF feature that needs it; CI test that asserts the manifest matches the documented set.
      Resolution: Closed with inline chart comments documenting why each eBPF hostPath exists: bpffs for pinned BPF objects, kernel BTF for CO-RE loading, and cgroupfs for cgroup-attached probes. Helm render validation now covers the documented mount names and paths.

**Per-pod summary:**

| Pod | `runAsNonRoot` | `fsGroup` | `roRootFS` | caps | `host*` | NetPol | Notes |
|---|---|---|---|---|---|---|---|
| core | ✅ via container (1001) | ❌ | ❌ | drop ALL | – | egress only | needs pod-level `fsGroup`, `roRootFS` |
| web-ng | ✅ (10001) | ✅ (10001) | ❌ | drop ALL | – | egress only | best-in-class today; needs `roRootFS` + ingress NetPol |
| agent-gateway | ✅ via container (1001) | ❌ | ❌ | drop ALL | – | egress only | needs pod-level `fsGroup` |
| datasvc | ✅ via container (1001) | ❌ | ❌ | drop ALL | – | egress only | PVC needs encrypted SC (6.P.3) |
| agent DS | ⚠️ false | ✅ (1001) | ❌ | NET_RAW + BPF + PERFMON | hostNetwork | egress only | `privileged: true` redundant (6.P.2) |
| migrations Job | ✅ (1001) | ❌ | ❌ | drop ALL | – | none | needs `fsGroup` |
| NATS creds Job | ✅ (1001) | ❌ | ❌ | drop ALL | – | none | over-broad `secrets *` RBAC (6.P.4) |
| secret-gen Job | ✅ (1001) | ❌ | ❌ | drop ALL | – | none | over-broad `secrets *` RBAC (6.P.4) |
| cert-gen Job | ✅ (1001) | ❌ | ❌ | drop ALL | – | none | over-broad `secrets *` RBAC (6.P.4) |

**Positives (Helm/K8s):**
- Pod helper enforces `runAsNonRoot: true` + `seccompProfile: RuntimeDefault` everywhere.
- Container helper drops `ALL` caps and disables privilege escalation consistently.
- **SPIRE** integration provides workload-attested mTLS — eliminates static long-lived cert secrets in images.
- Secrets mounted as files, not env vars — leak-via-`/proc/<pid>/environ` mitigated.
- web-ng deployment is exemplary: explicit `fsGroup`, init-container as 10001, no shortcuts.

**Coverage notes (Helm/K8s):**
- Read fully: `core.yaml`, `web.yaml`, `agent-gateway.yaml`, `datasvc.yaml`, `agent.yaml`, `network-policy.yaml`, `_helpers.tpl`, `*-rbac.yaml`, bootstrap Jobs, `ingress.yaml`.
- Out of scope: NATS Helm chart (external dep), CNPG, non-remote-access sidecars (db-event-writer, log-collector, trapd, faker), SPIRE agent/controller templates (separate identity-plane review).
- ArgoCD `k8s/argocd/applications/*.yaml` was sampled, not deeply audited.

**Cross-refs:**
- **6.P.3 is the infra companion to 3.J.1** — fix both for defence-in-depth on recording confidentiality.
- **6.P.8 is the infra companion to 5.5** — both must be flipped for CSRF to actually be enforced.
- **6.P.2 + 3.L.2** — once the cap-only path is verified per kernel, the privileged flag goes away cleanly.
- **6.P.1 + 6.P.7** — fix together; ingress NetPol is the gate that makes the BEAM cookie hard to abuse.
- **6.P.4** pairs with 6.L.3 (provisioning RPC authz) — both are "too-broad role on a credential-bearing component".

## 6. Agent Gateway Desktop Media, Palisade Outbound Policy, Build / CI / Packaging

- [x] 6.1 [C] Palisade `NetworkAddressPolicy` doesn't block IPv6-mapped IPv4 (`::ffff:10.0.0.1`)
      Where: `elixir/palisade/lib/palisade/network_address_policy.ex:114-123` (working tree)
      Why: Classic SSRF bypass — a URL like `https://[::ffff:169.254.169.254]/latest/meta-data/` reaches the cloud-metadata endpoint despite the IPv4 allowlist.
      Fix: Detect `{0,0,0,0,0,0xffff,a,b}` IPv6 form, extract the embedded IPv4, and re-run the IPv4 private/loopback check. Add `4in6` test cases.
      Resolution: Palisade and the live ServiceRadar policy copy now extract IPv4-mapped IPv6 addresses and re-apply the IPv4 denylist; tests cover metadata, RFC1918, loopback, CGNAT, multicast, and public embedded IPv4 cases.

- [x] 6.2 [H] Palisade missing IPv4 multicast / CGNAT / reserved and IPv6 multicast ranges
      Where: `elixir/palisade/lib/palisade/network_address_policy.ex:29-35, 114-123` (working tree)
      Why: IPv4 `224.0.0.0/4`, `100.64.0.0/10`, `240.0.0.0/4` and IPv6 `ff00::/8` should all be denied for outbound fetches.
      Fix: Extend the CIDR list and add positive/negative tests for each range.
      Resolution: Expanded the denylist to include unspecified, CGNAT, protocol-assignment, documentation, benchmarking, multicast, reserved, and IPv6 multicast ranges in Palisade and ServiceRadar core policy modules, with positive/negative range tests.

- [x] 6.3 [H?] Confirm `OutboundFetch` is bound to the pre-resolved IP and that redirects stay disabled
      Where: `elixir/palisade/lib/palisade/outbound_fetch.ex:50-100` (working tree)
      Why: Reviewer believes this is already mitigated (request bound to resolved IP, redirects disabled). Lock the property in tests so a future change can't reopen the DNS-rebinding window.
      Fix: Add an integration test that mocks a low-TTL host returning public then private, and asserts the fetch hits the *first* address; assert redirect off by default.
      Resolution: Existing request construction already pins the request URL to the pre-resolved address while preserving Host/SNI. Regression tests now assert that binding and redirect-disabled behavior, and the request builder forces `redirect: false` even if caller opts try to enable redirects.

- [x] 6.4 [M] `OutboundURLPolicy` has no port allowlist
      Where: `elixir/palisade/lib/palisade/outbound_url_policy.ex:33-39` (working tree)
      Why: Allows pivoting through https-on-22/25/587 etc., bypassing scheme-only filtering.
      Fix: Default allowlist of `[443, 80]` for http/https; require explicit caller opt-in for non-standard ports.
      Resolution: Kept the existing HTTPS-only scheme policy and added a default `[443]` port allowlist. Non-standard HTTPS ports require explicit `allowed_ports: [...]` opt-in, and that policy is applied before DNS resolution.

- [x] 6.5 [C] `DesktopMediaServer.validate_desktop_media_frame!` doesn't bind frame to agent / partition
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/desktop_media_server.ex:240-255` (working tree)
      Why: Frame validated against `desktop_session_id` / `media_session_id` only — agent A can submit a frame stamped with agent B's session id and the gateway forwards it. Cross-tenant media injection primitive.
      Fix: After `fetch_session`, assert `session.agent_id == frame.agent_id` and `session.partition_id == frame.partition_id`; refuse + audit on mismatch. Mirror the heartbeat path at `:112`.
      Resolution: Frame ingest now re-checks the authenticated mTLS partition against the partition stored at session open and emits a `[:serviceradar, :desktop_media, :frame, :rejected]` telemetry audit event plus warning log on owner mismatch. `DesktopMediaFrameChunk` does not carry a `partition_id`, so the binding uses cert-derived partition rather than changing the wire protocol.

- [x] 6.6 [M] `DesktopMediaSessionTracker` has no expiry reaper
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/desktop_media_session_tracker.ex:62-180` (working tree)
      Why: Crashed-agent leases stay in memory forever — unbounded growth + stale session-id reuse window.
      Fix: GenServer `handle_info(:sweep, ...)` every N seconds removing sessions with `lease_expires_at_unix <= now` or owner-pid dead; emit metric.
      Resolution: Tracker now schedules `:sweep_expired_sessions`, prunes expired or dead-owner-pid sessions, emits `[:serviceradar, :desktop_media, :session, :expired]`, and sweeps before new admission so expired sessions do not hold capacity.

- [x] 6.7 [M] Control stream + media server don't re-validate the agent cert on each message
      Where: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/control_stream_session.ex:26-42, 139-170` (working tree)
      Why: After `register/1` the session implicitly trusts subsequent `handle_cast({:message, ...})` deliveries. A different agent reaching the same GenServer (eg via process-name reuse / supervisor restart race) sends commands as the registered one.
      Fix: Stash `registered_cert_der` + `registered_agent_id` at register-time and compare on every inbound message; mismatch → terminate + audit.
      Resolution: Control stream registration now stores an mTLS identity context including component id, partition, component type, and SHA-256 cert fingerprint. AgentGatewayServer passes that context with every message delivered to the session; missing or mismatched context emits `[:serviceradar, :control_stream, :message, :rejected]` and terminates the session. Desktop media already extracts the stream certificate per inbound media/control call; 6.5 added the missing partition/session binding.

- [x] 6.8 [L] Cargo additions (`ironrdp-core 0.1.5`, `ironrdp-pdu 0.7`, `md-5`) not pinned with rationale
      Where: `Cargo.lock` (working tree); `rust/rdp-adapter/Cargo.toml`
      Why: `ironrdp` is crypto/protocol code; floating minor lets a future `cargo update` swap behaviour silently.
      Fix: Add a `# audited <date>, RUSTSEC-clean` comment on each pinned line and add `cargo-deny`/`cargo-audit` to CI (see 6.9).
      Resolution: RDP adapter/probe IronRDP dependencies are exact-version pinned with audit rationale comments. The isolated probe now pins blocking/connector 0.10.0, core 0.2.1, graphics/PDU 0.9.0, and session 0.11.0; CI triggers on RDP Rust paths, runs cargo-audit 0.22.1 with only RUSTSEC-2023-0071 and RUSTSEC-2023-0089 documented as upstream transitive exceptions, and runs the isolated probe plus both adapter connector Bazel tests with `--lockfile_mode=error`. The upgrade removes yanked `spin 0.9.8` and the stale `paste` advisory.

- [x] 6.9 [H] AGPL guardrail `check-teleport-license-paths.sh` is not invoked by any CI workflow
      Where: `scripts/check-teleport-license-paths.sh` exists, `.forgejo/workflows/*` doesn't call it (working tree / staging)
      Why: The whole "no AGPL transitive Teleport import" guarantee in `expand-remote-access-teleport-parity` is enforced only by convention. Any contributor adds an offending import → it lands.
      Fix: New workflow `.forgejo/workflows/license-check.yml` running the script on every PR; fail build on non-zero exit; cache the Teleport checkout
      Resolution: Added `.forgejo/workflows/license-check.yml`, which runs on PRs, protected-branch pushes, and manual dispatch, caches a Teleport checkout, installs Go from `go.mod`, discovers ServiceRadar's actual Teleport Go imports, and invokes `scripts/check-teleport-license-paths.sh` only when such imports exist.

- [x] 6.10 [L] Mixed action-pinning style — some `@v4`, some pinned SHAs
      Where: `.forgejo/workflows/release.yml`, `.forgejo/workflows/palisade-publish.yml` (working tree / staging)
      Why: Floating tags weaken supply-chain stance.
      Fix: Pin all `uses:` to full commit SHAs with a `# <action>@<tag>` comment.
      Resolution: Pinned Palisade's cache action to the repository-standard SHA and annotated every release/Palisade pinned action with the upstream tag it was resolved from.

- [x] 6.11 [M] Authentik OIDC fixture prints `client_secret` in fixture JSON / shell var
      Where: `scripts/authentik-remote-access-oidc-fixture.py:52-70`; `scripts/remote-access-authentik-oidc-ssh-smoke.sh:102-114` (working tree)
      Why: Test-only secret, but persists in test logs / CI artefacts; reusable against the dev Authentik instance.
      Fix: Strip `client_secret` from emitted JSON with `jq 'del(.client_secret)'`; unset shell var after use; rotate the dev provider secret per run.
      Resolution: The wrapper now generates a per-run client secret and passes it into fixture provisioning; the fixture JSON no longer emits `client_secret`, and the wrapper unsets the secret-bearing shell variable after token exchange / smoke-script use.

- [x] 6.12 [L] `release.yml` triggers on any `v*` tag push with no required approval gate
      Where: `.forgejo/workflows/release.yml:17-21` (working tree / staging)
      Why: An accidental or unauthorised tag push releases unreviewed code; the existing `environment: release` is only a documentation aid without protection rules.
      Fix: Configure environment protection rules requiring reviewer approval; restrict tag push to a protected branch.
      Resolution: Added an in-workflow release-source gate after checkout: release tags or manually selected release commits must resolve to a `v<version>` tag/commit reachable from `origin/staging`, otherwise the workflow fails before signing or publishing artifacts. The workflow still declares `environment: release`; required reviewer approval must be enforced in Forgejo environment protection settings because that policy is instance configuration, not repository YAML.

**Positives (gateway / palisade / CI):**
- Media server validates agent identity at *session open* via mTLS cert (`desktop_media_server.ex:23-24, 458-471`) — gap is only per-frame (see 6.5/6.7).
- Per-agent and per-gateway session-count limits enforced (`desktop_media_session_tracker.ex:72-98`).
- Palisade blocks RFC1918 + link-local + loopback for both v4 and v6 (gaps only in 6.1/6.2).
- `OutboundFetch` binds to the resolved IP, defeating naive DNS-rebinding after policy validation.
- Smoke scripts use ephemeral per-run nonces and clean up after themselves.

**Coverage notes (gateway / palisade / CI):**
- Partition-id derivation from cert assumed correct — out of scope; if a cert can be issued with a spoofable partition extension, 6.5 graduates to bastion-wide.
- No RUSTSEC scan run in this pass; recommend `cargo audit --json` once 6.8/6.9 land.
- CI workflow secret handling otherwise good; recommend adding `permissions:` block to every workflow to enforce least-privilege tokens (currently implicit).

### 6.G Coverage Follow-Up (supply-chain & dependency security)

Overall: dep posture is good — Cargo.lock + go.sum committed, no `[patch.crates-io]` / git-without-rev / alt-registries, ironrdp's heavyweight connector/session/blocking crates are quarantined in the `rdp-connector-probe` (review-only). Main gap is still the unwired AGPL guardrail.

- [x] 6.G.1 [M] `check-teleport-license-paths.sh` confirmed not invoked by any of 15 workflow files
      Where: `.forgejo/workflows/*` (working tree / staging)
      Why: Same as 6.9 — the AGPL guarantee is convention-only. Promote to M (was L in 6.G context) because OSV-Scanner / Syft are wired in `source-security.yml`, so adding this is a small extra step there.
      Fix: Append a step to `source-security.yml` (or a new `license-audit.yml`) that runs the script with the package list from `expand-remote-access-teleport-parity/matrix.md`9.
      Resolution: Covered by 6.9 via dedicated `.forgejo/workflows/license-check.yml`; it discovers actual ServiceRadar Teleport imports and invokes the AGPL path scanner on PRs, protected-branch pushes, and manual dispatch.

- [x] 6.G.2 [M] No `cargo audit` (RUSTSEC) wired for `rust/rdp-connector-probe`
      Where: CI workflows (working tree); crate at `rust/rdp-connector-probe/Cargo.toml`
      Why: The connector-probe pulls exact-pinned ironrdp-connector/blocking 0.10.0 and ironrdp-session 0.11.0 (RDP state machine, CredSSP, blocking I/O) — review-only today but the lock is already on disk and updates otherwise run silently.
      Fix: Add `cargo-audit --deny warnings` to `rust-tests.yml` against the connector-probe workspace member; surface advisory IDs as PR comments
      Resolution: `rust-tests.yml` includes RDP crate paths and runs `cargo audit --deny warnings` against `rust/rdp-connector-probe`. The workflow lists only RUSTSEC-2023-0071 and RUSTSEC-2023-0089 as current review-only transitive exceptions; any new RustSec warning or vulnerability fails CI. It also runs the isolated probe and both adapter connector Bazel tests with an immutable module lock. The 2026-07-13 refresh removed yanked `spin 0.9.8` and obsolete RUSTSEC-2024-0436 while retaining non-yanked `spin 0.9.9` only in IronRDP connector 0.10.0's forced smart-card build subtree.

- [x] 6.G.3 [L] `github.com/cilium/ebpf v0.21.0` maintenance window not documented
      Where: `go.mod` (working tree)
      Why: eBPF is high-privilege; if v0.21.0 is >12 mo old without a follow-up, dependence on it deserves a written rationale.
      Fix: Note release date + last CVE-patch version in a short ADR or in §3 of `add-remote-access-ebpf-recording/design.md`; review again at each ServiceRadar release cut.
      Resolution: `add-remote-access-ebpf-recording/design.md` now records the 2026-05-18 revalidation, notes `github.com/cilium/ebpf v0.21.0` as latest/published 2026-03-05, documents that no newer CVE-only patch release was identified, and requires review at every ServiceRadar release cut or within 12 months.

- [x] 6.G.4 [L] Installer scripts download tarballs from GitHub releases without `cosign verify-blob` / SHA256 check
      Where: `scripts/install-syft.sh:32`; equivalent pattern in `remote-access-authentik-oidc-ssh-smoke.sh:116, 126`; (working tree)
      Why: Acceptable today (curl `-fsS` + GH release infra), but a single compromise (token leak, tag rewrite, account takeover) ships a poisoned helper.
      Fix: Pin SHA256 next to each download or `cosign verify-blob` against the release signature; fail script on mismatch.
      Resolution: Added a shared SHA256 verifier for release-asset installer scripts and pinned the current Bazelisk, Syft, Cosign, ORAS, Gitleaks, and OSV-Scanner assets. Version overrides now require the matching `*_SHA256` override or fail closed.

- [x] 6.G.5 [L] `github.com/kr/fs v0.1.0` (transitive via pkg/sftp) is dormant
      Where: `go.sum` (working tree)
      Why: Minimal interface library, low attack surface, but unmaintained transitive deps in file-handling paths deserve a one-line acknowledgement.
      Fix: Note in the file-transfer threat model that kr/fs is dormant and trusted only as a shim; review at every pkg/sftp bump.
      Resolution: Added the dependency-maintenance note to the file-transfer proposal's SFTP dependency guidance, limited `github.com/kr/fs` to the `github.com/pkg/sftp` path, and required review on every `pkg/sftp` bump.

- [x] 6.G.6 [L] `maxminddb-golang v1.13.1` removed without a commit message rationale
      Where: `go.mod` deletion; `go.sum` deletion (working tree)
      Why: Was used elsewhere for geolocation; removing without an explanation makes "did we lose a feature?" hard to answer in 6 months.
      Fix: Add a CHANGELOG entry or commit-message follow-up describing what (if anything) replaced it, or confirm dead-code removal. Non-security, but housekeeping that prevents an accidental re-add.
      Resolution: Existing CHANGELOG entry documents that MTR ASN enrichment moved out of the agent and into core via `ServiceRadar.Observability.GeoIP`, removing the MaxMind Go dependency and `asn_db_path` / `ASNDBPath` agent configuration.

- [ ] 6.G.7 [L] Remove IronRDP's forced smart-card dependency subtree when upstream exposes a feature gate
      Where: `rust/rdp-connector-probe/Cargo.toml`; `openspec/changes/add-remote-access-desktop-rdp/dependency-review.md`
      Why: `ironrdp-connector 0.10.0` unconditionally enables `sspi/scard`, so the isolated review graph retains `winscard 0.3.3 -> iso7816 0.1.4 -> heapless 0.7.17 -> spin 0.9.9` even though ServiceRadar rejects smart-card redirection before connector construction. Cargo features are additive, so `default-features = false` cannot remove this unreachable build baggage.
      Fix: Upgrade to a maintained upstream IronRDP release that feature-gates `sspi/scard`, disable that feature, and verify `cargo tree --locked --target all` contains no `winscard`, `iso7816`, `heapless`, or `spin`. Do not add a ServiceRadar-maintained connector fork, version override, archived `spin` vendor, or audit ignore to work around the upstream feature shape.

**Positives (supply chain):**
- ironrdp's heavyweight crates (-connector / -session / -blocking / -graphics) live only in the **review-only** `rdp-connector-probe`; the production `rdp-adapter` keeps a minimal direct-dep footprint (ironrdp-core, ironrdp-pdu, zeroize).
- All Cargo dep sources are crates.io; no `git =`, no `[patch.crates-io]`, no `replace` directives.
- Bazel `MODULE.bazel` uses only canonical-registry pins; no `git_override` / `single_version_override` / `archive_override`.
- The isolated RDP connector probe declares rustls 0.23.40 / `rustls-native-certs 0.8.3` and currently locks 0.23.42 / 0.8.4; modern AEAD/TLS-1.2+ posture.
- Both `Cargo.lock` and `go.sum` checked in; OSV-Scanner + Syft already run in `source-security.yml`.

**Coverage notes (supply chain):**
- A fresh 2026-07-13 `cargo audit --deny warnings` run passed for the isolated RDP connector probe with only the two documented upstream exceptions; OSV-Scanner remains covered by `source-security.yml`.
- Membrane.WebRTC dep (server-side SDP/ICE) not audited here — review-E2 deferred it.
- License scanning today is OSV (vulns) only; the AGPL surface needs its own gate.

**Cross-refs:**
- 6.G.1 ≡ 6.9 — file one Forgejo issue, not two.
- 6.G.2 pairs with 6.8 — both want CI dep enforcement; group into the same workflow PR.

### 7.I Coverage Follow-Up (regression-test coverage for H/C findings)

Coverage classification: COVERED / PARTIAL / MISSING / N/A.

| Finding | Sev | Coverage | Citation | Recommended test |
|---|---|---|---|---|
| 1.1 | H | MISSING | `rust/rdp-adapter/tests/` has no actor-binding test for `DesktopCredentialGrant` | Mock grant with `actor_id != authenticated_caller`; assert rejection + grant zeroisation |
| 1.2 | H | MISSING | No test exercises invalid-UTF-8 path through `SensitiveString::expose()` | Craft grant with non-UTF-8 password bytes; assert `Err` and session fails closed |
| 1.A2.1 | C | MISSING | No test covers binary/DER CA-bundle input | Feed non-PEM bytes; assert structured `ca_bundle_invalid` error |
| 1.A2.2 | H | MISSING | Backend credential-build path untested for actor_id | Pair with 1.1 test; assert `build_memory_user_credential` rejects grant.actor_id mismatch |
| 2.1 | H | MISSING | `go/pkg/agent/proxmox_console_ssh_test.go:40-104` tests bridge routing only; raw `err.Error()` at `:120` unguarded | Mock SSH dial failure with hostname/auth detail; assert PTY output is generic |
| 3.1 | H | MISSING | `go/pkg/agent/remote_file_transfer_test.go` has no cancellation propagation | Cancel parent ctx mid-upload; assert goroutine exits and in-flight writes refused |
| 3.2 | H | MISSING | `remote_access_file_transfers_test.exs` / recordings have no destroy-RBAC test | Actor without `recording.delete`; assert denial + audit |
| 3.H.1 | H | MISSING | No PaperTrail-content test for excluded inputs | Create session with `credential_rule_id`; assert `*_versions` row omits it |
| 3.H.2 | M | MISSING | No JSON-schema regression on recording controller view | Assert response JSON has no `storage_backend`/`storage_bucket`/`object_key` |
| 3.H.3 | M | COVERED | `SecretRefs` signs grant refs and rejects tampering/expiry; central grant test asserts remote-access broker emits the signed ref path | Keep replay-window coverage with `SecretRefs.network_credential_grant_ref/2` tests |
| 4.2 | C | PARTIAL | `remote_access_sessions_test.exs:66-121` returns `:invalid_or_expired_ticket` on second attach | Promote to: assert atomic state transition to `:consumed`; add cross-session replay |
| 4.3 | H | MISSING | No `remote_access_requests_test.exs` for self-approval | Requester w/ review perm approves own req; assert `forbid_if` unless `allow_self_approval` |
| 4.4 | H | PARTIAL | `remote_access_broker_test.exs:691-750` exercises string-equality | Once HMAC lands, add forged-pair-without-HMAC negative case |
| 4.5 | H | COVERED | `remote_access_host_keys_test.exs` asserts rotation linkage, reject audit, rejected terminal behavior, and direct `:conflict` trust denial; `remote_access_host_keys_live_test.exs` asserts conflict rows expose reject instead of trust | Keep API/LiveView parity if additional host-key transitions are added |
| 5.1 | C | COVERED | `remote_access_host_keys_live_test.exs` and `remote_access_desktop_targets_live_test.exs` revoke cached permissions after mount and assert mutation events redirect without changing state | Keep route-level Permit hook migration as optional cleanup if settings sessions are reorganized |
| 5.2 | H | MISSING | `remote_access_stream_handler_test.exs` has no revocation scenario | Revoke perm via pubsub mid-stream; assert socket closes + audit |
| 5.3 | H | MISSING | `remote_access_session_controller_test.exs` lacks target_host/port override RBAC | Flag on, actor missing override perm; assert rejection + not-in-allowlist case |
| 5.4 | H | MISSING | `remote_access_recording_controller_test.exs` has no IDOR case | Actor A reads recording from B's session; assert 403 unless `recordings.view_all` |
| 5.5 | H | N/A → CI lint | No build-time enforcement | Add a CI script that fails the build if a mutating remote-access route bypasses `:protect_from_forgery` |
| 5.E2.3 | M | MISSING | No browser test for codec allowlist | Frontend unit: feed unknown codec; assert renderer fails closed |
| 6.1 | C | MISSING | No test file for `palisade/network_address_policy.ex` | Feed `::ffff:10.0.0.1`; assert reject after embedded-v4 extraction |
| 6.2 | H | MISSING | Same module — no IPv4 multicast/CGNAT/reserved + IPv6 multicast | Tests per range; assert reject |
| 6.5 | C | MISSING | `desktop_media_server_test.exs:178+` binds on `media_session_id` only | Send frame w/ mismatched `agent_id` then `partition_id`; assert reject + audit |
| 6.7 | M | MISSING | `control_stream_session_test.exs` has no cert-revalidation case | Cast a message from a different cert/agent_id than registered; assert termination |
| 6.9 / 6.G.1 | H | N/A → workflow | `.forgejo/workflows/*` doesn't invoke `check-teleport-license-paths.sh` | Add workflow that runs the script on every PR; verify it fails on a planted AGPL header |

**Highest-priority test gaps:**
1. **Frame-signing trio (4.4 + 6.5 + 6.7)** — three findings all rely on string equality; one negative test per layer is the only way to make HMAC/cert rebinding regression-proof.
2. **Recording IDOR + LiveView event-RBAC (5.4 + 5.1)** — biggest within-tenant data-exposure class; a single test pattern (`actor_without_perm + handle_event/get` → assert deny) covers both.
3. **Palisade SSRF coverage (6.1 + 6.2)** — module has no test file at all; add one with full range matrix.
4. **Proxmox error sanitisation (2.1)** — small test, high regression risk because the leak path is a single line.
5. **Permission-revocation mid-stream (5.2)** — needs the most new infrastructure (a perm-revocation pubsub stub), so do it early.

**Test-infrastructure observations:**
- Ash policy tests already use `actor:`, `AuditSink`, `CommandBusStub`, `PubSubStub` — negative-case test cost is low.
- Host-key tests have good `unique_host()` / `observation()` fixtures; reuse for the negative cases above.
- No property-based testing in use (`propcheck` / similar) — frame parsing (`media_frame.{rs,js}`, RDP wire) would benefit; suggest a single shared crate/lib helper before writing fuzzers per slice.
- WebSocket mocking is limited to mTLS cert identity at open — extending to per-message recheck needs a cert-stash helper (one-time cost).
- No permission-revocation pubsub stub exists in web-ng — first revocation test should land it as a shared support module.

**Coverage notes (test review):**
- Fully read: `remote_access_broker_test.exs:691-750`, `remote_access_sessions_test.exs:66-121`, `remote_access_host_keys_test.exs:88-106`, `remote_access_host_keys_live_test.exs` (mount + viewer block), `desktop_media_server_test.exs:132-176`, `proxmox_console_ssh_test.go:1-330`.
- Sampled via grep: file_transfers, stream_handler, recording_controller, session_controller test files — confirmed missing assertions, not full read.
- Not found / not present: any test file for `palisade/network_address_policy.ex`, `remote_access_requests.ex` approve action, or RDP credential-binding in `rust/rdp-adapter/tests/` (only `connector_live_probe.rs`).

## 7. Cross-Cutting / Spec Deltas

- [x] 7.1 Threat-model gate for every new protocol adapter — codified as "Remote-Access Adapter Security Review Gate".
- [x] 7.2 Credential zeroisation + signed-short-TTL credential refs + audit-input exclusion — codified as "Credential Custody and Zeroisation".
- [x] 7.3 Single-tenant today + multi-tenant readiness — covered via FJ-V tracking + "Recording Access Scoping" (within-tenant IDOR is the real concern under the single-tenant model; multi-tenant `tenant_id` strategy is tracked in C-V, not specced as a current requirement).
- [x] 7.4 Recording tamper-evidence floor — codified as "Recording Integrity and Lifecycle Custody".
- [x] 7.5 Desktop redirection-default-off — codified as "Desktop Adapter Redirection Default-Off".
- [x] 7.6 Palisade outbound network policy — codified as "Outbound Network Policy for User-Driven Egress".

Additional cross-cutting requirements added beyond the original 7.1–7.6 list (each derived from a cluster):
- "Bastion Logging Confidentiality" (from C-O / 6.K.7).
- "Authenticated Frame Routing" (from C-D).
- "Single-Use Session Attach Tickets" (from C-F).
- "Per-Action Authorization and Post-Authentication Re-Check" (from C-J).
- "Recording Access Scoping" (from C-C).
- "Approval Workflow Integrity" (from C-E).
- "Agent Identity Lifecycle" (from C-Q).
- "Bootstrap Token Lifecycle" (from C-Q).
- "Server-Side WebRTC Signalling Filtering" (from C-T).
- "eBPF Probe Safety" (from C-I).
- "Kubernetes Deploy Posture for the Bastion" (from C-R / C-S).
- "Supply-Chain License and Vulnerability Gate" (from C-P).
- "Recording Sensitive-Field Redaction Allowlist Discipline" (from 4.9).

## 8. Triage

### 8.1 Triage rules

This proposal is the single source of truth — we are **not** filing parallel forgejo issues. Each finding gets one of:

- **In-branch fix (`B`)** — bug introduced or surfaced on `codex/remote-access-desktop-rdp` working tree; remediated as part of this PR.
- **Follow-up cluster (`C-A`…`C-V`)** — bug rooted in staging code or shipping as its own focused PR against staging; grouped here by shared remediation so each cluster ≈ one future PR. Implementation tracked under §8.2 below; status checked off here when the cluster's PR merges.
- **Accept-with-note (`Acc`)** — L-severity defence-in-depth or operational hygiene not worth tracking as code work; recorded with a sign-off rationale so reviewers know the call was made deliberately.
- **Closed (`Cls`)** — finding superseded or invalidated by another review.
- **Spec delta (`Spec`)** — captured in §7 / `specs/edge-architecture/spec.md` rather than as a code fix.

Severity overrides: any **C** or **H** must end up in `B` or a cluster — no accept. Any finding that blocks this branch's merge is annotated **BLOCKING** in §8.3.

> **Note on the `" They are *not* action items — they predate this triage decision. Triage authority lives in §8.5; per-finding markers can be ignored as remediation hints.

### 8.2 Remediation clusters

Each cluster below is a unit of work tracked in this proposal — typically corresponds to one focused follow-up PR against staging (or against this branch, if the user decides to bundle). Cluster IDs are referenced from §8.5.

- **C-A. Replace static credential refs with signed, short-TTL handles + scrub audit inputs**
  Members: 4.8, 3.H.1, 3.H.3.
  Body: implement HMAC-signed (`secret_id, exp, nonce`) tokens in `SecretRefs.network_credential_ref/1` with sub-minute TTL; verify on deref; switch `RemoteAccessSession` / `RemoteAccessRequest` PaperTrail to `store_action_inputs? false` (or add `credential_rule_id`/`approval_id`/`metadata` to `ignore_attributes`).

- **C-B. Recording tamper-evidence floor (hash-chained, signed manifest, transactional finalize)**
  Members: 3.2, 3.H.4, 3.O.1, 3.O.3, 3.O.6, 3.O.7, 3.O.8.
  Body: drop `defaults [:destroy]` and gate on `recording.delete` RBAC + audit; add `prior_event_hash` + Merkle root + signed `manifest_sha256`; idempotency guard on `complete_recording/1`; stop merging live `recording.policy` into export manifest; `Ecto.Multi` around final batch + manifest write.

- **C-C. Recording IDOR / playback authz + drop vestigial object-store hints**
  Members: 5.4, 5.8, 3.H.2, 3.O.2, 3.O.10, 3.O.11, 3.O.14.
  Body: per-session/actor scope on recording read; `require_recording_view_permission` before export; reject export unless terminal status; record that current events replay is bounded one-shot JSON rather than chunked streaming; `:deleted` terminal state with 410 Gone playback; remove `storage_backend`/`storage_bucket`/`object_key` from JSON view + LiveView (or feature-flag).

- **C-D. Frame-signing contract — broker, media server, control stream, registry**
  Members: 4.4, 6.5, 6.7, 3.H.6.
  Body: mint per-session HMAC key on broker accept; every frame carries HMAC over `(session_id, agent_id, seq, payload_hash)`; mirror in `DesktopMediaServer.validate_desktop_media_frame!`; pin `registered_cert_der` + `registered_agent_id` on `ControlStreamSession.register/1` and recheck per inbound message; pid-bind broker registry re-register.

- **C-E. Approval state machine — self-approval forbid + atomic bind**
  Members: 4.3, 4.7.
  Body: `forbid_if expr(approver_id == requested_by)` unless explicit `allow_self_approval`; wrap `bind_session` in `Ash` transaction + `pg_advisory_xact_lock` keyed on approval_id.

- **C-F. Session attach ticket — single-use enforcement**
  Members: 4.2.
  Body: transition to `:attached` (and `consumed_at`) inside `Ash` transaction on first consume; refuse second consume with audit; lock down to existing timing-safe comparison (`crypto.ex:170-180`).

- **C-G. SSH adapter polish — error sanitisation, TOCTOU, extension policy, rate limit, HSM**
  Members: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7.
  Body: generic PTY error + server-side detailed log; `[:write, :exclusive]` for CA command signer payload; deny-list dangerous cert extensions unless policy approves; token-bucket per-actor cert mint cap; replace shell template with direct `exec`; HSM/Vault backend option for CA key; explicit algorithm allowlist (Ed25519, ECDSA P-256+).

- **C-H. File-transfer hardening — context lifecycle, approval recheck, path safety**
  Members: 3.1, 3.5, 3.7, 5.7.
  Body: thread session ctx through `HandleFileTransferFrame`; agent echoes `approval_id` in completion frame and core re-checks; treat `RealPath` failure as policy violation; reject `..`/`.` segments + NUL/control bytes at the controller.

- **C-I. eBPF enhancements — kernel-version gate, cap precheck, output validation, in-band loss**
  Members: 3.4, 3.6, 3.L.1, 3.L.2.
  Body: bound `Argc`, sanitise `cString`, UTF-8 validate before storage + fuzz target; emit in-band loss events when drop rate crosses threshold; explicit `>= 5.8` kernel check with `ReasonKernelTooOld`; capabilities precheck with `ReasonCapabilityMissing`.

- **C-J. Web-NG per-action RBAC + post-attach reauth + CSRF lint**
  Members: 5.1, 5.2, 5.5, 5.6.
  Body: move settings LiveViews into `:require_authenticated_user_with_permit` and add `handle_event` perm checks; perm-revocation pubsub closes affected sockets; CI lint asserting every mutating remote-access route uses `:protect_from_forgery`; property-based test asserting all host-key/target-label renders are HTML-escaped.

- **C-K. SSH session metadata override behind RBAC + upstream allowlist**
  Members: 5.3.
  Body: `target_host` / `target_port` overrides require `remote-access.ssh.target.override` and per-tenant upstream allowlist; feature flag alone is insufficient.

- **C-L. Web-NG minor hardening**
  Members: 5.9, 5.10, 5.11.
  Body: prop allowlist in `RemoteAccessSSHConsole.js`; warn-log + metric on unknown stream-handler messages; derive browser stream timeout from session policy.

- **C-M. Palisade SSRF coverage**
  Members: 6.1, 6.2, 6.3, 6.4, 5.K.3.
  Body: detect IPv6-mapped IPv4 + recheck embedded v4; extend CIDR list with IPv4 multicast/CGNAT/reserved + IPv6 multicast; integration test for DNS-rebind defence; default port allowlist `[80, 443]`; add server-side ICE candidate filter mirroring these ranges in `webrtc_signaling_manager.ex`.

- **C-N. Gateway hygiene — expiry reaper + gRPC limits + backpressure**
  Members: 6.6, 6.K.4, 6.K.6.
  Body: GenServer reaper sweep for expired desktop-media sessions; `max_message_length` / `max_concurrent_streams` / keepalive on the gRPC server; per-stream credit-based backpressure on `StreamStatus`.

- **C-O. URGENT: scrub gRPC logger payloads**
  Members: 6.K.7.
  Body: replace `GRPC.Server.Interceptors.Logger` with a project-local interceptor that emits `{method, duration, status, actor}` only; INFO logs **must never** contain RPC bodies. Single-issue cluster, file FIRST — gates the safety of C-A.

- **C-P. Supply-chain CI gates — AGPL guardrail + cargo-audit + action pinning**
  Members: 6.9, 6.G.1, 6.G.2, 6.G.3, 6.G.4, 6.G.5, 6.G.6, 6.10, 6.11, 6.12, 6.8.
  Body: wire `check-teleport-license-paths.sh` into `source-security.yml`; add `cargo-audit --deny warnings` for `rdp-connector-probe` workspace; pin GitHub Action `uses:` to full SHAs; document cilium/ebpf + kr/fs maintenance status; pin Cargo additions with audit comment; SHA256-pin installer downloads; strip `client_secret` from Authentik fixture output; environment-protection rule on release.yml.

- **C-Q. Agent cert + provisioning — short TTL, revocation, partition-bound issuance**
  Members: 6.L.1, 6.L.2, 6.L.3, 6.N.1, 6.N.2, 6.N.3, 6.N.4, 6.N.5, 6.N.6, 6.N.7, 6.N.8, 6.N.9, 6.N.10.
  Body: cert TTL default 1-3 days with `--allow-long-ttl` opt-in + audit; in-memory revocation list (ETS) + admin `cert revoke` endpoint; `partition_matches()` policy on OnboardingPackage; rename `site` → `partition_id`; `authorize?: true` on download with token-bound actor; add `partition_id` to bootstrap token payload (`edgepkg-v3`); single-use `download_token_consumed_at`; per-actor / per-partition mint quota; audit row per cert mint; issuer-derived CN/SPIFFE refusing caller-supplied values on conflict; renewal revokes predecessor.

- **C-R. K8s deploy hygiene**
  Members: 6.P.1, 6.P.4, 6.P.5, 6.P.6, 6.P.7, 6.P.8, 6.P.9, 6.P.10, 6.P.11.
  Body: default-deny ingress + explicit edges; scope bootstrap Job RBAC with `resourceNames`; flip `readOnlyRootFilesystem: true` default + named `emptyDir`; pod helper sets `runAsUser` + `fsGroup`; NetPol gate for epmd:4369; default `PHX_CHECK_ORIGIN=true`; PDB for control-plane pods; refuse `:latest` in production install; inline comments on agent hostPath mounts.

- **C-S. K8s deploy critical — drop privileged + encrypt PVC**
  Members: 6.P.2, 6.P.3, 3.J.1 (rescoped to Postgres + datasvc PVC).
  Body: drop `privileged: true` on agent DaemonSet and rely on cap allowlist (verified per supported kernel); require encrypted `storageClassName` on datasvc PVC and CNPG storage; refuse install without explicit override.

- **C-T. Membrane / WebRTC server-side filtering + SDP hardening**
  Members: 5.K.1, 5.K.2, 5.K.4, 5.K.5, 5.K.6, 5.K.7, 5.E2.1, 5.E2.2, 5.E2.3, 5.E2.4, 5.E2.5, 5.E2.6.
  Body: server-side codec allowlist (`avc1`,`vp8`,`vp09`,`av01`); `a=fingerprint` algorithm allowlist (sha-256+); per-session ephemeral TURN creds (HMAC-time-bounded); DataChannel `max_message_size`/`max_channels`; SDP renegotiation gated by state machine; client-side codec allowlist + ICE filter; explicit `media-src 'none'` + Permissions-Policy denials; VideoFrame dimension check.

- **C-U. Recording-side rescoped audit (re-trigger when datasvc writer lands)**
  Members: 3.J.2, 3.J.3, 3.J.4, 3.J.5, 3.J.6, 3.J.7.
  Body: dormant until the datasvc recording writer is wired in; track as a *blocker* on that future change so the at-rest + per-actor + integrity story lands together.

- **C-V. Multi-tenant readiness backlog**
  Members: 4.1, 4.6.
  Body: when (if) ServiceRadar moves to multi-tenant, add `tenant_id` attribute strategy + indexes per CLAUDE.md; today's schema-prefix isolation is acceptable in single-tenant.

### 8.3 In-branch fix list (current PR `codex/remote-access-desktop-rdp`)

Ordered by priority. Items marked **BLOCKING** should land before this PR's merge.

1. **BLOCKING — 1.A2.1 [C]** CA-bundle parser strict-PEM only (no raw-bytes fallback). — RDP backend.
2. **BLOCKING — 1.1 [H] + 1.A2.2 [H]** Authenticated actor binding in `RdpBackend::open` *and* in `build_memory_user_credential`. — RDP backend.
3. **BLOCKING — 1.2 [H]** `SensitiveString::expose()` returns `Result`, fails session closed on invalid UTF-8. — RDP protocol.
4. **1.3 [M]** Custom serde deserialiser for `ca_bundle_pem` size cap. — RDP protocol.
5. **1.4 [M]** Closed as spec-delta: current length-prefixed stream has no frame magic; invalid next headers already fail closed. — RDP lib.
6. **1.5 [M]** Off-by-one fix to `>=` on pointer bounds. — RDP protocol.
7. **1.A2.4 [M]** `validate_desktop_media_frame` rejects NUL / control bytes / non-UTF-8. — `media_frame.rs`.
8. **1.A2.5 [M]** Assert `!tls_stream.conn.is_handshaking()` before consuming peer certs. — RDP backend.
9. **1.A2.6 [M]** `ServerName` LDH-validation + IP-literal rejection. — RDP backend.
10. **1.6 [L]** Move `harden_process_for_secrets()` invocation into helper `main` unconditionally. — RDP lib.
11. **1.7 [L]** Drop the `.trim()` in CA-bundle presence check. — RDP protocol.
12. **1.8 [L]** Per-session credit accumulation cap. — RDP protocol.
13. **1.A2.3 [M]** Wrap connector-probe test-helper passwords in `Zeroizing`. — connector-probe.
14. **1.A2.7 [L]** Per-stage Kerberos / KDC timeout + log which stage tripped. — RDP backend.
15. **1.A2.8 [L]** Re-validate `kerberos_config` across connector phases. — RDP backend.
16. **1.A2.9 [L]** Test-only comment on `bytes_contain_secret`. — RDP backend.

Other working-tree findings (5.E2.*, 5.K.*, 6.P.*, 6.L.*, 6.N.*, 6.G.*, 6.K.*, palisade) all live on this branch in *non-RDP* files. **Default triage = file in clusters C-Q, C-R, C-S, C-P, C-T, C-N, C-O, C-M** so they can ship as their own focused PRs against staging without expanding this RDP-feature branch beyond its mandate. If any are deemed branch-blocking, promote them out of FJ here.

### 8.4 Accept-with-note

Recorded for traceability; no code work scheduled. Reopen if conditions change.

- **3.J.2, 3.J.3, 3.J.4, 3.J.5, 3.J.6, 3.J.7** — dormant pending datasvc-writer activation (tracked via C-U). *Sign-off rationale:* Review O confirmed recording bytes live in Postgres today; reopening the moment the writer ships is acceptable risk because that change is itself a security-review trigger.
- **4.1, 4.6** — multi-tenant-readiness only; current deployment is single-tenant. *Sign-off rationale:* schema-prefix isolation suffices today; C-V tracks the migration item.
- **5.E2.5 [L]** VideoFrame dimension validation. *Sign-off rationale:* canvas `drawImage` clamps; impact is operator-visible inconsistency, not security. Will revisit if a per-target watermark / overlay feature lands.
- **5.10 [L]** Stream-handler unknown-message silent drop. *Sign-off rationale:* forward-compat behaviour is desirable; C-L adds the warn-log + metric so triage still has visibility.
- **6.G.3 [L]** cilium/ebpf maintenance documentation. *Sign-off rationale:* will be revisited at each release cut (per C-P).
- **6.G.5 [L]** kr/fs dormant transitive. *Sign-off rationale:* trivial shim; review when pkg/sftp bumps.
- **6.G.6 [L]** maxminddb-golang removal rationale. *Sign-off rationale:* housekeeping, non-security.
- **3.O.13 [L]** Redaction snapshot consistency. *Sign-off rationale:* documented intent; not a security gap — operators can re-export if policy changes.
- **3.O.4 [M]** Concurrent export idempotency. *Sign-off rationale:* small window, no security impact; if it becomes a UX issue add the export_id later (C-B doesn't depend on it).
- **3.O.9 [M]** Late-event fence at seal. *Sign-off rationale:* approximate byte counts already documented; bundle with C-B if signing the manifest+events together makes this trivial.
- **3.O.12 [M]** Authoritative `session_id` from `recording.session_id`. *Sign-off rationale:* defensive only — no known caller passes a foreign session_id; small refactor in C-B's transactional rewrite.
- **1.4 [M]** Frame trailing-byte detection. *Sign-off rationale:* current helper IPC is a length-prefixed stream, so extra bytes after one payload are indistinguishable from the next frame without adding a frame magic/version field. Invalid next headers already fail closed before payload allocation; stronger desync detection belongs in a future wire-format revision.

### 8.5 Rollup table

`B` = in-branch fix (this PR), `Fxx` = forgejo cluster id, `Acc` = accepted, `Spec` = §7 / spec delta, `Cls` = closed.

| ID | Sev | Triage | Cluster / Note |
|---|---|---|---|
| 1.1 | H | B | branch-blocking; pair with 1.A2.2 |
| 1.2 | H | B | branch-blocking |
| 1.3 | M | B | |
| 1.4 | M | Spec | length-prefixed stream; future frame magic/version needed |
| 1.5 | M | B | |
| 1.6 | L | B | |
| 1.7 | L | B | |
| 1.8 | L | B | |
| 1.A2.1 | C | B | **BLOCKING** |
| 1.A2.2 | H | B | branch-blocking; pair with 1.1 |
| 1.A2.3 | M | B | test-only but worth landing now |
| 1.A2.4 | M | B | |
| 1.A2.5 | M | B | |
| 1.A2.6 | M | B | |
| 1.A2.7 | L | B | |
| 1.A2.8 | L | B | |
| 1.A2.9 | L | B | |
| 2.1 | H | Fjo | C-G |
| 2.2 | M | Fjo | C-G |
| 2.3 | L | Fjo | C-G |
| 2.4 | M | Fjo | C-G |
| 2.5 | L | Fjo | C-G |
| 2.6 | L | Fjo | C-G |
| 2.7 | L | Fjo | C-G |
| 3.1 | H | Fjo | C-H |
| 3.2 | H | Fjo | C-B |
| 3.3 | M | Fjo | C-C (events read policy) |
| 3.4 | M | Fjo | C-I |
| 3.5 | M | Fjo | C-H |
| 3.6 | L | Fjo | C-I |
| 3.7 | L | Fjo | C-H |
| 3.H.1 | H | Fjo | C-A |
| 3.H.2 | M | Fjo | C-C |
| 3.H.3 | M | Fjo | C-A |
| 3.H.4 | L | Fjo | C-B |
| 3.H.5 | L | Fjo | C-A (retention/cascade) |
| 3.H.6 | L | Fjo | C-D |
| 3.H.7 | L | Cls | timing-safe confirmed; regression test in C-B |
| 3.J.1 | H | Fjo | C-S (re-targeted to Postgres + datasvc PVC) |
| 3.J.2 | M | Acc | C-U dormant |
| 3.J.3 | H | Acc | C-U dormant |
| 3.J.4 | H | Acc | C-U dormant |
| 3.J.5 | M | Acc | C-U dormant |
| 3.J.6 | L | Acc | C-U dormant |
| 3.J.7 | L | Acc | C-U dormant |
| 3.L.1 | M | Fjo | C-I |
| 3.L.2 | L | Fjo | C-I |
| 3.O.1 | H | Fjo | C-B |
| 3.O.2 | H | Fjo | C-C |
| 3.O.3 | H | Fjo | C-B |
| 3.O.4 | M | Acc | concurrent-export consistency |
| 3.O.5 | M | B | orphan reaper |
| 3.O.6 | H | Fjo | C-B |
| 3.O.7 | H | Fjo | C-B |
| 3.O.8 | M | Fjo | C-B |
| 3.O.9 | M | Acc | bundle with C-B if cheap |
| 3.O.10 | M | Cls | current endpoint is one-shot JSON, not a stream |
| 3.O.11 | M | B | deleted terminal state |
| 3.O.12 | M | Acc | defensive only |
| 3.O.13 | L | Acc | documented intent |
| 3.O.14 | M | Fjo | C-C |
| 4.1 | M | Acc | C-V multi-tenant readiness |
| 4.2 | C | Fjo | C-F |
| 4.3 | H | Fjo | C-E |
| 4.4 | H | Fjo | C-D |
| 4.5 | H | Fjo | C-D (add `:rejected` state + audit) |
| 4.6 | L | Acc | C-V |
| 4.7 | M | Fjo | C-E |
| 4.8 | M | Fjo | C-A |
| 4.9 | M | Fjo | C-C (redaction allowlist→denylist) |
| 4.10 | L | Fjo | C-D (warn on unknown frame) |
| 5.1 | C | Fjo | C-J |
| 5.2 | H | Fjo | C-J |
| 5.3 | H | Fjo | C-K |
| 5.4 | H | Fjo | C-C |
| 5.5 | H | Fjo | C-J |
| 5.6 | M | Fjo | C-J |
| 5.7 | M | Fjo | C-H |
| 5.8 | M | Fjo | C-C |
| 5.9 | L | Fjo | C-L |
| 5.10 | L | Acc | C-L tracks warn-log |
| 5.11 | L | Fjo | C-L |
| 5.E2.1 | L | Fjo | C-T |
| 5.E2.2 | L | Fjo | C-T |
| 5.E2.3 | M | Fjo | C-T |
| 5.E2.4 | L | Fjo | C-T |
| 5.E2.5 | L | Acc | canvas-safe |
| 5.E2.6 | L | Fjo | C-T |
| 5.K.1 | H | Fjo | C-T |
| 5.K.2 | M | Fjo | C-T |
| 5.K.3 | H | Fjo | C-M (also lives in C-T) |
| 5.K.4 | L | Fjo | C-T |
| 5.K.5 | H | Fjo | C-T |
| 5.K.6 | M | Fjo | C-T |
| 5.K.7 | M | Fjo | C-T |
| 6.1 | C | Fjo | C-M |
| 6.2 | H | Fjo | C-M |
| 6.3 | H | Fjo | C-M |
| 6.4 | M | Fjo | C-M |
| 6.5 | C | Fjo | C-D |
| 6.6 | M | Fjo | C-N |
| 6.7 | M | Fjo | C-D |
| 6.8 | L | Fjo | C-P |
| 6.9 | H | Fjo | C-P |
| 6.10 | L | Fjo | C-P |
| 6.11 | M | Fjo | C-P |
| 6.12 | L | B | release source gate; environment reviewer gate is Forgejo config |
| 6.G.1 | M | Fjo | C-P (≡ 6.9) |
| 6.G.2 | M | Fjo | C-P |
| 6.G.3 | L | Acc | revisit per release |
| 6.G.4 | L | Fjo | C-P |
| 6.G.5 | L | Acc | revisit on pkg/sftp bump |
| 6.G.6 | L | Acc | housekeeping |
| 6.K.4 | H | Fjo | C-N |
| 6.K.6 | M | Fjo | C-N |
| 6.K.7 | H | Fjo | **C-O (file FIRST)** |
| 6.L.1 | H | Fjo | C-Q |
| 6.L.2 | H | Fjo | C-Q |
| 6.L.3 | M | Fjo | C-Q |
| 6.N.1 | H | Fjo | C-Q (C-class in any multi-tenant deployment) |
| 6.N.2 | H | Fjo | C-Q |
| 6.N.3 | H | Fjo | C-Q |
| 6.N.4 | M | Fjo | C-Q |
| 6.N.5 | M | Fjo | C-Q |
| 6.N.6 | M | Fjo | C-Q |
| 6.N.7 | M | Fjo | C-Q |
| 6.N.8 | H | Fjo | C-Q |
| 6.N.9 | M | Fjo | C-Q |
| 6.N.10 | L | Fjo | C-Q |
| 6.P.1 | H | Fjo | C-R |
| 6.P.2 | H | Fjo | C-S |
| 6.P.3 | H | Fjo | C-S |
| 6.P.4 | M | Fjo | C-R |
| 6.P.5 | M | Fjo | C-R |
| 6.P.6 | M | Fjo | C-R |
| 6.P.7 | M | Fjo | C-R |
| 6.P.8 | M | Fjo | C-R |
| 6.P.9 | L | Fjo | C-R |
| 6.P.10 | L | Fjo | C-R |
| 6.P.11 | L | Fjo | C-R |

### 8.6 Triage counts

| Bucket | Count |
|---|---:|
| In-branch fix (this PR) | 16 |
| Forgejo issues (clustered into 22 issues C-A … C-V) | ~95 |
| Accept with note | 14 |
| Closed | 1 (3.H.7) |

**Critical / High needing forgejo (front of queue):** 6.K.7 (C-O — file *first*), 1.A2.1 (in-branch, branch-blocking), 4.2 (C-F), 5.1 (C-J), 6.1 (C-M), 6.5 (C-D), 6.P.2/.3 (C-S), 3.J.1 (C-S), 6.N.1 (C-Q).
