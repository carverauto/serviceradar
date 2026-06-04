## 1. Agent — attribution without capture (shipped in v1.2.90)
- [x] 1.1 Relax `netprobeConfigHasWork` so `enabled` alone runs netprobe (`go/pkg/agent/push_loop_config.go`)
- [x] 1.2 Verify agent tests cover enable-only launch (`go test ./go/pkg/agent/...`)

## 2. Config schema — attribution-first defaults
- [x] 2.1 Add sensible defaults + clarify `enabled` runs attribution (`addons/netprobe/config.schema.json`)
- [ ] 2.2 Mark `capture_interfaces`, `dpi`, `default_sample_interval_ms`, `external_flow_match_window_ms`, `device_bindings` as advanced via an `x-serviceradar-ui-*` hint
- [x] 2.3 Confirm no capture field is in the schema `required` set (top-level schema has no `required`)

## 3. Operator form — one-touch
- [ ] 3.1 Render `x-serviceradar-ui-advanced` properties in a collapsed "Advanced" section in the web-ng add-on assignment form
- [ ] 3.2 Make Enable the only required input for an attribution assignment (single-agent + cohort)
- [ ] 3.3 Update copy so capture interfaces read as optional/advanced, not required

## 4. Seeding — manifest-driven
- [x] 4.1 `NetprobeAddonPackageSeeder` derives `version` + `capabilities` from the in-image manifest (`addon.yaml`) instead of hardcoded `@version "0.1.0"`
- [x] 4.2 Seeder always writes the in-image `config_schema` (create or update), so a schema change reaches the seeded package
- [x] 4.3 When no matching signed artifacts are configured, stage (do not approve) the manifest version instead of no-op'ing, so the version + schema become visible; approve only verified versions
- [ ] 4.4 Generalize the same manifest-driven seeding for other native add-ons (bumblebee, endpoint-inventory) or factor a shared helper

## 5. Publish pipeline (shipped in v1.2.90)
- [x] 5.1 `native-addons.yml` triggers on `v*` tags (republish on release)
- [ ] 5.2 Wire the published import index into the seeder's signed-artifact config so artifact refs track the release (removes the manual runtime-config step)

## 6. Verification
- [ ] 6.1 On a release, confirm the add-ons UI shows the new netprobe version + updated schema
- [ ] 6.2 Assign netprobe (Enable only) to a worker cohort; confirm attribution streams and attributed-flow rows appear with no interface config
- [ ] 6.3 Confirm capture/DPI still works when opted in via advanced settings
