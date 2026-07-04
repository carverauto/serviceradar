# Design — refactor-addon-lifecycle-operability

## Context

Verified incidents motivating this change (demo fleet, 2026-07-04):

- **Netprobe/flow-attribution outage (active since 2026-07-01 00:44):** a
  corrupt `AddonAssignment.params` row stores `capture_interfaces` as a scalar
  string; the delivery path emits it verbatim
  (`agent_config_generator.ex:1642` — `config_json:
  encode_json(normalize_map(params))`, where `normalize_map` is a passthrough
  and the existing coercion helper `ConfigSchema.normalize_params` /
  `split_list` (`config_schema.ex:357-366`) is never called on delivery); the
  Go decoder (`go/pkg/agent/netprobe/config.go:49`, `[]string`) fails
  permanently; the deployed agent then logs `Skipped control stream config ack
  because config apply failed` on every cycle. The netprobe process runs, but
  only with the minimal bootstrap sidecar config
  (`/etc/serviceradar/sidecars/netprobe.json` — enabled flag + IPC batching,
  no capture/binding config), so no attribution is produced:
  `platform.flow_process_attribution_current` = 0 rows against 236M lifetime
  inserts. Author-time validation (`AddonAssignmentParams` via strict
  ExJsonSchema) would have rejected the string — the row entered via a write
  path that bypassed it. Note the *visibility-profile proto* path is clean
  (compiler always emits a list; proto field is `repeated string`) — the bug
  is specific to the add-on `config_json` delivery path.
- **Bumblebee wedge (weeks, prior):** `open /var/lib/serviceradar/bumblebee/
  tmp/.bumblebee-catalog-*: permission denied` → `Deferring config version
  update because Bumblebee config did not apply`, logged every minute for
  weeks. Same architecture flaw, different section.
- **Partial in-tree remediation, unspecified:** staging HEAD already carries a
  permanent/transient disposition split (post fj#4301,
  `push_loop_config.go:162-169, 305-327`): permanent failures no longer defer
  the version commit. Remaining gaps this change owns: (a) the model exists in
  Go comments only — no spec; (b) transient failures in the add-on-assignment
  and visibility sections early-return and skip all later sections that cycle
  (`push_loop_config.go:195-201, 225-231`); (c) permanent failures are
  log-only (`logConfigSectionFailure`, :321-327) — they synthesize no
  `AddonStatus` (unlike artifact-delivery failures via
  `addonDeliveryFailureStatuses`, `addon_delivery.go:279-319`), so a
  config-broken netprobe reads as healthy/running in the fleet view; (d) core
  discards acks — the gateway logs `config_ack` at debug
  (`control_stream_session.ex:226-228`), persists nothing, and detects no ack
  drift; (e) one unconditional ack-blocker remains even post-split — a
  supervisor `manager.Apply` error in `applyAddonAssignments`
  (`push_loop_addons.go:370-373`).
- Both incidents were invisible from core: no ack-gap detection, no health
  event, no UI surface. Diagnosis required ssh + journalctl on the host.
- **Fleet UI evidence** (screenshots attached to the change record): drift
  badges rendering bare or zero versions (`drift: 0.0.0`, `drift: 0.1.20`),
  clipped ATTENTION badges, horizontal scroll, `— (catalog only)` rows inside
  the fleet table, per-version row explosion, truncated error strings in the
  RUNNING STATE column, and an always-present, feedback-free "Import all"
  button on the catalog page.

## Goals / Non-Goals

- Goals:
  - A failing add-on config section can never block other sections or config
    version acknowledgement.
  - Core knows, and shows, when an agent is config-wedged — within minutes,
    in the UI, without host access.
  - Core cannot publish add-on config that the agent-side decoder rejects;
    representational drift is caught in CI, tolerated at runtime.
  - An operator can answer at a glance: what runs where, at which version,
    is it healthy, am I on latest, did my import work.
- Non-Goals:
  - Add-on artifact distribution/signing/rollout mechanics
    (`agent-release-management`, `add-native-addon-delivery-models`,
    `add-addon-profile-targeting` own these; the gateway-only delivery
    boundary is preserved).
  - The `native-addon-delivery` capability deltas being landed by
    `fix-staging-observability-addon-regressions` (fleet inventory reporting,
    systemd self-heal, per-agent enablement). This change consumes that
    reporting data in the UI; it does not respecify it.
  - SRQL targeting semantics (`add-addon-profile-targeting`).

## Decisions

- **Decision: per-section apply/ack, protocol-compatible.** The ack message
  gains an optional per-section status list; core treats an ack without
  section statuses as a legacy whole-version ack. Alternative — a whole-version
  "best effort ack" flag — rejected: it hides which section failed and cannot
  drive targeted health surfacing.
- **Decision: permanent failures become state, not log spam.** The agent
  persists (config_version, section, error, since) and re-evaluates only when
  the section payload hash changes. Today's behavior (retry + warn every
  cycle, marked `permanent:true` yet retried forever) is contradictory.
- **Decision: schema validation + coercion belongs at the delivery path, not
  only author time.** The author-time guard (`AddonAssignmentParams`) already
  exists and was bypassed by non-interactive write paths; the delivery path
  (`to_proto_addons`) is the single choke point every param traverses, so wire
  `ConfigSchema.normalize_params` coercion + validation there, enforce the
  guard on all write paths, and refuse delivery for uncoercible params with a
  visible per-assignment error. Agent-side decoders additionally coerce
  documented compatibility forms (scalar→list) so drift that still slips
  through degrades gracefully. Alternative — strict both sides with no
  coercion — re-creates exactly this outage class on every schema evolution.
- **Decision: contract tests use the real Go decoders.** Golden-output tests
  of the Elixir side alone cannot catch type-shape drift; CI decodes
  core-emitted `config_json` fixtures with the actual agent/add-on structs
  (small Go test binary consuming fixtures generated by the Elixir suite).
- **Decision: spec the disposition model that already exists in code, then
  close its gaps.** The permanent/transient split is currently documented only
  in Go comments; specifying it (plus per-section ack status, no
  transient early-return skipping, escalation, ack persistence) prevents the
  next refactor from silently regressing to the pre-#4301 wedge.
- **Decision: fleet table models (agent × add-on), not
  (agent × add-on × version).** The version dimension moves into the add-on
  detail page. This is what collapses the row explosion, kills the
  `— (catalog only)` hybrid rows (catalog inventory gets its own surface), and
  makes "on latest" a first-class state.
- **Decision: drift is a rendered comparison, computed only when both sides
  exist.** `drift: 0.0.0` came from formatting a comparison against an absent
  version; the read model must carry `assigned_version` and
  `running_version` as nullable and the renderer must handle all four
  presence combinations explicitly (up-to-date / drift / unassigned-running /
  assigned-not-reported).

## Risks / Trade-offs

- Per-section acks change agent↔core protocol → mitigated by
  optional-field compatibility both directions; mixed-fleet test in tasks 8.2.
- Agent-side coercion could mask genuine authoring errors → mitigated by
  compatibility notices in the ack status and publish-time validation
  catching them first.
- Fleet read-model rework touches the reporting pipeline being landed by
  `fix-staging-observability-addon-regressions` → sequence UI overhaul after
  its PR8 fleet-reporting lands; UI consumes, not redefines, that data.

## Migration Plan

1. Tier 1 (hotfix): corrupt-row remediation + delivery-path coercion +
   tolerant netprobe decoder → restores flow attribution on demo.
2. Tier 2: sectioned apply/ack (agent), ack persistence + wedge detection
   (core), UI surfacing. Protocol-compat gated; mixed-version verified.
3. Tier 3: schema contract enforcement + CI suite.
4. Tier 4: fleet/catalog UI overhaul (after fleet-reporting PRs from
   `fix-staging-observability-addon-regressions` land).
Rollback: each tier independently revertible; tier 2 protocol fields are
optional so old agents remain functional throughout.

## Open Questions

- Add-on build/versioning hygiene is unaudited: what increments versions, why
  adjacent versions (0.1.19/0.1.20) linger as peer assignments, whether
  `staged → approved` verification is actually wired, and whether sample
  add-ons belong in production catalogs. Needs a dedicated audit (tracked as a
  follow-up issue); its outcome sets the version-retention policy the fleet UI
  assumes.

- Where should add-on config schemas canonically live — package manifest
  (travels with the artifact) vs core repo (versioned with compilers)?
  Leaning manifest, since add-ons version independently of core.
- Does the existing `resource limits not enforced: create addon …` runtime
  warning belong in RUNNING STATE at all, or in a per-add-on diagnostics
  drawer? (UI overhaul should decide a single home for runtime diagnostics.)
