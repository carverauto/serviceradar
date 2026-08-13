# Composite Checks Builder UI Implementation Plan (Plan 3 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make composite checks authorable and their verdicts visible — an index with per-check rollups, a builder with scope/vantage points/verdict table/live preview, and verdict surfacing on device detail and the device list.

**Architecture:** One Phoenix LiveView under Settings, split the way `visibility_profiles_live` is (index / components / form_state / scope_builder), because that feature already solves the SRQL visual-builder round-trip this spec requires reusing. The preview calls `ServiceRadar.CompositeChecks.Evaluation.evaluate_devices/5` directly — the same function the scheduled pass and the refresh worker call — so a preview cannot disagree with a persisted evaluation.

**Tech Stack:** Phoenix LiveView, HEEx, Ash, the existing `SRQL.Builder` / `QueryBuilderComponents` / `target_builder` round-trip.

**Depends on:** Plan 1 (PR #4962) for the resources, evaluator, readiness, and coverage. Plan 2 (PR #4965) for `composite.<slug>` device filtering, which task 9 uses for the device-list filter.

**Spec:** `openspec/changes/add-composite-service-checks/specs/build-web-ui/spec.md`, tasks 8.1–8.10.

## Global Constraints

- **Iron laws (AGENTS.md):** no database queries in disconnected mount; use streams for lists over 100 items; check `connected?/1` before PubSub subscribe; authorize in every `handle_event`; never `String.to_atom/1` on user input; never `raw/1` with untrusted content.
- **Follow `elixir/web-ng/AGENTS.md`** — it governs everything under `elixir/web-ng/**` and is more specific than the repo root guide. Read it before writing HEEx.
- **RBAC is already in the catalog.** Plan 1 added `composite_checks.view` / `.manage` / `.evaluate` (`identity/rbac/catalog.ex`). This plan enforces them; it does not re-add them. Gate `mount` on `.view`, every mutating `handle_event` on `.manage`, and preview on `.evaluate`.
- **Verdict slugs are operator-authored strings.** Never `String.to_atom` them, never interpolate them into HEEx without escaping. `status` is the fixed enum and is the only one safe to key styling on.
- **The evaluator is shared, not reimplemented.** The preview must call `Evaluation.evaluate_devices/5`. Any verdict logic written in the LiveView is a bug: it can drift from what the worker persists, which is the exact property Plan 1 was built to guarantee.
- **Draft rollups are sampled and must say so.** `specs/composite-checks/spec.md` requires preview counts be labelled with sampled-vs-total; enabled-check rollups read persisted results and cover the full scope. Presenting a sample as the full scope is a spec violation, not a cosmetic one.
- **`mix format` and `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`** before every commit.

## Decisions

### D1 — A vantage point has no single "scan profile"; task 8.7 is amended

**The spec assumes something the data model does not provide.**

`specs/build-web-ui/spec.md` requires the builder show "the sweep configuration that produces its vantage point signals" and "the profile's probes and ports". That wording comes from the original mock, where the composite owned the scan profile.

Under the derivation-only design that Plan 1 implemented, a vantage point is only an `agent_id`. Mapping it back to a sweep profile is one-to-many and ambiguous: `SweepGroup.agent_id` is nullable and documented as *"nil = any agent in partition"* (`sweep_jobs/sweep_group.ex:30`), so an agent is fed by every group explicitly assigned to it **plus** every unassigned group in its partition. There is no single profile to display, and picking one arbitrarily would misinform the operator about which ports are actually probed.

So: show **every** sweep group that could feed the agent, each with its profile's probes and ports, and say plainly when there are none — that case is exactly the zero-coverage problem the readiness gate already blocks on, and naming it here tells the operator what to go fix. Link each to sweep administration. Task 8 implements it and amends the spec delta.

*Alternative considered:* omitting the panel entirely. Rejected — the operator needs to know what "available" actually means for this check, and "no sweep group covers this agent" is the single most useful thing the panel can say.

### D2 — Preview shares the evaluator; the LiveView holds no verdict logic

`Evaluation.evaluate_devices/5` resolves inputs and evaluates without persisting, and takes `now:` so the preview is reproducible. The LiveView passes unsaved form state through `RuleGenerator`/the rule structs and renders what comes back. This is the whole reason that function exists.

### D3 — File layout mirrors `visibility_profiles_live`

That feature is the closest analog (settings CRUD + SRQL scope + preview) and already solves the round-trip. Matching its split keeps each file focused: `index.ex` (LiveView + events), `components.ex` (HEEx), `form_state.ex` (params ↔ form), `scope_builder.ex` (SRQL round-trip). Expect this feature to be larger — it adds vantage points, a rule table, and a preview — so split further if any file passes ~600 lines, which is roughly where `components.ex` sits there.

### D4 — Rollup source differs by state, deliberately

Enabled checks read persisted `DeviceCompositeCheckResult` rows: cheap, full scope, already computed by the worker. Draft checks have no rows, so the index shows scope size and "not yet evaluated" rather than a fake rollup, and the builder's preview computes a labelled sample. Showing a draft a rollup it has not earned is how an operator ends up trusting a number nobody computed.

## File Structure

**New**
- `live/settings/composite_checks_live/index.ex` — index + builder LiveView, mount/params/events.
- `live/settings/composite_checks_live/components.ex` — HEEx for index rows, scope panel, vantage points, rule table, preview.
- `live/settings/composite_checks_live/form_state.ex` — params ↔ form struct, rule row normalization.
- `live/settings/composite_checks_live/scope_builder.ex` — SRQL round-trip, copied in shape from `visibility_profiles_live/target_builder.ex`.
- `live/settings/composite_checks_live/preview.ex` — assembles preview data by calling `Evaluation.evaluate_devices/5` and `Coverage.for_check/3`.
- `live/settings/composite_checks_live/sweep_context.ex` — resolves the sweep groups that could feed a vantage point (D1).

**Modified**
- `settings/catalog.ex` — nav entry, gated on `composite_checks.view`.
- `router.ex` — index / `:new` / `:edit` live routes beside the other settings routes.
- `live/device_live/availability_data.ex` + `availability_components.ex` — verdict section on device detail, beside the per-agent availability it explains.
- `live/device_live/index_data.ex` + `index_view.ex` — optional verdict column and filter on the device list.

---

### Task 1: Route, nav entry, and an empty index gated on RBAC

**Files:**
- Create: `live/settings/composite_checks_live/index.ex`
- Modify: `settings/catalog.ex`, `router.ex`
- Test: `test/phoenix/live/settings/composite_checks_live_test.exs`

**Interfaces:**
- Produces `ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Index` mounted at `/settings/composite-checks`, with `:index`, `:new`, and `:edit` live actions.

**Why this is its own task:** it establishes the RBAC gate and the nav registration, which every later task depends on and which a reviewer can accept independently of any composite behaviour.

- [x] **Step 1: Read the analog end to end**

```bash
sed -n '1,60p' elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/index.ex
sed -n '644,665p' elixir/web-ng/lib/serviceradar_web_ng_web/settings/catalog.ex
grep -n "visibility-profiles" elixir/web-ng/lib/serviceradar_web_ng_web/router.ex
```

Note the mount shape: `RBAC.can?(scope, permission)` guarded, `current_path` assigned for the settings shell, and a redirect otherwise. Match it.

- [x] **Step 2: Write the failing test**

```elixir
defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AshTestHelpers.user_fixture(%{role: :operator})
    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders the index for a permitted operator", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/settings/composite-checks")
    assert html =~ "Composite Checks"
  end

  test "redirects a user without composite_checks.view", %{conn: conn, user: user} do
    conn = assign(conn, :current_scope, Scope.for_user(user, permissions: MapSet.new()))
    assert {:error, {:redirect, _}} = live(conn, ~p"/settings/composite-checks")
  end
end
```

Confirm the login helper name first — `rg -n "def log_in_user|def log_in_api_user" elixir/web-ng/test/support/conn_case.ex`.

- [x] **Step 3: Run and watch it fail**

Run: `bash <scratchpad>/run-webng.sh cc-live test test/phoenix/live/settings/composite_checks_live_test.exs`
Expected: FAIL — no route.

- [x] **Step 4: Add the routes**

Beside the visibility-profiles routes in `router.ex`:

```elixir
      live("/settings/composite-checks", Settings.CompositeChecksLive.Index, :index)
      live("/settings/composite-checks/new", Settings.CompositeChecksLive.Index, :new)
      live("/settings/composite-checks/:id/edit", Settings.CompositeChecksLive.Index, :edit)
```

- [x] **Step 5: Add the nav entry**

In `settings/catalog.ex`, mirroring the visibility-profiles entry. Site it near Networks — composite checks consume the sweeps authored there. Use `permission: "composite_checks.view"`, an icon from the existing `hero-*` set, and keywords `["composite", "isolation", "verdict", "segmentation"]`.

- [x] **Step 6: Implement the mount**

Gate on `composite_checks.view`, assign `page_title`, `current_path`, `checks` (empty list for now), and the two capability flags `can_manage` / `can_evaluate` from `composite_checks.manage` / `.evaluate`. Assign capabilities in mount rather than checking inline in templates, matching the analog.

- [x] **Step 7: Run, format, commit**

```bash
cd elixir/web-ng && mix format
git add elixir/web-ng/lib elixir/web-ng/test
git commit -m "feat(web-ng): add the composite checks settings route and RBAC gate"
```

---

### Task 2: Index list with per-check rollups

**Files:**
- Modify: `index.ex`; Create: `components.ex`
- Test: same test file

**Interfaces:** Produces `load_checks/1` returning `[%{check: check, scope_count: integer | nil, rollup: [%{verdict:, status:, count:}]}]`.

**Spec:** "each check SHALL show its name, state, device count in scope, and a breakdown of devices per verdict"; "the counts per verdict SHALL sum to the number of devices with result rows".

Per D4, a draft check has no rows — show its scope count and "not yet evaluated", not a zero rollup that looks like a real answer.

- [x] **Step 1: Write the failing tests**

Cover: an enabled check with results renders its verdict counts; a draft check renders "not yet evaluated" rather than a rollup; counts sum to the number of result rows.

- [x] **Step 2: Implement the rollup query**

Group `DeviceCompositeCheckResult` by verdict and status for each check id. One grouped query for all checks, not one per check — the index is a list page and N+1 here is a real cost as check count grows.

- [x] **Step 3: Implement the scope count**

Reuse the SRQL stats approach from `visibility_profiles_live/index.ex:393-409` (`stats:"count() as total"`). It already handles the `in:`-prefixed and bare-filter cases.

- [x] **Step 4: Render**

Name, state badge, scope count, and a proportional bar of verdict counts coloured by `status` (never by verdict slug — those are operator-defined).

- [x] **Step 5: Run, format, commit**

---

### Task 3: Scope panel with the SRQL round-trip

**Files:** Create `scope_builder.ex`; modify `index.ex`, `components.ex`
**Spec:** "SHALL reuse the existing SRQL visual query builder so that the raw SRQL string and the visual filter rows edit the same state in either direction"; an unparseable query "SHALL leave the raw string authoritative and warn".

- [x] **Step 1: Read the existing round-trip**

Run: `cat elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/target_builder.ex`

It returns `{builder_state, in_sync?}` from `parse_target_query_to_builder/1`, and the LiveView only overwrites builder state when `in_sync?` is true — that is precisely the "raw string stays authoritative" behaviour the spec asks for. Copy the shape; do not reimplement SRQL parsing.

- [x] **Step 2–5:** failing tests (visual edit updates raw; raw edit updates visual; unparseable raw warns and leaves visual untouched; device count updates), implement, run, commit.

---

### Task 4: Vantage points with expectations and witness labelling

**Files:** modify `form_state.ex`, `components.ex`, `index.ex`
**Spec:** "SHALL be recorded with that expectation AND SHALL be labelled as the liveness witness".

- [x] **Step 1: Load selectable agents**

Find the existing agent picker source — `rg -n "list_online_agents|Infrastructure.Agent" elixir/web-ng/lib --glob '*.ex' | head`. Reuse it rather than querying agents ad hoc.

Done: `Agent |> Ash.Query.for_read(:read, ...)`, deliberately every agent rather
than only connected ones. A vantage point is durable configuration; an agent
that is temporarily down must stay selected and resolve `unknown`.

- [x] **Step 2: Write failing tests**

Adding a vantage point with `expected: "available"` labels it liveness witness; `expected: "blocked"` labels it isolation probe; removing the only witness surfaces the readiness warning (the gate itself is Plan 1's and is asserted at enable time in Task 7).

- [x] **Step 3–5:** implement add/remove/change-expectation events (each authorized on `composite_checks.manage`), render the badges, run, commit.

**What the tests pinned down beyond the plan:**

- A new row defaults to `blocked`, not `available`. Defaulting to available
  would make adding a second vantage point silently produce two witnesses.
- The witness warning only fires once there is more than one row. One row is a
  half-built check, not a broken one — the real gate is at enable time.
- The input `key` is the agent id, which is what makes `unique_key_per_check`
  enforce one vantage point per agent and what rule match maps address.
- Save replaces the vantage point inputs rather than diffing them. Rules
  reference inputs by key, so recreating an input with the same key leaves the
  rule table intact.
- The viewer case is already covered by the route guard: a viewer is
  live-redirected away from `/new` entirely, so there is no vantage-point-
  specific viewer assertion to make.

---

### Task 5: The editable verdict rule table

**Files:** modify `form_state.ex`, `components.ex`, `index.ex`
**Spec:** "the edited rule SHALL be persisted AND SHALL be used for evaluation in place of the generated value".

**The two invariants Plan 1 enforces server-side, which this UI must not fight:** the catch-all cannot be reordered, rematched, or deleted (policy-enforced, returns `Ash.Error.Forbidden`), and a non-catch-all rule must constrain at least one input (check constraint). Render the catch-all row without reorder/delete affordances and with only its label editable, so the UI never offers an action the server will refuse.

- [x] **Step 1: Write failing tests**

Generating from expectations produces the isolation rows; editing a verdict label persists; the catch-all row renders without delete/reorder controls; regenerating warns before discarding edits.

- [x] **Step 2: Wire generation**

Call `RuleGenerator.generate/1` with the current inputs. It returns rule attrs with positions; the catch-all already exists from check creation and must not be duplicated.

- [x] **Step 3–5:** implement edit/reorder/delete events, the regeneration confirmation, run, commit.

**What the implementation settled beyond the plan:**

- The table lives outside `#composite-check-form`, and each row is its own
  `<form phx-change="update_rule">`. A form nested in a form is invalid HTML —
  the browser drops the inner one and the row silently stops submitting. That
  ruled out a `<table>` too (`<form>` is not valid inside `<tr>`), so the rows
  are a CSS grid with a runtime-built `grid-template-columns`.
- Columns come from the check's *persisted* inputs, not the unsaved vantage
  point rows. A column for an input that does not exist yet produces a rule that
  can never match. A new check therefore says so instead of rendering an empty
  table.
- "Any" is stored as an absent key, matching what the generator writes, rather
  than the wildcard `"*"` — one representation for one meaning.
- A cell holding a list of literals has no single-select representation. It
  renders as "any" but is carried through untouched unless the operator picks a
  value, so editing a status cannot silently widen a hand-written match.
- Setting every cell to "any" is *not* prevented in the form. The database check
  constraint rejects it with the message the operator needs to read; duplicating
  that rule client-side would let the two drift.
- Rule edits persist immediately rather than batching into the check's Save. The
  rules are their own resource with their own policies, and the catch-all takes
  `:relabel` while authored rules take `:update` — the action is chosen from the
  rule, not from the form, because `:update` on the catch-all returns Forbidden.
- `Ash.destroy/2` returns a bare `:ok`, not `{:ok, record}`. Matching only the
  tuple crashed the delete handler; the test caught it.

---

### Task 6: Live preview

**Files:** Create `preview.ex`; modify `index.ex`, `components.ex`
**Spec:** per-vantage-point outcome, each fact's value and age, verdict and explanation, rollup counts, the unreachable-population sentence, and draft rollups labelled sampled-vs-total.

- [x] **Step 1: Write failing tests**

A sampled device renders each input's resolved value and age; an input with no result renders "unknown" with its reason rather than blank; the rollup states how many devices no vantage point can see; a draft rollup shows sampled-of-total.

- [x] **Step 2: Implement via the shared evaluator**

```elixir
{:ok, rows} = Evaluation.evaluate_devices(check, inputs, rules, uids, now: now)
```

Take `uids` from `Scope.stream_uids/2` bounded to a sample (start at 25, matching the preview limit `AvailabilitySourceProfileMaterializer` uses). Nothing persists and no events emit — `evaluate_devices/5` writes nothing by construction.

- [x] **Step 3: Render the explanation**

The verdict's `verdict_description` is the explanation; the unreachable count comes from rows whose inputs are all non-`available`. State it in the words the spec uses: these devices cannot be counted as compliant.

- [x] **Step 4: Authorize**

Preview is `composite_checks.evaluate`. It is the one read-ish action that costs real query work, which is why it has its own permission.

**What the implementation settled beyond the plan:**

- `total` is passed in rather than counted. The builder already renders the
  scope size beside the SRQL; counting again would walk the whole population to
  display a number already on screen.
- The preview runs against the *saved* check, not the form state. Previewing
  unsaved edits would show a verdict the scheduled pass cannot reproduce, which
  is the one thing a preview must never do. A new check says so instead.
- `Scope.stream_uids/2` raises on a runner error, which is correct for the
  evaluation pass — a partial pass must not sweep. Preview has nothing to
  corrupt, so it rescues and turns the failure into a message.
- Ages are measured against the evaluation's own `now`, not the wall clock, so
  the rendered age and the resolver's staleness verdict cannot disagree. That is
  why this does not reuse `format_relative_time/1` from the scans components.
- A check with no vantage points has *no* unreachable population, rather than
  every device being trivially unreachable.
- The rows carry `data-preview-*` attributes. Every value the panel renders —
  verdicts, expectations, statuses — also appears in the rule table and the
  vantage point selects above it, so assertions on visible text alone passed
  with the panel entirely empty. Caught by re-reading the first green run.
- The `!can_evaluate` branch is unreachable with the default catalog:
  `composite_checks.manage` and `composite_checks.evaluate` both default to
  `@operator_roles`, so no default role can reach the builder without evaluate.
  The branch stays because permissions are customizable per deployment.

- [ ] **Step 5–6:** run, commit.

---

### Task 7: Validation feedback at save and enable

**Files:** modify `index.ex`, `components.ex`
**Spec:** missing witness blocks enabling and is explained; coverage gap reported with counts; zero coverage requires acknowledgement.

Plan 1 enforces all three server-side (`Readiness`, `EnforceReadiness`, and the `:enable` action). This task surfaces them; it must not duplicate the logic.

- [ ] **Step 1: Write failing tests**

Enabling a witness-less check shows the "powered-off device is indistinguishable" explanation and does not enable; a partial-coverage check shows "N of M"; a zero-coverage check requires ticking the acknowledgement before enable succeeds.

- [ ] **Step 2: Call `Readiness.check/2` on the builder**

Render `blocking` and `warnings` in place. The acknowledgement checkbox maps to the `acknowledge_coverage_gap` argument on `:enable`.

- [ ] **Step 3: Map the enable error**

`:enable` returns an `Ash.Error.Invalid` whose message is the problem text. Surface it rather than a generic "could not save".

- [ ] **Step 4–5:** run, commit.

---

### Task 8: Sweep context panel (D1)

**Files:** Create `sweep_context.ex`; modify `components.ex`; modify `specs/build-web-ui/spec.md`
**Spec (amended):** show every sweep group that could feed each vantage point, with its profile's probes and ports, read-only, linking to sweep administration; say plainly when none exist.

- [ ] **Step 1: Amend the spec delta first**

Replace the "Scan profile shown read-only" scenario with one that matches the data model:

```markdown
#### Scenario: Sweep coverage shown read-only

- **WHEN** an operator views a check whose vantage point is fed by one or more
  sweep groups
- **THEN** each group's probes and ports SHALL be displayed as context
- **AND** editing them SHALL navigate to the sweep administration UI

#### Scenario: A vantage point with no sweep coverage is named

- **GIVEN** a vantage point whose agent is covered by no sweep group
- **WHEN** the builder renders sweep context
- **THEN** it SHALL state that no sweep group covers that agent
```

Add a note recording why: `SweepGroup.agent_id` is nullable and means "any agent in partition", so a vantage point maps to zero or more groups rather than one profile.

Run: `openspec validate add-composite-service-checks --strict`

- [ ] **Step 2: Implement the resolver**

`SweepGroup` has a `by_agent` read (`sweep_jobs/sweep_group.ex:165-175`) whose filter is `agent_id == ^arg or is_nil(agent_id)` — exactly the "explicitly assigned plus partition-wide" set. Use it, then load each group's profile for ports and modes.

- [ ] **Step 3–5:** failing tests (one group renders its ports; several groups all render; no groups renders the named gap), implement, run, commit.

---

### Task 9: Device detail and device list surfacing

**Files:** modify `live/device_live/availability_data.ex`, `availability_components.ex`, `index_data.ex`, `index_view.ex`
**Spec:** verdict + per-input breakdown on detail with unknown reasons stated not blank; optional verdict column and filter on the list.

- [ ] **Step 1: Read the per-agent availability section**

That section answers the same shape of question and sits where the verdict belongs — directly beside the vantage-point data that produced it.

- [ ] **Step 2: Write failing tests**

Detail shows verdict and status for a device in an enabled check's scope; an input with no result shows "unknown" and its reason, not blank or raw JSON; the list filters by verdict.

- [ ] **Step 3: Implement detail**

Load `DeviceCompositeCheckResult.list_by_device/2`, render verdict, status, and the `inputs` snapshot — each input's value, observation age, and `reason` when unknown. Link to the check.

- [ ] **Step 4: Implement the list filter**

Use Plan 2's `composite.<slug>` SRQL field rather than a bespoke query, so the list filter and the query language agree.

- [ ] **Step 5–6:** run, commit.

---

### Task 10: Verification

- [ ] **Step 1:** `bash <scratchpad>/run-webng.sh ui test test/phoenix/live/settings/composite_checks_live_test.exs test/phoenix/live/device_live_test.exs`
- [ ] **Step 2:** `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix --skip-dialyzer`
- [ ] **Step 3:** Visual verification with the `local web-ng + Playwright` loop — author a check, add two vantage points, generate rules, run the preview, screenshot at 1680×945 and 390×844, and **read the PNGs**. A LiveView test asserting on HTML does not tell you the rule table is legible.
- [ ] **Step 4:** `openspec validate add-composite-service-checks --strict`
- [ ] **Step 5:** Update `openspec/changes/add-composite-service-checks/tasks.md` section 8 to `- [x]`.

## Plan Self-Review

**Spec coverage:**

| Requirement | Task |
|---|---|
| Composite Check Index | 2 |
| Composite Check Builder | 3, 4, 5 |
| Composite Check Live Preview | 6 |
| Composite Check Authoring Validation Feedback | 7 |
| Scan Configuration Is Referenced, Not Edited | 8 (amended per D1) |
| Device Composite Verdict Surfacing | 9 |
| tasks.md 8.10 (RBAC enforcement) | 1, and every mutating event thereafter |

**Placeholder scan:** Tasks 2–9 name their tests and their implementation approach but do not embed full HEEx. That is deliberate and is the one place this plan differs from Plans 1 and 2: the markup depends on `elixir/web-ng/AGENTS.md` conventions and the existing component library, which the implementer must read first. Every task names the file to read and the assertion to make. If that proves too loose in execution, the fix is to expand Task 2's components inline and let the rest follow its pattern.

**Type consistency:** `load_checks/1`'s shape (Task 2) is consumed by the index render; `Preview` (Task 6) returns rows in `Evaluation.evaluate_devices/5`'s shape, whose `inputs` snapshot keys (`value`, `observed_at`, `stale`, `reason`) are the ones Task 9 renders on device detail.

**Known risk:** this is the largest of the four plans and the only one where correctness is partly visual. Task 10 Step 3 is not optional — the rule table and preview panel are dense, and HTML assertions will pass on a layout no operator can read.
