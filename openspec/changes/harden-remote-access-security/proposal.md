# Change: Harden remote-access surface from end-to-end security review

## Why
ServiceRadar's agent-routed remote-access plane has grown rapidly across several proposals — SSH, SSH CA, file transfer, recording, eBPF enhanced telemetry, broker, desktop/RDP, central credential grants — porting Teleport-like bastion behaviour into ServiceRadar. Most of this work landed in `codex/teleport-agent-routed-remote-access` (#3275, in staging) and `codex/remote-access-desktop-rdp` (current branch, ~623 commits / ~617 changed files vs staging). Because ServiceRadar agents now act as a *trusted bastion* sitting between human operators, IdPs, and customer infrastructure, the threat model is larger than any single sub-proposal anticipated: cross-tenant escape, credential exfiltration, recording bypass, malformed-protocol DoS, MITM, transitive AGPL/license risk, and RBAC bypass are all in scope.

This change records a deep-dive security review of the remote-access surface (branch + relevant staging code) and tracks remediation as discrete, prioritised tasks **in this proposal** — every finding lives here so the audit isn't fragmented across multiple trackers. Remediation that targets staging-rooted code ships as its own follow-up PR but is checked off against this proposal. This change does not modify code on its own.

## What Changes
- Document a single source of truth for the remote-access security baseline (threat-model summary, severity rubric, scope) at `design.md`.
- Enumerate all findings in `tasks.md`, grouped by capability slice, each linked back to file:line and triaged in §8 to either an in-branch fix on this PR or a named remediation cluster (`C-A`…`C-V`) shipping as its own staging PR.
- Add normative security requirements to `edge-architecture` covering: protocol adapter threat-model & dependency-review gate, credential-custody / zeroisation guarantees, tenant isolation invariants for broker/session/recording resources, recording-tamper-evidence floor, redirection-default-off contract for desktop adapters, and outbound-network policy obligations (Palisade) for any user-driven egress.
- Reserve separate OpenSpec changes only when a cluster grows beyond a single PR's worth of scope; otherwise everything stays in this proposal and clusters check off as their PRs merge.

## Impact
- Affected specs: `edge-architecture`
- Affected code (review surface, not necessarily modified):
  - Rust: `rust/rdp-adapter/`, `rust/rdp-connector-probe/`
  - Go: `go/pkg/agent/remoteaccess/{ssh,file_transfer,enhanced_recording}*`, `go/pkg/agent/desktop_rdp_helper_*`, `go/pkg/agent/remote_file_transfer*`, `go/pkg/agent/proxmox_console_ssh*`, `go/cmd/tools/sshca-signer/`
  - Elixir core: `elixir/serviceradar_core/lib/serviceradar/edge/remote_access_*`, `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/remote_desktop/*`, related migrations and policies
  - Elixir gateway: `elixir/serviceradar_agent_gateway/lib/.../{desktop_media_*,control_stream_session,desktop_media_session_tracker}`, palisade outbound network policy
  - Web-ng: `elixir/web-ng/lib/.../controllers/api/remote_access_*`, `channels/remote_access_stream_handler`, `live/remote_access_live/*`, settings LiveViews, JS hooks `RemoteAccessSSHConsole*`
  - Build / CI / scripts: `MODULE.bazel`, `Cargo.{toml,lock}`, `.forgejo/workflows/palisade-publish.yml`, `scripts/remote-access-*`, `scripts/check-teleport-license-paths.sh`
- All findings tracked in this proposal; no parallel forgejo filings.
