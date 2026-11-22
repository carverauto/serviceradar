## 1. Profile schema and generator

- [ ] 1.1 Add `tools/syslog_profiles/` to read napalm-logs YAML (and
      `nxos/USER_LOGIN.py`) at commit `1f7b06f808156812bab07d1c622fa1d0ba91f2d5`
      and emit `serviceradar.syslog.profile.v1` documents.
- [ ] 1.2 Port prefix lists, `match_on`, line templates, value patterns, the
      closed transform set, attribute projections, and yang mappings.
- [ ] 1.3 Fail the generator on an unknown transform, a `{name}` without a
      value, or a capture that has nowhere to land.

## 2. Matcher in the shared Zen engine

- [ ] 2.1 Implement the `syslog_profile` custom node in `rust/zen-normalize`
      and register it from `RuleSet::compile`. Leave every other custom node
      a no-op.
- [ ] 2.2 Index messages by tag at compile time. Apply the match procedure,
      transforms, and attribute writes from the design.
- [ ] 2.3 Short-circuit when `syslog.matched` is already true.
- [ ] 2.4 On compile or evaluation error, keep the record and increment
      `zen_syslog_profile_errors`. Do not drop the log in the collector or
      in core.

## 3. Zen template and Solution Packs

- [ ] 3.1 Teach `ZenRuleTemplates.compile/2` to embed `builder_config` in the
      `syslog_profile` custom node when the template name is `syslog_profile`.
- [ ] 3.2 Validate that template in `pack_manifest.ex` and
      `js/cli/src/pack/validate.ts`: schema, transforms, regex compile, and
      the nested-repetition rejection list.
- [ ] 3.3 Add ten built-in packs under
      `elixir/serviceradar_core/priv/solution_packs/syslog-<os>/`, each with
      one `zen_rule` named `syslog_profile_<os>`, subject `logs.syslog`,
      order 112, and a README that credits napalm-logs Apache-2.0 at the
      pinned commit.
- [ ] 3.4 Confirm install, upgrade, and uninstall publish and withdraw the
      compiled rule on `zen/rulesets/events/logs.syslog.json` through the
      existing reconciler. Do not seed the rules into every tenant.

## 4. Corpus and docs

- [ ] 4.1 Add Rust corpus tests for every `syslog.msg` / `yang.json` pair
      under napalm-logs `tests/config` (133 messages), plus one parsed-record
      test per platform.
- [ ] 4.2 Add a collision test that loads every profile together and fails if
      two profiles match the same fixture.
- [ ] 4.3 Document the attribute keys and the packs in `docs/docs/syslog.md`
      and `docs/docs/solution-packs.md`.

## 5. Validation

- [ ] 5.1 `openspec validate add-syslog-vendor-profiles --strict` (already
      required for this proposal; re-run after any spec edit during
      implementation).
- [ ] 5.2 `./scripts/bazel test --config=remote` for `//rust/zen-normalize:zen_normalize_test`
      and the Elixir pack-manifest tests touched above.
