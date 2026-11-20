## 1. Schema and validation

- [ ] 1.1 Accept `target_binding.mode: "srql_rows"` with `scope_query`,
      `key_fields`, `label_template` and `max_targets` in
      `DeclarativeChecks.SchemaValidator`; refuse a missing or empty
      `key_fields`, a missing `scope_query`, a scope query with template
      placeholders, and `max_targets` outside 1..1000.
- [ ] 1.2 Add the `target_row` node kind; refuse it outside an `srql_rows`
      check, and refuse edge signal nodes and credential slots inside one.
- [ ] 1.3 Mirror 1.1 and 1.2 in `js/cli/src/pack/validate.ts`.
- [ ] 1.4 Unit tests for each refusal and for an accepted document, in core
      and in the CLI.

## 2. Storage

- [ ] 2.1 Migration on `platform.declarative_check_instances`: allow
      `target_kind = 'row'` in the check constraint and add a nullable
      `target_label` column. Refresh the baseline per the repository's
      migration procedure.
- [ ] 2.2 Add `target_label` to `DeclarativeCheckInstance` and accept
      `:row` as a target kind.

## 3. Evaluation

- [ ] 3.1 `Evaluation.run_for_mode("srql_rows", ...)`: run the scope query
      once with limit `max_targets` (at most 1000), treat the scope as
      complete only when the page has fewer rows than the limit that
      actually ran (never by the absence of `next_cursor`), flatten each
      row, derive key and label, skip incomplete and duplicate keys,
      evaluate, and persist with target kind `row`.
- [ ] 3.2 `target_row` evaluator returning the target's row; add
      `{{target.row.*}}` and `{{target.label}}` to interpolation.
- [ ] 3.3 Record pass diagnostics on the check: truncated scope, rows skipped
      for incomplete or duplicate keys, scope query failure, targets whose
      graph evaluation failed.
- [ ] 3.4 Do not prune on a truncated pass or after a failed scope query.
- [ ] 3.5 Tests with a stub SRQL runner and invented rows: one query per
      pass; three rows give three instances with the expected statuses; key
      stability across passes; incomplete and duplicate keys; truncation,
      including a full page returned under a limit clamped below
      `max_targets`, and a full page returned with no `next_cursor`, both of
      which prune and close nothing;
      scope failure leaves instances untouched; single-`payload` rows are
      flattened.

## 4. Departure

- [ ] 4.1 In every fan-out mode, compute departed keys as existing instance
      keys minus the keys of a complete, successful, non-truncated scope read,
      replacing the `evaluated_at < started_at` test in
      `Evaluation.prune_departed_targets`. An SRQL scope read (`srql_rows`,
      the `srql_devices` stream) is complete only when its last page has
      fewer rows than the limit that ran; a device stream whose last page is
      full is truncated even without a `next_cursor`, and prunes and closes
      nothing. A successful `service_targets` resolution is always complete;
      its 1000-id chunking is batching, not a limit.
- [ ] 4.2 Before pruning, publish a `healthy` / `target_departed` transition
      for each departed instance whose status was `degraded`, `down` or
      `unknown`, passing the publisher a suppression predicate that returns
      false for this transition only, and setting the verdict
      `target_departed` and the boolean `target_departed: true`; add the
      marker to `VerdictEventWriter`'s `unmapped` allowlist next to
      `to_status` and `to_verdict` so it is on the stored event.
      Other transitions keep the default predicate.
- [ ] 4.3 A target in scope whose graph evaluation fails keeps its instance
      and status, publishes nothing, is not pruned, and is counted in the
      pass diagnostics (3.3).
- [ ] 4.4 Tests: a departed `down` row, device and service target each
      publish one closing transition and are then pruned; a departed healthy
      target publishes nothing; the stored closing event carries
      `target_departed: true` in `unmapped` (asserted on the stored row, not
      the published struct).
- [ ] 4.5 Test: an `srql_devices` target at `down` whose evaluation returns
      an error while it is still in scope keeps its instance and status,
      publishes no transition and is reported as a diagnostic; the same for a
      row target.
- [ ] 4.6 Test: a `down` device target that leaves the scope after being
      marked out of service publishes its `target_departed` transition through
      the real publisher (not suppressed), while an ordinary transition for an
      out-of-service device is still suppressed.
- [ ] 4.7 In the alert engine's event state machine
      (`StatefulAlertEngine.StateMachine`), treat an event carrying
      `target_departed: true` as a recovery for the matching rule and skip the
      rule's open clause for it.
- [ ] 4.8 Test through the engine's event path (not only `RuleMatcher`): with
      a rule whose `open_on_statuses` is `["down", "healthy"]` and an open
      alert for a target, the stored event `VerdictEventWriter` produced for a
      departure (marker in `unmapped`) closes that alert and opens or
      renotifies none; the same event with no open alert changes nothing.
- [ ] 4.9 Test: a `service_targets` check bound to exactly 1000 service
      targets, one removed and one added, prunes the removed one and publishes
      its closing transition.
- [ ] 4.10 A `service_targets` binding with `selector_query` and no
      `target_ids` is not a successful resolution: evaluate nothing, prune
      nothing, publish nothing, and record a "selector not evaluated" pass
      diagnostic. Validation keeps accepting the binding.
- [ ] 4.11 Test: a `service_targets` check with a `down` instance and an open
      alert, rebound to `selector_query` only, keeps the instance and alert,
      publishes nothing and reports the diagnostic.

## 5. Events and alerts

- [ ] 5.1 Add `target_label` to the transition event's unmapped fields and use
      it in the event message when present.
- [ ] 5.2 Put the label in the alert title for row targets in
      `AlertRuleSync` / the alert engine, so the stored title contains
      `target_label`.
- [ ] 5.3 Test: two row targets going `down` in turn publish two events with
      different `target_key` and `target_label`, and the rule grouped by
      `check_slug` and `target_key` treats them as two groups whose stored
      alert titles contain their respective labels.

## 6. Surfaces

- [ ] 6.1 Import, export and canonical JSON round-trip an `srql_rows` check.
- [ ] 6.2 SRQL `in:declarative_check_results`: return `target_label`, accept
      `target_kind:row`, and filter by `target_label`.
- [ ] 6.3 OpenAPI document for the declarative check API.
- [ ] 6.4 Check editor in web-ng: choose the row mode, edit scope query, key
      fields, label template and bound; Test Run previews the first rows with
      their keys, labels and verdicts; the results view shows the label.
- [ ] 6.5 Show pass diagnostics (truncated, skipped rows, scope failure) on
      the check's page.

## 7. Documentation

- [ ] 7.1 Document the mode, the `target_row` node, choosing stable key
      fields, the bound, and pairing a row check with a singleton freshness
      check because an empty scope produces no verdict.
- [ ] 7.2 Document the departure transition and its `target_departed` verdict.

## Follow-up changes, not part of this one

- Proxmox Monitoring pack: move the datastore capacity and paused guest checks
  to `srql_rows`.
- Revise `add-proxmox-host-outage-alerting` to drop its paused-guest and
  node-storage condition requirements.
- Implement `selector_query` resolution for `service_targets` bindings.
