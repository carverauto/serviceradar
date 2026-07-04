# Change: Make add-on config delivery resilient and the add-on lifecycle legible to operators

## Why

The add-on subsystem fails silently and its operator surface is illegible. Two
live production regressions on the demo fleet were caused or prolonged by it,
and the Settings UI actively hides fleet state behind noise:

1. **Config-apply failures wedge silently and invisibly.** Since 2026-07-01
   00:44 the agent on sr-test-pve04 logs `parse netprobe add-on config: json:
   cannot unmarshal string into Go struct field addonConfig.capture_interfaces
   of type []string` (marked `permanent:true`) and therefore `Skipped control
   stream config ack because config apply failed` — the deployed agent has not
   acked a config version in three days. Netprobe runs on a minimal bootstrap
   sidecar config, so **flow attribution stopped fleet-wide**
   (`platform.flow_process_attribution_current`: 0 rows, 236M lifetime
   inserts). Before that, the *same pattern* ran for weeks with a different
   section: `Deferring config version update because Bumblebee config did not
   apply` (catalog staging `permission denied`). Staging HEAD has since gained
   a permanent/transient disposition split (post fj#4301,
   `go/pkg/agent/push_loop_config.go:162-169`) so a *permanent* failure no
   longer blocks the version commit once that code ships — but the model is
   specified in no spec, a *transient* failure in the add-on-assignment or
   visibility sections still early-returns and skips every later section for
   that cycle (`push_loop_config.go:195-201,225-231`), permanent failures are
   log-only (`logConfigSectionFailure`, `push_loop_config.go:321` — no add-on
   status, no health event), and core-side the gateway logs `config_ack` at
   debug and persists nothing (`control_stream_session.ex:226-228`) — there is
   no "agent stuck at version X since <date>" anywhere.
2. **Type contracts between core and agent are unenforced on the delivery
   path.** The netprobe outage's string came from a corrupt
   `AddonAssignment.params` row (`capture_interfaces` stored as a scalar
   string) delivered verbatim: `agent_config_generator.ex:1642` emits
   `config_json: encode_json(normalize_map(params))` where `normalize_map` is
   a passthrough; the existing schema-coercion helper
   (`ConfigSchema.normalize_params`, `config_schema.ex:357-366`, which would
   split a string into a list) is never invoked on the delivery path; and the
   author-time validation (`AddonAssignmentParams` against the package
   `config_schema`) does not cover rows persisted before the guards existed
   and skips entirely for packages with an empty `config_schema`. The Go
   decoder (`go/pkg/agent/netprobe/config.go:49`, `[]string`) then fails
   permanently. Nothing in CI decodes core-emitted `config_json` with the real
   agent decoders. (`fix-staging-observability-addon-regressions` PR6.3 fixes
   the one corrupt row — a data remediation, not a contract.)
3. **Delivery semantics are illegible.** Operators cannot answer: is delivery
   automatic or manual? did my import do anything? which add-ons run where?
   am I on the latest version? Live UI evidence:
   - The catalog **Import all** button renders regardless of import state and
     gives zero feedback when clicked (no progress, no result, no idempotence
     signal).
   - The fleet table requires **horizontal scrolling** to see its columns;
     ATTENTION badges truncate into unreadable clipped text ("version drift",
     "assigned, not running" cut mid-word).
   - Drift labels are meaningless: `drift: 0.0.0` (running-vs-assigned
     comparison against a zero/absent version) and `drift: 0.1.20` (which is a
     *version string*, not a drift description).
   - Rows appear with no agent name as `— (catalog only)`, mixing
     catalog-inventory rows into a fleet-status table.
   - The table enumerates every (agent × add-on × version) row — pages of
     stale versions (`0.1.19` next to `0.1.20`) with `not reported` /
     `disabled` states drowning the few rows that matter.
   - Truncated error text (`resource limits not enforced: create addon ...`)
     is jammed into the RUNNING STATE column with no way to read the rest.

## What Changes

- **Specify and complete the sectioned config-apply model**: elevate the
  existing (unspecified) permanent/transient disposition split into a spec'd
  invariant, and close its gaps — a transient failure in one section MUST NOT
  skip applying the remaining sections in the same cycle; the config ack
  gains structured per-section status; permanent failures escalate once with
  persistent state instead of per-cycle log spam.
- **Core-side wedge detection**: core persists per-agent config version acks
  and per-section apply status (today: gateway debug-log only); an agent that
  stops acking or reports a permanently failing section becomes visibly
  unhealthy (agent detail + fleet views + health event), with the failing
  section and error surfaced verbatim. Config-apply failures for an add-on
  synthesize an unhealthy add-on status the same way artifact-delivery
  failures already do (`addonDeliveryFailureStatuses`).
- **Typed add-on config contracts on the delivery path**: `AddonAssignment`
  params are validated AND schema-coerced against the package `config_schema`
  at delivery time (wire `ConfigSchema.normalize_params` into
  `to_proto_addons`), enforced at every write path (manual, profile
  reconciler, seeder), with uncoercible params refusing delivery of that
  section visibly at the assignment — never shipping JSON the agent decoder is
  known to reject. Agent-side parsers accept documented compatibility forms
  (string→[]string for singletons) as defense in depth. CI contract tests
  decode representative core-emitted `config_json` with the real Go decoders
  for every bundled add-on (netprobe, otel-collector, anomaly, bumblebee,
  endpoint-inventory, workload-identity, rdp).
- **Fix the concrete netprobe regression**: remediate corrupt string-typed
  assignment params (coordinate with
  `fix-staging-observability-addon-regressions` PR6.3), add the delivery-path
  coercion + tolerant agent decoder, and restore flow attribution on demo.
- **Add-on fleet UI overhaul** (per screenshots):
  - One row per (agent × add-on) showing the *effective* state: assigned
    version, running version, health; historical/unassigned versions collapse
    behind the add-on detail view.
  - Drift rendered as a comparison ("running 0.1.19 → assigned 0.1.20"), never
    a bare version number; no drift label at all when there is nothing
    meaningful to compare (unassigned rows never say `drift: 0.0.0`).
  - Catalog-only inventory separated from fleet status (no `— (catalog only)`
    rows inside the fleet table).
  - No horizontal scroll at standard desktop widths; badges never truncate;
    full error text reachable (expand/tooltip/detail).
- **Catalog import UX** (add-on catalog AND the WASM plugin catalog "Plugins
  Manager", which has the identical problem): import is idempotent and
  stateful — the action shows imported-vs-available state, disables or
  relabels when everything is already imported, and shows progress + a result
  summary when triggered.
- **Version presentation model**: fleet and assignment flows default to the
  latest approved version; older versions are selectable only inside a specific
  add-on's detail page; agents already on the latest are visibly marked
  up-to-date ("on latest") without enumerating stale versions.

## Impact

- Affected specs: `agent-config`, `plugin-configuration-ui`
- Affected code:
  - `go/pkg/agent/push_loop_config.go`, `go/pkg/agent/push_loop_addons.go`,
    `go/pkg/agent/control_stream.go`, `go/pkg/agent/addon_delivery.go`,
    `go/pkg/agent/netprobe/config.go`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex`
    (`to_proto_addons`/`normalize_map` delivery path),
    `elixir/serviceradar_core/lib/serviceradar/plugins/config_schema.ex`,
    `.../plugins/validations/addon_assignment_params.ex`,
    `.../plugins/addon_profile_reconciler.ex` (params write paths)
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/control_stream_session.ex`
    (config_ack persistence)
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/addon_fleet.ex` +
    `.../live/admin/addon_fleet_live/` (fleet UI), add-on catalog LiveViews
  - CI: config contract test suite (core-emitted `config_json` ↔ real Go decoders)
- Relationship to in-flight changes (deliberate non-overlap):
  - `fix-staging-observability-addon-regressions` (5/43): owns the staging
    remediation PRs, including idempotent apply on *unchanged versions* and the
    `native-addon-delivery` capability (fleet inventory reporting, systemd
    self-heal, per-agent enablement). Its task 6.5 ("classify as permanent
    failure so it stops wedging the config ack") is subsumed by the sectioned
    apply/ack architecture here; this change intentionally writes NO
    `native-addon-delivery` deltas (that capability has no baseline until that
    change archives) and instead lands protocol-level requirements in
    `agent-config` and UX requirements in `plugin-configuration-ui`.
  - `add-addon-profile-targeting` (8/13): owns SRQL-targeted assignment +
    skip-diagnostics + the gateway-only artifact delivery boundary; the fleet
    UI here must respect that boundary and surface its skip reasons.
  - `add-netprobe-fleet-attribution` (51/84): made `capture_interfaces`
    optional/advanced (schema + form UX); it does NOT cover the string-vs-list
    serialization contract, which is specified here.
- **BREAKING**: agent config-ack protocol gains per-section semantics (older
  agents keep whole-version acks; core treats missing section status as legacy)
