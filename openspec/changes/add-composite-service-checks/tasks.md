## 1. Investigation

- [x] 1.1 Confirm the exact read path and freshness semantics of
      `platform.device_agent_availability` (`checked_at` update cadence, what
      `is_available` collapses per sweep mode) so `blocked` is specified against
      real behavior, not assumed behavior.
- [x] 1.2 Trace the DIRE merge path that calls
      `DeviceAgentAvailability.reassign_device` and identify every call site a
      new result resource must be added to.
- [x] 1.3 Confirm the OCSF attribute set and severity helpers a verdict event
      should use, following the system-actor `Ash.create(OcsfEvent, action:
      :record)` pattern in `credentials/credential_event_writer.ex:281`.
- [x] 1.4 Confirm how `rust/srql` resolves dotted dynamic keys for `tags.<key>`
      and what the equivalent resolution for `composite.<slug>` requires on both
      the translator and Ash adapter sides.
- [x] 1.5 Confirm the `target_builder` round-trip contract used by
      `visibility_profiles_live` so the scope panel reuses it rather than
      reimplementing SRQL parsing.

## 2. Data Model

- [x] 2.1 Add the migration creating `platform.composite_checks`,
      `composite_check_inputs`, `composite_check_rules`, and
      `device_composite_check_results`, with the `(device_uid, check_id)` unique
      index and scope/lookup indexes.
- [x] 2.2 Add `ServiceRadar.CompositeChecks.CompositeCheck` with slug
      immutability after first enable, `in:devices` scope validation, state
      transitions, and Ash policies.
- [x] 2.3 Add `CompositeCheckInput` with the `vantage_point` and
      `device_metadata` kinds, per-kind config validation, and unique keys per
      check.
- [x] 2.4 Add `CompositeCheckRule` with ordered positions, the match map, the
      operator-defined verdict slug, and the fixed status enum.
- [x] 2.5 Enforce the mandatory trailing catch-all rule: auto-created on check
      creation, undeletable, always last.
- [x] 2.6 Add `DeviceCompositeCheckResult` including the input snapshot,
      `evaluated_at`, `changed_at`, and a `reassign_device` action.
- [x] 2.7 Wire `DeviceCompositeCheckResult.reassign_device` into every DIRE merge
      call site found in 1.2.

## 3. Input Resolution

- [x] 3.1 Add the vantage point resolver over `device_agent_availability` with
      missing-row and `max_age` staleness handling.
- [x] 3.2 Add the device metadata resolver reading the value and its provenance,
      with absent, stale, no-provenance, and type-mismatch all yielding `unknown`.
- [x] 3.3 Define the resolver behaviour/contract that a future input kind
      implements, and add a test proving a new kind needs no evaluator, storage,
      or rule-structure change.

## 4. Evaluation

- [x] 4.1 Add `CompositeChecks.Evaluator.verdict/2` as a pure function returning
      `{verdict, status, matched_rule_id}`.
- [x] 4.2 Add `CompositeChecks.EvaluationWorker`: resolve scope via the SRQL Ash
      adapter, page 1000 UIDs, one availability query and one metadata query per
      page, bulk upsert, diff against prior verdict.
- [x] 4.3 Delete result rows for devices that no longer match the scope.
- [x] 4.4 Schedule the worker per enabled check on its `evaluation_interval`, and
      reconcile schedules on check create/enable/disable/delete/interval change.
- [x] 4.5 Add the debounced per-device refresh triggered by sweep result
      ingestion and by device fact writes.
- [x] 4.6 Record verdict transition OCSF events under a system actor, logging
      and swallowing failures so they never fail the evaluation.
- [x] 4.7 Add evaluation telemetry: pass duration, devices evaluated, verdict
      transition count, per-input unknown rate.
- [x] 4.8 Retain and mark stale (never clear) existing results when a pass fails,
      and let Oban retry.

## 5. Coverage And Validation

- [x] 5.1 Add per-vantage-point coverage computation over a check's scope.
- [x] 5.2 Block enabling at zero coverage without explicit acknowledgement;
      surface partial coverage with counts.
- [x] 5.3 Add the liveness witness validation for checks with two or more vantage
      points.
- [x] 5.4 Add expectation-seeded rule generation, and the regeneration warning
      when rules were edited after generation.
- [x] 5.5 Surface a configuration error on the check when an input references an
      agent or path that no longer resolves, without failing the pass.

## 6. External Fact Ingress

- [x] 6.1 Add `PATCH /api/devices/:uid/metadata` in web-ng writing the plain
      value plus server-stamped provenance per key.
- [x] 6.2 Enforce the write bounds: key pattern, scalar values only, per-device
      fact cap, reserved internal keys rejected, whole request rejected on any
      invalid fact.
- [x] 6.3 Add the `devices.facts.write` permission to the RBAC catalog and gate
      the endpoint on it for both session and API token principals.
- [x] 6.4 Document the NCO phase-1 integration: endpoint, auth, payload, and the
      `max_age` implication of provenance.

## 7. SRQL

- [x] 7.1 Add `composite.<slug>` and `composite.<slug>.status` device field
      resolution in `rust/srql` as a correlated `EXISTS` over
      `device_composite_check_results` joined to `composite_checks` on slug,
      following `filters/availability.rs` (`apply_agent_availability_filter`).
      NOT the `tags.<key>` precedent: that is a JSONB path filter on a column of
      the same table and shares only the dotted-key token shape. `DeviceQuery`
      is boxed over `ocsf_devices` alone, so a JOIN would change its type across
      the module.
- [x] 7.2 Add the `composite_results` entity with check/verdict filters and
      per-status counts.
- [x] 7.3 Add the arm in `query/devices/filters/params.rs` that mirrors the
      `apply_filter` arm. These are parallel matches on the same field names in
      different files; a field added to one and not the other fails at query
      time with a placeholder/parameter mismatch, not at compile time.
      (Supersedes "add the Ash adapter side": there is no SRQL Ash adapter.
      `web-ng` translates through the NIF (`SRQL.Native` -> `ServiceRadarSRQL.Native`)
      and executes the SQL; the `AshAdapter` named in AGENTS.md and the
      `serviceradar_srql` moduledoc does not exist in the tree.)
- [x] 7.4 Extend the SRQL catalog so the visual builder offers composite fields
      and each enabled check's authored verdict slugs as values.
- [x] 7.5 Validate composite slugs in the Elixir layer, failing with an error
      naming the unknown check. The translator cannot do this: it is a pure
      query compiler with no database connection. It does guarantee the safety
      half for free -- because the predicate joins `composite_checks` on slug, an
      unknown slug matches nothing, so the filter returns zero devices rather
      than degrading to "match everything".

## 8. UI

- [x] 8.1 Add the composite check index with state, scope size, and verdict
      rollup per check.
- [x] 8.2 Add the builder shell with scope, vantage points, verdict table, and
      preview sections.
- [x] 8.3 Wire the scope section to the existing SRQL visual builder with
      bidirectional round-trip and a device count.
- [x] 8.4 Add the vantage point section with agent picker, expectation selector,
      and liveness-witness / isolation-probe labelling.
- [x] 8.5 Add the editable verdict rule table with reordering and the protected
      catch-all row.
- [x] 8.6 Add the live preview panel: sampled device, per-input breakdown with
      ages, resulting verdict, and rollup counts with the unreachable-population
      explanation.
- [x] 8.7 Add the read-only sweep coverage reference with a link to sweep
      administration, listing every sweep group that covers each vantage
      point's agent and naming the case where none do. Not "the scan profile":
      `SweepGroup.agent_id` is nullable and means "any agent in partition", so
      an agent is covered by every group assigned to it plus every unassigned
      group in its partition. There is no single profile to show, and picking
      one would misstate which ports are actually probed.
- [x] 8.8 Add the composite verdict section to device detail with the per-input
      breakdown and unknown reasons stated rather than blank.
- [x] 8.9 Add the optional composite column and filter to the device list. The
      column appears only when the query already filters on one check, which is
      what makes "the" verdict well-defined: a device can hold a verdict for
      several checks at once.
- [x] 8.10 Enforce the `composite_checks` RBAC permissions in LiveView mount
      and every `handle_event`. (The catalog section itself was added with the
      device fact endpoint in section 6.)
- [x] 8.11 Surface readiness on the builder: blocking problems, coverage
      warnings with counts, per-agent coverage, and the enable/disable controls.
      The coverage report is produced at save time as well as on demand, which
      is why saving stays on the builder instead of returning to the index.
- [x] 8.12 Add the device fact section so the builder can author the third
      factor. Section 8 originally described the builder as scope + vantage
      points + rules, which left `:device_metadata` inputs creatable only
      through the API even though the resolver, rule generator, evaluator and
      rule table all already handled them. Without it the builder could not
      express the distinction the feature exists for: blocked-and-configured
      (`isolated_verified`) versus blocked-but-not-by-configuration
      (`isolated_unenforced`). Facts are positioned after the vantage points so
      the rule columns read in the order the verdict is reasoned. A blank max
      age omits the key rather than storing nil, because the resolver treats
      absent `max_age_seconds` as "resolve on the stored value, no provenance
      required" -- storing a nil would instead demand provenance and resolve
      every pre-provenance key `:unknown` forever.

## 9. Northbound

- [x] 9.1 Add composite check and value-form selection to Armis northbound
      configuration. Stored in `settings["composite"]` as check_slug,
      value_form, and custom_field; all three required, unknown value form
      disables the export rather than guessing.
- [x] 9.2 Emit the selected verdict or status per in-scope device, omitting
      devices with no result rather than sending a placeholder. Omission falls
      out of the value map's shape — a device with no result is absent from it —
      rather than being a filter a later step could forget.
- [x] 9.3 Display the selection in northbound run status, read from the run's
      own metadata so it describes that run rather than the source's current
      selection.

## 10. Verification

- [x] 10.1 Table-driven evaluator tests over the full input cross-product,
      including the six-row isolation table as a named fixture.
- [x] 10.2 Property test: for any input combination exactly one rule matches.
- [x] 10.3 Test that preview and periodic evaluation produce identical results
      for identical inputs.
- [x] 10.4 End-to-end test with two agents reporting different availability for
      one device, following `sweep_results_flow_e2e_test.exs`.
- [x] 10.5 Staleness test: a fact aging past `max_age` flips the verdict on the
      next periodic pass with no triggering event.
- [x] 10.6 Scope-exit test: a device leaving scope loses its result row and drops
      out of the rollup.
- [x] 10.7 Device merge test: verdicts survive a DIRE merge with exactly one row
      per check on the surviving UID.
- [x] 10.8 Fact API tests: bounds enforcement, reserved keys, back-dating
      ignored, unauthorized rejected, unknown device rejected.
- [x] 10.9 SRQL tests for verdict and status filters, the rollup entity, and the
      unknown-slug error. 22 Rust tests (`cargo test --lib composite`) plus the
      Elixir end-to-end "an unknown slug returns nothing rather than everything".
- [x] 10.10 LiveView tests for the three save-time validations and the scope
      round-trip.
- [x] 10.11 Run DB-backed tests against the `srql-fixtures` scratch database.
- [x] 10.12 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
      and `--project elixir/web-ng --phoenix`, plus `cargo fmt` / `cargo clippy`
      on `rust/srql`.
- [x] 10.13 Run `openspec validate add-composite-service-checks --strict`.
