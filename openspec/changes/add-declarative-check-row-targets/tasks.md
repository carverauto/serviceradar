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
      once with `max_targets + 1`, flatten each row, derive key and label,
      skip incomplete and duplicate keys, evaluate, and persist with target
      kind `row`.
- [ ] 3.2 `target_row` evaluator returning the target's row; add
      `{{target.row.*}}` and `{{target.label}}` to interpolation.
- [ ] 3.3 Record pass diagnostics on the check: truncated scope, rows skipped
      for incomplete or duplicate keys, scope query failure.
- [ ] 3.4 Do not prune on a truncated pass or after a failed scope query.
- [ ] 3.5 Tests with a stub SRQL runner and invented rows: one query per
      pass; three rows give three instances with the expected statuses; key
      stability across passes; incomplete and duplicate keys; truncation;
      scope failure leaves instances untouched; single-`payload` rows are
      flattened.

## 4. Departure

- [ ] 4.1 Before pruning in any fan-out mode, publish a `healthy` /
      `target_departed` transition for each departing instance whose status
      was `degraded`, `down` or `unknown`.
- [ ] 4.2 Tests: a departed `down` row, device and service target each
      publish one closing transition and are then pruned; a departed healthy
      target publishes nothing; the closing event matches the recovery clause
      of the rule `AlertRuleSync` builds, checked with the real `RuleMatcher`.

## 5. Events and alerts

- [ ] 5.1 Add `target_label` to the transition event's unmapped fields and use
      it in the event message when present.
- [ ] 5.2 Use the label in the alert title for row targets.
- [ ] 5.3 Test: two row targets going `down` in turn publish two events with
      different `target_key` and `target_label`, and the rule grouped by
      `check_slug` and `target_key` treats them as two groups.

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
