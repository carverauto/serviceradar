# Change: Fix sysmon bare-metal mTLS defaults and edge onboarding

## Why
- Sysmon RPM/Deb packages currently seed and ship a SPIFFE/SPIRE default config (`cmd/checkers/sysmon/config/default_template.json`, `packaging/sysmon/config/checkers/sysmon.json.example`). Bare-metal installs should default to mTLS so sysmon starts without SPIRE infrastructure.
- Sysmon edge onboarding is failing in some bare-metal environments with `502 {"message":"failed to deliver edge package"}`, blocking zero-touch installs.
- Existing edge-onboarding changes added mTLS bundles and sysmon bootstrap support, but sysmon bare-metal defaults and sysmon-specific onboarding hardening remain inconsistent.

## What Changes
- Update sysmon’s embedded default template and RPM/Deb example config to mTLS mode with correct bare‑metal cert defaults.
- Ensure sysmon checker edge onboarding packages default to mTLS on bare metal, and that downloaded bundles install config/certs to standard Linux paths non‑interactively.
- Harden Core’s sysmon edge package flow:
  - Make delivery errors actionable (log root causes, map common failures to clear HTTP errors).
  - Validate sysmon checker templates and security modes so packages can’t be issued in a state that will later 502.
- Validate end-to-end on bare metal:
  - Issue sysmon mTLS edge package, bootstrap with token, verify config/certs persisted, restart succeeds, poller can query sysmon.

## Impact
- Affected specs: `sysmon-checker`, `edge-onboarding`.
- Affected code (expected):
  - `cmd/checkers/sysmon/config/default_template.json`
  - `packaging/sysmon/config/checkers/sysmon.json.example`
  - `pkg/core/edge_onboarding.go`, `pkg/core/api/edge_onboarding.go`
  - KV seeding/templates for sysmon checkers (`templates/checkers/mtls/sysmon.json`)
  - sysmon RPM/Deb systemd/service install paths and docs.
- Breaking/behavioral notes:
  - Fresh bare‑metal installs without an explicit config will now come up in mTLS mode; SPIFFE users must provide a SPIFFE config or KV override.

