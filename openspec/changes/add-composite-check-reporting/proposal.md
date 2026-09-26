# Change: Publish composite check verdicts as dashboards and scheduled reports

## Why

A composite check answers a question someone outside the product asked: *prove
these devices are isolated*. Today the answer is only visible to an operator
who opens the builder and runs a preview. The people who need it — a security
lead, an auditor, whoever signed the control — have no way to receive it.

The machinery to deliver it already exists. `dashboard-creator` specifies
authored SRQL dashboards, report schedules, delivery history, and bounded
scheduling jobs, and the SRQL `composite.<slug>` field already resolves a
device population by verdict. What is missing is the wiring: nothing turns a
check into either surface, so an operator has to hand-author six panels of
SRQL and keep them in step with the check's verdicts by hand. Verified by
doing exactly that on a lab deployment — the panels are mechanical, which is
the argument for generating them.

Both surfaces are wanted, and they are not the same artifact. A dashboard is
pulled, interactive, and current. A report is pushed, periodic, and is the
thing that gets forwarded and archived as evidence.

This proposal also closes a defect that reporting makes dangerous. A vantage
point's freshness window is authored independently of the sweep interval that
feeds it, and nothing checks the two against each other. On a lab deployment
the sweeps ran hourly against a 900-second window, so every reachability
signal was stale for 45 minutes in every 60 and readiness reported **0 of 110**
devices covered. Widening the window to 5400s took it to **110 of 111** with no
other change.

Today that silently produces a check that never reaches a verdict. Once the
same check is emailed to an auditor, it produces something worse: a report
stating zero non-compliant devices, which reads as *we checked and found
nothing* when it means *we never checked*. A report that cannot distinguish
those two is not evidence.

## What Changes

- Add a **publish** action to the composite check builder that generates an
  authored dashboard from the check: verdict rollup counts, a per-verdict
  device table, and the unreachable-population note, all as SRQL panels bound
  to `composite.<slug>`.
- Add a **report schedule** action on the same surface, reusing
  `dashboard-creator`'s existing schedule, delivery, and outbound mail
  machinery rather than introducing a second delivery path.
- Regenerating after the check's verdicts change SHALL update the generated
  panels in place, and SHALL NOT discard panels an operator added by hand.
- Add a **freshness feasibility** readiness check: warn when a vantage point's
  `max_age_seconds` is shorter than the interval of the sweep groups covering
  that agent, naming both numbers.
- A generated report SHALL state its evaluation coverage — how many devices in
  scope produced a verdict versus `inconclusive` — so an empty result is never
  mistaken for a clean result.

## Impact

- Affected specs: `composite-checks`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/composite_checks_live/` —
    publish actions on the builder
  - `elixir/serviceradar_core/lib/serviceradar/composite_checks/readiness.ex` —
    freshness feasibility warning
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/` — consumed as-is
    (`AuthoredDashboard`, `DashboardPanel`, `DashboardReportSchedule`)
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/` — read-only, to
    resolve the sweep interval covering an agent
- No new external dependencies, no schema changes to the dashboards tables.
