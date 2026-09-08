## Context

Two things are already true and constrain this change:

1. **#3444 shipped Bumblebee's runtime.** The scanner (`go/cmd/bumblebee-scan`,
   `go/pkg/bumblebee/*`), the root-owned systemd unit/timer
   (`build/packaging/bumblebee-scan/`), the sanitized spool contract, the non-root agent
   ingest (`go/pkg/agent/bumblebee_spool_service.go`), and the full control-plane catalog
   / posture / risk pipeline are implemented. Its `agent-configuration` spec already says
   the scanner is "an optional native capability bundle enabled through Edge Ops
   feature-set deployment" — but the actual install mechanism is a standalone deb.

2. **#3425 shipped the framework + control plane.** `AddonPackage`/`AddonAssignment`/
   `AddonStatus` and `AgentConfigGenerator` add-on compilation are merged and
   DB-validated (39 integration tests green), including `pushed-artifact` per-arch
   artifact references. `delivery-models` defines the generic `systemd-timer` supervision
   ("the agent SHALL ingest the add-on's spooled output"), pushed-artifact
   activation/rollback, and capability application via the root-owned `agent-updater`.

This change is the **seam** between the two: make Bumblebee a concrete consumer of the
framework's `systemd-timer` / `pushed-artifact` path, and stop installing it as a
bespoke package.

## Goals / Non-Goals

- **Goals:** one signed, versioned Bumblebee artifact; Edge-Ops-driven enable/target/drift
  after the initial agent install; the agent stays non-root; the spool contract and all
  #3444 behavior are preserved byte-for-byte.
- **Non-Goals:** an agent-launched (go-plugin) Bumblebee; changing scan scope/catalog/risk;
  macOS packaging (Linux systemd-timer only, as in #3444); a new findings RPC (the spool
  stays the data channel).

## Decisions

- **Decision: `systemd-timer` supervision, not `agent-sidecar` (go-plugin).** Bumblebee
  needs broad root reads; the agent is non-root with no sudo and launches add-ons as
  itself. A go-plugin Bumblebee could only get there via `CAP_DAC_READ_SEARCH` (read-any-
  file ≈ root-for-reads, no real safety win) and would still need the root-owned updater
  to apply it. The root-owned systemd timer is the honest privilege boundary and is
  already proven (#3444). *Alternative considered:* agent-sidecar go-plugin — rejected on
  the privilege grounds above.

- **Decision: `pushed-artifact` is the primary delivery model; `os-package` is an
  air-gapped fallback.** The live agent already runs the signed-release pipeline
  (root-owned `agent-updater`, Ed25519 release key, versioned `current`-symlink + release
  manifests). `pushed-artifact` reuses that exact shape with no per-update apt/dnf
  transaction. *Alternative considered:* `os-package` as primary — rejected because it
  requires a host package transaction and repo config per update; kept as a fallback for
  hosts that cannot fetch artifacts.

- **Decision: the spool/`state_dir` remains the data channel.** The `AddonAssignment`
  governs enable/disable/config and the timer cadence; the sanitized spool the
  root scanner writes is ingested by the existing `BumblebeeSpoolService`. This reuses a
  tested, crash-durable pipeline and matches delivery-models' "systemd-timer add-on
  spools for ingest." *Alternative considered:* a v2 findings RPC — deferred; unnecessary
  for a timer-cadenced scanner and would discard the working ingest path.

- **Decision: privileged install is performed by the root-owned `agent-updater`, invoked
  by the privileged orchestrator, never by the agent.** Installing/enabling the systemd
  timer + service and setting spool-dir perms are root operations; the agent
  (non-root, no sudo) requests them via the assignment, and the updater applies them. The
  add-on process never sets its own capabilities.

## Risks / Trade-offs

- **Two active changes touch `agent-configuration` (#3444 not yet archived).** → This
  change ADDS a framework-delivery requirement and documents that it supersedes #3444's
  ad-hoc-deb delivery scenario; reconcile the `specs/` merge when both archive.
- **e2e requires an agent build that contains the #3425 add-on manager.** The live
  `dusk01` agent (v1.2.83) predates it. → e2e must target a scratch/test agent rolled
  from a current build via the signed-release pipeline, not the production agent.
- **Signature gate.** The Bumblebee artifact must be signed with the key matching the
  agent's `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`; a mis-signed bundle is rejected (good)
  but a key mismatch would block delivery. → verify-before-release gate (build-signing).
- **Rollback of a privileged add-on.** A bad Bumblebee version must roll back to the prior
  `current` version AND leave the timer in a consistent state. → reuse delivery-models'
  versioned-symlink rollback; on activation failure, keep the previous version current and
  do not enable a half-installed timer.

## Migration Plan

1. Land `addons/bumblebee/addon.yaml` + bundle; keep the #3444 deb buildable but no longer
   the install path.
2. Seed/import a Bumblebee `AddonPackage` (staged → approved) so Edge Ops can target it.
3. Gate `BumblebeeSpoolService` on the assignment; fall back to the local-override/cache
   path (#3444) when the control plane is unreachable.
4. Roll a current agent build (with the add-on manager) to a **scratch test agent**;
   enable the Bumblebee add-on via Edge Ops; confirm timer install, root scan, spool
   ingest, findings + status/drift reporting, and rollback.
5. Deprecate the standalone `build/packaging/bumblebee-scan` deb install in release notes.

**Rollback:** disable the assignment (timer disabled, agent stops ingesting) or roll the
add-on back to the prior `current` version; the standalone deb path remains available as a
break-glass until the deprecation completes.

## Open Questions

- Default delivery for shipped fleets: `pushed-artifact` everywhere, or `os-package` for
  specific air-gapped cohorts?
- Does Bumblebee need any file capability beyond running as root via systemd, or is the
  systemd `User=root` context sufficient (it is today in #3444)?
