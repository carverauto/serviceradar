# Let a plugin propose alert rules for operator approval

## Why

A plugin can ship the metrics it collects, but nothing that watches them. So
every deployment repeats the same manual step: read the plugin's docs, work out
which metric names it emits and which tags they carry, and hand-author rules in
the UI. That is friction for the operator and, worse, a correctness trap — the
person authoring the rule is not the person who knows the metric.

Two failure modes this produces are already documented in the customer's
`config/ALERT-RULES.md`: a rule grouping on a tag the metric never emits fails
**silently** (`build_group` skips every record with no error), and a rule
thresholding a cumulative `_total` counter becomes true once and never
recovers. The plugin author knows both; the operator has to rediscover them.

## What Changes

A plugin manifest may declare `alert_rules:`. On **approval** — not import —
each becomes a row in `stateful_alert_rules`, **disabled**.

```yaml
alert_rules:
  - name: controller-down
    signal: metric
    match:
      metric_name: aruba.device.up
      metric_condition: {comparison: lt, threshold: 1}
    group_by: [hostname]
    threshold: 2
    window_seconds: 7200
```

This clones the `producer_schedules` pipeline rather than inventing a mechanism:
same manifest shape, same approval hook, same operator-ownership contract.

### A plugin proposes; it never activates

`enabled` is **not an accepted manifest key**, and rows are created
`enabled: false`. Arming a rule is a human action in the UI, because a rule that
fires pages someone and a plugin update must never change who gets woken up. A
test asserts the key is rejected.

### Re-sync cannot overwrite an operator

The update branch takes only the rule's *definition* — what it watches and what
it says. `enabled`, `threshold`, `window_seconds`, `bucket_seconds`,
`cooldown_seconds`, `renotify_seconds` and `priority` are structurally excluded,
so a plugin upgrade cannot re-arm a rule someone disabled or undo a threshold
they tuned. Tuning fields ARE applied on create, so a plugin can still ship
sensible starting values. This mirrors `RuleSeeder`'s `@managed_fields`.

### Sync runs on approve, not import

`producer_schedules` materialize at import, before anyone has read the manifest.
Alert rules deliberately do not: a staged package is unreviewed content, and
nothing it declares should reach the database until a human approves it. On
deny/revoke/restage the rules are **disabled, not deleted** — an operator may
have tuned them, and re-approving should not silently lose that.

### Names are namespaced

`plugin:<package>:<name>`. `RuleSeeder.ensure_managed_defaults/3` keys the whole
rule table by name and adopts unmanaged rows matching its built-in defaults, so
a package shipping a rule called `sweep_device_unavailable` would otherwise
collide with a core-managed one. The prefix makes that impossible rather than
unlikely.

## Impact

- Affected specs: `wasm-plugin-system`
- Affected code: `plugins/manifest.ex`, `plugins/alert_rule_catalog.ex` (new),
  `plugins/plugin_package.ex`, `observability/stateful_alert_rule.ex`,
  `web-ng/plugins/packages.ex`, one migration
- **Purely additive.** A manifest without `alert_rules:` behaves identically.
- The `plugin_package_id` FK is nullable with `ON DELETE SET NULL` — removing a
  package must not delete rules an operator tuned and relies on. An orphaned
  rule is visible and recoverable; a cascade is neither.

### A pre-existing gap this does not fix

`Manifest.from_map/1` rejects unknown keys only *inside* nested blocks — there
is no top-level unknown-key check. So a manifest with `alert_rule:` (singular)
validates and is silently discarded. This change adds the nested check for its
own block, matching every existing sibling, but does not add a top-level one:
that would reject manifests which validate today, and the blast radius belongs
in its own change.

### Deliberately out of scope

- **A capability token** like `alert-rules:v1`. `manifest.ex` already warns that
  `advisory-feed:v1` and `producer-schedule:v1` are "declared here and enforced
  nowhere". Adding a third unenforced string reproduces that defect.
- **A UI for reviewing proposed rules.** They appear in the existing rule list,
  disabled. A dedicated review surface is worth having and is a separate change.
