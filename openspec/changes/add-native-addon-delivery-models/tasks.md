# Tasks: Native add-on delivery & supervision models

> Implements the agent-side delivery/supervision models beyond agent-sidecar from
> `add-agent-feature-sets`. Task numbers in parentheses map back to that change.

## 1. Packaging boundary
- [ ] 1.1 Carve the base `serviceradar-agent` package to the core agent only (no
  optional capability binaries baked in via alternate targets). (3425 §3.1)
- [ ] 1.2 Define the signed `pushed-artifact` tarball format and the optional
  `os-package` add-on template (depends on `serviceradar-agent`, dormant on
  install). (§3.2)

## 2. Delivery dispatch
- [ ] 2.1 Agent add-on manager dispatches an assignment to its delivery model:
  `config-toggle` / `pushed-artifact` fetch+verify+activate / `os-package`
  activate. (§6.1)
- [ ] 2.2 `pushed-artifact` activation: reuse `release_runtime.go` staged-dir +
  `current`-symlink + rollback; verify `sha256` + signature; apply file capabilities
  per `requires.os_capabilities` via the root-owned `agent-updater`. (§6.5)

## 3. Supervision models
- [ ] 3.1 Wire `systemd-service` and `systemd-timer` (spool ingest). (§6.6)
- [ ] 3.2 Wire `ephemeral-helper` and `config-toggle`. (§6.6)

## 4. Resilience
- [ ] 4.1 Last-known-good cache + local override for add-on assignments (mirror the
  existing config override/cache pattern); fall back to last good on delivery or
  verification failure. (§6.7)

## 5. Validation
- [ ] 5.1 `openspec validate add-native-addon-delivery-models --strict` passes.
- [ ] 5.2 Tests: activation rollback on bad signature; timer spool ingest; config-toggle
  enable/disable; cache fallback on fetch failure.
