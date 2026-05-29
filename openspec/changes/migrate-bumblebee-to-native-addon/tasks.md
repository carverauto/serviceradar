## 1. Add-on manifest & bundle

- [ ] 1.1 Author `addons/bumblebee/addon.yaml` (kind: capability; delivery: pushed-artifact; supervision: systemd-timer; capability id for exposure scanning; `requires` root-context execution; `state_dirs` for the spool) and `addons/bumblebee/config.schema.json` mirroring the existing `bumblebee-scan.json` config surface
- [ ] 1.2 Validate `addons/bumblebee/addon.yaml` against the manifest JSON-Schema + validator from `add-native-addon-build-signing`
- [ ] 1.3 Wire a `bumblebee` bundle into `build/native_addons/addon_inventory.bzl` (scanner binary + systemd service + timer + scanner config) producing per-arch signed bundles
- [ ] 1.4 Retire `build/packaging/bumblebee-scan` as the install/enable mechanism (keep the binary build target; the units now ship in the add-on bundle); confirm the base `serviceradar-agent` package still installs no scanner

## 2. Agent delivery & supervision (consumes delivery-models)

- [ ] 2.1 Activate the signed Bumblebee artifact via the root-owned `agent-updater`: stage under the versioned `current`-symlink layout, verify sha256 + signature, then install/enable the systemd service + timer and set spool-dir permissions (privileged steps never run by the agent)
- [ ] 2.2 Gate `BumblebeeSpoolService` ingest on the `AddonAssignment` (enabled/disabled + approved-capability subset) instead of the standalone `bumblebee_config` delivery path; preserve the local-override/cache fallback when the control plane is unreachable
- [ ] 2.3 Report per-add-on state (installed/active/degraded + version/arch + last scan) for Bumblebee through the merged `AddonStatus` read model so Edge Ops drift reflects it
- [ ] 2.4 On activation/launch failure, roll back to the prior `current` version and do NOT leave a half-installed/enabled timer

## 3. Control plane & Edge Ops (reuses merged work)

- [ ] 3.1 Seed/import a Bumblebee `AddonPackage` (staged → approved with the exposure-scan capability) so it is selectable/targetable in Edge Ops
- [ ] 3.2 Confirm `AgentConfigGenerator` compiles the Bumblebee assignment (delivery=pushed-artifact, supervision=systemd-timer, per-arch artifact reference, schema-validated params) into agent config
- [ ] 3.3 Confirm Bumblebee appears as a selectable feature-set in onboarding + per-cohort targeting + the assigned/installed/active drift card (no new UI beyond `add-native-addon-edge-ops`)

## 4. Verification

- [ ] 4.1 Go unit tests: assignment-gated ingest enable/disable; rollback on bad-signature activation; spool ingest unchanged
- [ ] 4.2 Elixir DB-backed tests (srql-fixtures scratch DB): Bumblebee `AddonPackage`/`AddonAssignment` compile + status ingest + drift
- [ ] 4.3 e2e on a **scratch** agent rolled from a current build (NOT the live dusk01 agent): enable via Edge Ops → timer installed → root scan → spool ingested → findings + status reported → disable stops the timer → rollback restores prior version
- [ ] 4.4 `openspec validate migrate-bumblebee-to-native-addon --strict`
