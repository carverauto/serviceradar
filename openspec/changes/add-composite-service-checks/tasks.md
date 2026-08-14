## 1. Investigation

- [ ] 1.1 Confirm the exact read path and freshness semantics of
      `platform.device_agent_availability` (`checked_at` update cadence, what
      `is_available` collapses per sweep mode) so `blocked` is specified against
      real behavior, not assumed behavior.
- [ ] 1.2 Trace the DIRE merge path that calls
      `DeviceAgentAvailability.reassign_device` and identify every call site a
      new result resource must be added to.
- [ ] 1.3 Confirm the OCSF attribute set and severity helpers a verdict event
      should use, following the system-actor `Ash.create(OcsfEvent, action:
      :record)` pattern in `credentials/credential_event_writer.ex:281`.
- [ ] 1.4 Confirm how `rust/srql` resolves dotted dynamic keys for `tags.<key>`
      and what the equivalent resolution for `composite.<slug>` requires on both
      the translator and Ash adapter sides.
- [ ] 1.5 Confirm the `target_builder` round-trip contract used by
      `visibility_profiles_live` so the scope panel reuses it rather than
      reimplementing SRQL parsing.

## 2. Data Model

- [ ] 2.1 Add the migration creating `platform.composite_checks`,
      `composite_check_inputs`, `composite_check_rules`, and
      `device_composite_check_results`, with the `(device_uid, check_id)` unique
      index and scope/lookup indexes.
- [ ] 2.2 Add `ServiceRadar.CompositeChecks.CompositeCheck` with slug
      immutability after first enable, `in:devices` scope validation, state
      transitions, and Ash policies.
- [ ] 2.3 Add `CompositeCheckInput` with the `vantage_point` and
      `device_metadata` kinds, per-kind config validation, and unique keys per
      check.
- [ ] 2.4 Add `CompositeCheckRule` with ordered positions, the match map, the
      operator-defined verdict slug, and the fixed status enum.
- [ ] 2.5 Enforce the mandatory trailing catch-all rule: auto-created on check
      creation, undeletable, always last.
- [ ] 2.6 Add `DeviceCompositeCheckResult` including the input snapshot,
      `evaluated_at`, `changed_at`, and a `reassign_device` action.
- [ ] 2.7 Wire `DeviceCompositeCheckResult.reassign_device` into every DIRE merge
      call site found in 1.2.

## 3. Input Resolution

- [ ] 3.1 Add the vantage point resolver over `device_agent_availability` with
      missing-row and `max_age` staleness handling.
- [ ] 3.2 Add the device metadata resolver reading the value and its provenance,
      with absent, stale, no-provenance, and type-mismatch all yielding `unknown`.
- [ ] 3.3 Define the resolver behaviour/contract that a future input kind
      implements, and add a test proving a new kind needs no evaluator, storage,
      or rule-structure change.

## 4. Evaluation

- [ ] 4.1 Add `CompositeChecks.Evaluator.verdict/2` as a pure function returning
      `{verdict, status, matched_rule_id}`.
- [ ] 4.2 Add `CompositeChecks.EvaluationWorker`: resolve scope via the SRQL Ash
      adapter, page 1000 UIDs, one availability query and one metadata query per
      page, bulk upsert, diff against prior verdict.
- [ ] 4.3 Delete result rows for devices that no longer match the scope.
- [ ] 4.4 Schedule the worker per enabled check on its `evaluation_interval`, and
      reconcile schedules on check create/enable/disable/delete/interval change.
- [ ] 4.5 Add the debounced per-device refresh triggered by sweep result
      ingestion and by device fact writes.
- [ ] 4.6 Record verdict transition OCSF events under a system actor, logging
      and swallowing failures so they never fail the evaluation.
- [ ] 4.7 Add evaluation telemetry: pass duration, devices evaluated, verdict
      transition count, per-input unknown rate.
- [ ] 4.8 Retain and mark stale (never clear) existing results when a pass fails,
      and let Oban retry.

## 5. Coverage And Validation

- [ ] 5.1 Add per-vantage-point coverage computation over a check's scope.
- [ ] 5.2 Block enabling at zero coverage without explicit acknowledgement;
      surface partial coverage with counts.
- [ ] 5.3 Add the liveness witness validation for checks with two or more vantage
      points.
- [ ] 5.4 Add expectation-seeded rule generation, and the regeneration warning
      when rules were edited after generation.
- [ ] 5.5 Surface a configuration error on the check when an input references an
      agent or path that no longer resolves, without failing the pass.

## 6. External Fact Ingress

- [ ] 6.1 Add `PATCH /api/devices/:uid/metadata` in web-ng writing the plain
      value plus server-stamped provenance per key.
- [ ] 6.2 Enforce the write bounds: key pattern, scalar values only, per-device
      fact cap, reserved internal keys rejected, whole request rejected on any
      invalid fact.
- [ ] 6.3 Add the `devices.facts.write` permission to the RBAC catalog and gate
      the endpoint on it for both session and API token principals.
- [ ] 6.4 Document the NCO phase-1 integration: endpoint, auth, payload, and the
      `max_age` implication of provenance.

## 7. SRQL

- [ ] 7.1 Add `composite.<slug>` and `composite.<slug>.status` device field
      resolution in `rust/srql`, following the `tags.<key>` precedent.
- [ ] 7.2 Add the `composite_results` entity with check/verdict filters and
      per-status counts.
- [ ] 7.3 Add the Ash adapter side for both.
- [ ] 7.4 Extend `srql_catalog_controller.ex` so the visual builder offers
      composite fields and each check's authored verdict slugs as values.
- [ ] 7.5 Fail a query referencing an unknown composite slug with a named error
      rather than returning every device.

## 8. UI

- [ ] 8.1 Add the composite check index with state, scope size, and verdict
      rollup per check.
- [ ] 8.2 Add the builder shell with scope, vantage points, verdict table, and
      preview sections.
- [ ] 8.3 Wire the scope section to the existing SRQL visual builder with
      bidirectional round-trip and a device count.
- [ ] 8.4 Add the vantage point section with agent picker, expectation selector,
      and liveness-witness / isolation-probe labelling.
- [ ] 8.5 Add the editable verdict rule table with reordering and the protected
      catch-all row.
- [ ] 8.6 Add the live preview panel: sampled device, per-input breakdown with
      ages, resulting verdict, and rollup counts with the unreachable-population
      explanation.
- [ ] 8.7 Add the read-only scan configuration reference with a link to sweep
      administration.
- [ ] 8.8 Add the composite verdict section to device detail with the per-input
      breakdown and unknown reasons stated rather than blank.
- [ ] 8.9 Add the optional composite column and filter to the device list.
- [ ] 8.10 Add the `composite_checks` RBAC section (`view`, `manage`,
      `evaluate`) and enforce it in LiveView mount and every `handle_event`.

## 9. Northbound

- [ ] 9.1 Add composite check and value-form selection to Armis northbound
      configuration.
- [ ] 9.2 Emit the selected verdict or status per in-scope device, omitting
      devices with no result rather than sending a placeholder.
- [ ] 9.3 Display the selection in northbound run status.

## 10. Verification

- [ ] 10.1 Table-driven evaluator tests over the full input cross-product,
      including the six-row isolation table as a named fixture.
- [ ] 10.2 Property test: for any input combination exactly one rule matches.
- [ ] 10.3 Test that preview and periodic evaluation produce identical results
      for identical inputs.
- [ ] 10.4 End-to-end test with two agents reporting different availability for
      one device, following `sweep_results_flow_e2e_test.exs`.
- [ ] 10.5 Staleness test: a fact aging past `max_age` flips the verdict on the
      next periodic pass with no triggering event.
- [ ] 10.6 Scope-exit test: a device leaving scope loses its result row and drops
      out of the rollup.
- [ ] 10.7 Device merge test: verdicts survive a DIRE merge with exactly one row
      per check on the surviving UID.
- [ ] 10.8 Fact API tests: bounds enforcement, reserved keys, back-dating
      ignored, unauthorized rejected, unknown device rejected.
- [ ] 10.9 SRQL tests for verdict and status filters, the rollup entity, and the
      unknown-slug error.
- [ ] 10.10 LiveView tests for the three save-time validations and the scope
      round-trip.
- [ ] 10.11 Run DB-backed tests against the `srql-fixtures` scratch database.
- [ ] 10.12 Run `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
      and `--project elixir/web-ng --phoenix`, plus `cargo fmt` / `cargo clippy`
      on `rust/srql`.
- [ ] 10.13 Run `openspec validate add-composite-service-checks --strict`.
