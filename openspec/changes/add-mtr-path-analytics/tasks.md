## 1. Proposal

- [x] 1.1 Validate with `openspec validate add-mtr-path-analytics --strict`.
- [x] 1.2 Get approval before implementation.
- [x] 1.3 Confirm the two open gates in [design.md](design.md): the StarRocks
      arbitrary-duration bucketing function, and whether MTR results are already
      published to a JetStream subject.

## 2. SRQL aggregates (parser)

- [x] 2.1 Add `LossRatio` and `Wavg` variants to `StatsAggType` in
      `rust/srql/src/parser/ast.rs`.
- [x] 2.2 Add a second optional field to `StatsAggregation` for the two-argument
      form, leaving the single-argument form unchanged.
- [x] 2.3 Parse `loss_ratio(a, b)` and `wavg(a, b)` in
      `rust/srql/src/parser/stats.rs`, rejecting a one-argument call to either
      with `InvalidRequest`.
- [x] 2.4 Recognise a `time:<duration>` group dimension in the post-`by` clause,
      reusing `parse_bucket_seconds`; reject a duration on any other dimension.
- [x] 2.5 Add parser tests in `rust/srql/src/parser/tests.rs` covering both new
      functions, the arity error, the time dimension, and that `avg` still parses
      to `StatsAggType::Avg`.

## 3. CNPG implementation (`mtr_hops`)

- [x] 3.1 Emit `loss_ratio` as a ratio of sums returning NULL when the
      denominator sums to zero, in `rust/srql/src/query/mtr_hops.rs`.
- [x] 3.2 Emit `wavg` as `SUM(value * COALESCE(weight,0)) / SUM(COALESCE(weight,0))`,
      returning NULL when the weight sums to zero.
- [x] 3.3 Whitelist the valid column pairs so `loss_ratio(sent, received)` and
      `wavg(<latency>, received)` are accepted and other pairings are rejected.
- [x] 3.4 Emit the time-bucket group dimension using the epoch-floor form the
      downsample builder already uses; include the bucket in `GROUP BY` and in
      the projection.
- [x] 3.5 Keep the newest buckets when `limit:` truncates a bucketed result and
      still return ascending, per the `downsample/sql.rs:16-25` defect.
- [x] 3.6 Unit tests: correct loss SQL shape, weighted-average SQL shape,
      zero-denominator NULL, bucket in `GROUP BY`, newest-bucket truncation,
      rejected column pairing, rejected arity.
- [x] 3.7 Assert in a test that `avg(loss_pct)` still compiles to `AVG`, so the
      old behaviour is not silently redefined.

## 4. StarRocks dialect parity

- [x] 4.1 Implement `loss_ratio` and `wavg` in `rust/srql/src/query/starrocks.rs`
      with identical NULL and zero-denominator semantics.
- [x] 4.2 Implement the time-bucket group dimension per the resolved design gate;
      refuse an unsupported duration with `InvalidRequest` rather than rounding.
- [x] 4.3 Add the shared (aggregate, backend) support table and assert it from
      tests on both builders, so adding a variant to one alone fails.
- [x] 4.4 Tests: same aggregate produces the same semantics on both backends, and
      an unsupported combination errors rather than silently differing.

## 5. Close the silent stats-drop

- [x] 5.1 Return `InvalidRequest` for a `stats:` clause in each module that does
      not implement one: `bmp_events`, `capacity_forecasts`,
      `endpoint_inventory_scans`, `field_survey`, `source_fact_disagreements`,
      `virtualization`, following the guard `mtr_traces` already uses.
- [x] 5.2 One test per module asserting the refusal, so a `stats:` clause can
      never again be discarded silently.

## 6. Amend the superseded requirement

- [x] 6.1 Replace `stats:avg(loss_pct)` / `stats:avg(avg_us)` in
      `openspec/changes/add-srql-mtr-hops-entity/specs/mtr-diagnostics/spec.md`
      with the correct aggregates, so archiving that change cannot restore the
      incorrect panel queries.
- [x] 6.2 Update section 4 of that change's `tasks.md` to point at this change
      and drop the `/analytics` route task: `/analytics` is already bound to
      `AuthoredDashboardLive.Index` and `analytics_live/index.ex` is an unrelated
      2086-line page.
- [x] 6.3 Check off sections 1-3 of that change, which are implemented and
      correct, and run `openspec validate add-srql-mtr-hops-entity --strict`.

## 7. Built-in dashboard definition

Only the definition is created — the dashboard row and its panels, each holding
SRQL text. Every panel runs that SRQL against live data on each load; nothing
here stores panel content.

- [x] 7.1 Generalise `elixir/web-ng/lib/serviceradar_web_ng/dashboards/system_reports.ex`
      from its hardcoded single dashboard to a list of dashboard specs,
      preserving the existing `new-devices` dashboard's slug, title, description,
      query and metadata.
- [x] 7.2 **Fix the revert bug while doing so.** Remove the content reconcile:
      `maybe_update_new_devices_panel/2` writes `@new_devices_query` back over a
      differing `srql_query`, so an operator edit to the shipped `new-devices`
      dashboard is silently reverted on the next boot. Replace with
      create-when-absent; never rewrite an existing title, description, time range
      or panel query. A dashboard row with zero panels MAY have its panels
      created, since that is an interrupted creation, not an operator choice.
- [x] 7.3 Add the MTR path analytics dashboard spec: public, active, default time
      range `last_24h`, `system_report` metadata.
- [x] 7.4 Loss-hotspot panel using `loss_ratio(sent, received)` grouped by `addr`,
      with `label_field`/`value_field` bindings.
- [x] 7.5 Latency panel using `wavg(avg_us, received)` grouped by `addr`.
- [x] 7.6 External/transit AS loss panel using `loss_ratio(sent, received)` grouped
      by `asn` and filtered with `asn:>0`, titled so it cannot be read as
      fleet-wide. `asn` comes only from GeoLite2, so it is NULL for every internal
      hop and every private AS.
- [x] 7.7 Loss trend panel using the `time:<duration>` group dimension and a
      `:line` visual type, with a `time_field` binding.
- [x] 7.8 Update `mtr_hops` in the web-ng SRQL catalog for the new aggregates.
      **No change needed — verified, not assumed.** The catalog has no notion of
      aggregate function names, and `stats_agg_fields` / `stats_group_fields` are
      read by nothing in the repository; they are dead declarations. The key that
      *is* consumed is `filter_fields` (`srql/page.ex` rejects a filter field
      absent from it), and `asn` is already listed, which is what the AS panel's
      `asn:>0` needs.
      `time` was deliberately NOT added to `stats_group_fields`: the builder emits
      a bare field name after `by`, so offering `time` would produce `by time`,
      which the entity rejects because `time` is not a groupable column. The
      dimension requires `time:<duration>`, which the builder cannot express yet.
- [x] 7.9 Tests for the definition step: creates when absent; is idempotent across
      repeated runs; **does not revert an edited panel query, title or
      description**; does not remove an operator-added panel; completes a dashboard
      row that has no panels; leaves `new-devices` content untouched. Add a row to
      `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` if a new
      `serviceradar_core` test file is introduced.
- [x] 7.10 Tests for edit authority on the built-in dashboard, whose public /
      no-owner / no-grant combination is the least covered today: an actor with
      view permission but neither `analytics.dashboards.edit` nor a per-dashboard
      grant is refused a panel `srql_query` update and the stored query is
      unchanged; an actor holding the permission succeeds; an actor holding only a
      per-dashboard grant succeeds.
- [x] 7.11 Verify the interactive panel-edit path supplies the acting user as
      `actor`, since an Ash policy does not run when no actor is given. Read the
      LiveView event handler and assert the refusal through the path it uses.

## 8. Readiness for MTR in the warehouse (dialect side only)

Moving MTR telemetry into StarRocks is **owned by
`extend-starrocks-to-all-telemetry`** (its task 3.4 "MTR traces and hops", and
its requirement "All append-only telemetry is warehouse-eligible"). That change
also owns cutover parity and retention; CNPG stays a supported backend and is not
retired. This change does not
duplicate any of it and adds no competing requirement. The tasks here make the
dialect ready so that when MTR lands in the warehouse, the correct aggregates
already exist there rather than being added under cutover pressure.

- [x] 8.1 Confirm the aggregates and the time-bucket dimension from section 4 are
      reachable for any entity `starrocks.rs` serves, so no per-entity work is
      needed when MTR is added there.
- [x] 8.2 Record in `extend-starrocks-to-all-telemetry` that MTR's warehouse
      rollups should use `loss_ratio` and `wavg`, so its task 3.4 does not
      materialize a rollup built on `AVG(loss_pct)`.
- [x] 8.3 Note the finding from gate 1.3 in that change: MTR results are not
      published to JetStream today. `MtrMetricsIngestor` receives a payload
      directly from the agent and writes CNPG, so an MTR warehouse destination
      needs a JetStream publication step first to satisfy the
      JetStream-first/EventWriter-single-owner rule.
- [x] 8.4 Leave the dashboard's panel queries backend-agnostic, so they serve
      from CNPG now and from the warehouse after that change's cutover with no
      panel edit.

## 9. Validation

- [x] 9.1 `cargo check --workspace --lib --bins --tests` and
      `cargo fmt` / `cargo clippy` clean on touched crates. Clippy green in CI on
      the merge of PR #4565 (2m22s); `cargo fmt` and clippy also clean locally on
      lib and test targets.
- [x] 9.2 `bazel build //rust/...` clean. Covered by BazelCI, green in 14m on
      PR #4565. Could not be run locally: no `.bazelrc.remote` exists on the
      development machine, so RBE cannot authenticate.
- [x] 9.3 `make test` green. Covered by BazelCI on PR #4565, which builds and
      tests the same Bazel graph including the Elixir unit shards that are
      invisible to `go test`/`cargo test`/`mix test`. Same local RBE limitation as
      9.2.
- [x] 9.4 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix --lint-only` clean.
      Elixir Quality (web-ng) green in CI on PR #4565 (3m6s); `mix format
      --check-formatted` also clean locally on both changed files.
- [ ] 9.5 Verify each panel query returns correct aggregates against synthetic MTR
      data, including a group with zero probes sent (expect NULL, not zero) and a
      group whose hops sent unequal probe counts (expect the ratio-of-sums result
      to differ from the mean-of-ratios result).
- [ ] 9.6 Verify the built-in dashboard renders every panel, and that a second
      startup does not duplicate it.
- [x] 9.7 Verify a `stats:` clause against each module from section 5 errors
      rather than returning rows. Asserted by
      `entities_without_aggregation_refuse_a_stats_clause`, which exercises all six
      modules and was confirmed to fail with a guard removed.

## 10. Coverage limits found while testing, recorded rather than papered over

- **web-ng has no DB-backed Bazel target.** `elixir/web-ng/BUILD.bazel` states it
  directly: `test/integration/**` and `test/property/**` are excluded because
  nothing in them is `:db_free`, and "they belong in a DB-backed target; until one
  exists they are not covered by Bazel". `test_helper.exs` is an allow-list
  (`exclude: [:test], include: [:db_free]`) with an `after_suite` hook that fails
  a target executing zero tests — added after two targets reported PASSED on
  "0 tests, 0 failures (11 excluded)".

  So an end-to-end authorization test — create the built-in dashboard, attempt a
  panel update as a view-only user, assert the stored query is unchanged — has no
  home that executes today. Rather than write a test that never runs, the
  properties are asserted where they can run:
  - The no-clobber rule is a pure function (`SystemReports.definition_action/1`),
    asserted directly. Confirmed to fail when the `:keep` branch is broken.
  - Edit authority is asserted against `DashboardPanel`'s own policy model via
    `Ash.Policy.Info.policies/1` — a typed structure, not its source text — so a
    behaviour-preserving rewrite passes and dropping the authorization fails.
  - The interactive path's decision is a pure function
    (`AccessControls.can_manage?/2`), asserted for the built-in shape: public,
    no owner, no edit permission.

- **The interactive editor is stricter than the data layer, and the spec now says
  so.** `can_manage?/2` is dashboard ownership or `analytics.dashboards.edit`; it
  never consults a per-dashboard edit grant, which `ActorCanEditDashboardChild`
  does honour. A grant-only actor is therefore refused through the UI and
  permitted through the data layer. That direction is fail-closed, so it is
  recorded as current behaviour rather than changed here. The requirement
  constrains only the dangerous direction: the interactive path must never permit
  what the data layer would refuse.

- [x] 10.1 ~~Decide whether a DB-backed web-ng test target is worth adding.~~
      Resolved by `add-declarative-dashboards-and-mtr-device-scope`: that change
      added `//elixir/web-ng:networks_live_db_test`, which runs against the shared
      SRQL fixture in CI and already carries `group_access_db_test.exs`,
      `authored_dashboard_live_test.exs`, and the five `SystemReports.seed_all/1`
      idempotency tests from PR #4652. The end-to-end authorization and
      definition-idempotency tests described above now have a home that executes.

- **The panel set shipped by this change is superseded.** The dashboard defined
  here (`mtr-path-analytics`) aggregated `loss_ratio` across all hop positions
  without a per-hop qualification. That makes ICMP-rate-limiting at a transit
  router read as packet loss, which is the specific failure the
  `add-declarative-dashboards-and-mtr-device-scope` change was opened to correct.
  Additionally, none of the panels here could be scoped to a specific target device.
  The replacement dashboard definition in `priv/dashboards/mtr-path-analytics.json`
  (merged in PR #4640) corrects both issues. The slug is the same; once the new
  definition is seeded, an existing `mtr-path-analytics` dashboard is not overwritten
  unless its panels are absent (the create-when-absent rule), so operators who have
  already customised it are unaffected.
