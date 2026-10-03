## 1. Freshness feasibility readiness

- [ ] 1.1 Resolve the sweep interval covering a vantage point's agent in
      `Readiness`, reusing the agent-to-sweep-group resolution the coverage
      report already uses. `SweepGroup.agent_id` is nullable and means "any
      agent in partition", so an agent is covered by every group assigned to it
      plus every unassigned group in its partition — there is no single group
      to read, and picking one would misstate the cadence.
- [ ] 1.2 Add a `:freshness_window_shorter_than_sweep` warning carrying both
      values, alongside the existing `:partial_coverage` warning. Warning, not
      blocking: the operator may be about to shorten the sweep interval.
- [ ] 1.3 Handle the multi-group case: an agent covered by groups of differing
      intervals is only dormant if the window is shorter than the *shortest*
      covering interval, since any one of them refreshes the row.
- [ ] 1.4 Render the warning in the builder's readiness panel next to the
      coverage warnings.
- [ ] 1.5 Tests: window shorter warns with both numbers; window longer does
      not; no covering group does not warn (zero-coverage blocking still
      applies); multiple groups compare against the shortest.

## 2. Dashboard generation

- [ ] 2.1 Add a generator that maps a check's authored verdicts to panel specs:
      one `:count` panel per verdict, one `:table` panel per terminal verdict,
      each with `srql_query` bound to `composite.<slug>:<verdict>` and
      `dataset_key` `devices`.
- [ ] 2.2 Mark generated panels in `DashboardPanel.metadata` with the check id
      and the verdict they came from. This is what makes regeneration able to
      distinguish its own panels from an operator's.
- [ ] 2.3 Implement idempotent regeneration: add panels for new verdicts,
      remove generated panels whose verdict no longer exists, leave unmarked
      panels untouched. `dashboard_ref` is a required 7-digit route reference
      and is not auto-assigned by `:create` — allocate one.
- [ ] 2.4 Add the publish action to the builder, gated on the same
      `composite_checks.manage` permission as the rest of the surface, and link
      to the dashboard once it exists.
- [ ] 2.5 Tests: generation creates a panel per verdict; regeneration adds,
      removes, and preserves as specified; the generated dashboard survives the
      check being disabled.

## 3. Coverage statement in the report

- [ ] 3.1 Add an evaluated-versus-inconclusive panel to the generated set,
      always present even when the inconclusive count is zero — its absence is
      exactly the ambiguity this requirement exists to remove.
- [ ] 3.2 Tests: a scope with unevaluated devices states the count; a fully
      evaluated scope states zero rather than omitting the panel.

## 4. Report scheduling

- [ ] 4.1 Add the schedule action on the check surface, creating a
      `DashboardReportSchedule` bound to the generated dashboard. Reuse the
      existing scanner and delivery jobs; do not add a second delivery path.
- [ ] 4.2 Refuse scheduling when the check has no generated dashboard, with a
      message that says to generate one first.
- [ ] 4.3 Surface the check's existing schedules and their last delivery from
      the builder, reading `DashboardReportDelivery`.
- [ ] 4.4 Tests: scheduling persists a schedule bound to the dashboard;
      scheduling without a dashboard is refused.

## 5. Documentation

- [ ] 5.1 Document the publish flow in the composite checks operator
      documentation, including that the freshness window must exceed the sweep
      interval for a check to hold a verdict continuously.
