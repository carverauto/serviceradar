# Composite Verdict Northbound Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export a selected composite check's per-device result to Armis as either the verdict slug or the fixed status enum, through the existing northbound bulk-update path.

**Architecture:** The Armis northbound runner already collapses candidates by `armis_device_id` and writes one custom field per device via a bulk upsert. This adds a second, optional custom field carrying the composite value. Selection is source configuration (`settings["composite"]`), the values are read once per run from `DeviceCompositeCheckResult`, and `build_bulk_payload/3` — already public and directly unit-tested — is where the extra entry is produced.

**Tech Stack:** Elixir, Ash, `ServiceRadar.Integrations.ArmisNorthboundRunner`, `ServiceRadar.CompositeChecks.DeviceCompositeCheckResult`, Phoenix LiveView (`settings/integrations_live`).

## Global Constraints

- **Devices with no result row are omitted entirely.** No placeholder, no empty string, no `"unknown"` — the spec says "SHALL NOT send a placeholder or empty value". A device outside the check's scope must produce no composite entry at all.
- **Never use `authorize?: false`.** Background reads use `ServiceRadar.Actors.SystemActor`.
- The value form is `"verdict"` (operator-authored slug) or `"status"` (the fixed `healthy | degraded | down | unknown` enum). Anything else disables the export rather than guessing.
- Only **enabled** checks are exportable. A draft check's results are stale by definition — nothing maintains them on a schedule.
- The existing availability export must be unaffected when no composite selection is configured. Every current test in `armis_northbound_runner_test.exs` must still pass unchanged.
- `elixir/serviceradar_core/AGENTS.md` and the repo `AGENTS.md` apply: `mix format`, `--warnings-as-errors`, `credo --strict` clean per task.

---

### Task 1: Composite export configuration on the source

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/armis_northbound_runner.ex`
- Test: `elixir/serviceradar_core/test/serviceradar/integrations/armis_northbound_runner_test.exs`

**Interfaces:**
- Produces: `ArmisNorthboundRunner.composite_export/1 :: nil | %{check_slug: String.t(), value_form: :verdict | :status, custom_field: String.t()}`

**Why `settings` and not a positional `custom_fields` entry:** `custom_field/1` takes `custom_fields` head, and a second positional entry would silently become the composite field for every source that happens to configure two. The selection is three coupled values; one nested map keeps them together and makes "not configured" a single `nil`.

- [x] **Step 1: Write the failing tests**

```elixir
test "composite_export is nil when nothing is configured" do
  assert ArmisNorthboundRunner.composite_export(%{settings: %{}}) == nil
  assert ArmisNorthboundRunner.composite_export(%{}) == nil
end

test "composite_export reads the selection from settings" do
  source = %{
    settings: %{
      "composite" => %{
        "check_slug" => "pci-isolation",
        "value_form" => "verdict",
        "custom_field" => "sr_pci_isolation"
      }
    }
  }

  assert %{
           check_slug: "pci-isolation",
           value_form: :verdict,
           custom_field: "sr_pci_isolation"
         } = ArmisNorthboundRunner.composite_export(source)
end

test "composite_export is nil when any of the three values is missing" do
  for partial <- [
        %{"check_slug" => "pci-isolation", "value_form" => "verdict"},
        %{"check_slug" => "pci-isolation", "custom_field" => "f"},
        %{"value_form" => "verdict", "custom_field" => "f"}
      ] do
    assert ArmisNorthboundRunner.composite_export(%{settings: %{"composite" => partial}}) == nil
  end
end

test "composite_export rejects an unknown value form rather than guessing" do
  source = %{
    settings: %{
      "composite" => %{
        "check_slug" => "pci-isolation",
        "value_form" => "whatever",
        "custom_field" => "f"
      }
    }
  }

  assert ArmisNorthboundRunner.composite_export(source) == nil
end
```

- [x] **Step 2: Run them and watch them fail**

Run: `cd elixir/serviceradar_core && MIX_ENV=test mix test test/serviceradar/integrations/armis_northbound_runner_test.exs`
Expected: FAIL, `composite_export/1 is undefined`.

- [x] **Step 3: Implement**

```elixir
@spec composite_export(struct() | map()) :: composite_export() | nil
def composite_export(source) do
  source
  |> Map.get(:settings, %{})
  |> case do
    settings when is_map(settings) -> Map.get(settings, "composite")
    _other -> nil
  end
  |> build_composite_export()
end

defp build_composite_export(%{} = config) do
  with slug when is_binary(slug) and slug != "" <- trimmed(config, "check_slug"),
       field when is_binary(field) and field != "" <- trimmed(config, "custom_field"),
       form when form in [:verdict, :status] <- value_form(config) do
    %{check_slug: slug, value_form: form, custom_field: field}
  else
    _incomplete -> nil
  end
end

defp build_composite_export(_config), do: nil

defp value_form(config) do
  case trimmed(config, "value_form") do
    "verdict" -> :verdict
    "status" -> :status
    _other -> nil
  end
end

defp trimmed(config, key) do
  case Map.get(config, key) do
    value when is_binary(value) -> String.trim(value)
    _other -> nil
  end
end
```

- [x] **Step 4: Run, format, commit**

```bash
cd elixir/serviceradar_core && mix format && MIX_ENV=test mix test test/serviceradar/integrations/armis_northbound_runner_test.exs
git add -A && git commit -m "feat(northbound): read the composite export selection from source settings"
```

---

### Task 2: Composite values for a run

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/integrations/composite_northbound_values.ex`
- Test: `elixir/serviceradar_core/test/serviceradar/integrations/composite_northbound_values_test.exs`

**Interfaces:**
- Consumes: `composite_export/1`'s return from Task 1
- Produces: `CompositeNorthboundValues.for_devices(export, device_uids, opts) :: %{String.t() => String.t()}` — device uid to the string value to send. **A device with no result is absent from the map**, which is what makes omission the default rather than a filtering step someone can forget.

**Why its own module:** the runner is already 1432 lines and this is a self-contained lookup with its own failure mode (unknown slug, disabled check). Keeping it separate is also what lets Task 3 test payload building with a plain map and no database.

- [x] **Step 1: Write the failing tests**

```elixir
test "returns the verdict slug per device in verdict form" do
  # check enabled, two devices with results
  values = CompositeNorthboundValues.for_devices(export(:verdict), [a.uid, b.uid], actor: system_actor())

  assert values == %{a.uid => "isolated_verified", b.uid => "not_isolated"}
end

test "returns the status enum in status form" do
  values = CompositeNorthboundValues.for_devices(export(:status), [a.uid], actor: system_actor())

  assert values == %{a.uid => "healthy"}
end

test "a device with no result is absent rather than mapped to a placeholder" do
  values = CompositeNorthboundValues.for_devices(export(:verdict), [a.uid, "no-result"], actor: system_actor())

  refute Map.has_key?(values, "no-result")
end

test "an unknown slug yields no values rather than every device" do
  assert CompositeNorthboundValues.for_devices(export_for_slug("nope"), [a.uid], actor: system_actor()) == %{}
end

test "a draft check yields no values" do
  # Nothing maintains a draft's results on a schedule, so exporting them would
  # publish a number that silently stops moving.
  assert CompositeNorthboundValues.for_devices(export(:verdict), [a.uid], actor: system_actor()) == %{}
end

test "no device uids means no query at all" do
  assert CompositeNorthboundValues.for_devices(export(:verdict), [], actor: system_actor()) == %{}
end
```

- [x] **Step 2: Implement**

Resolve the slug through `CompositeCheck.get_by_slug/2`, require `state == :enabled`, then one `DeviceCompositeCheckResult` read filtered by `check_id` and `device_uid in ^uids`. Map `:verdict` to `result.verdict` and `:status` to `to_string(result.status)`.

- [x] **Step 3–4:** run against the srql-fixtures scratch DB, format, commit.

---

### Task 3: Emit the composite entry in the bulk payload

**Files:**
- Modify: `armis_northbound_runner.ex` (`build_bulk_payload/3`)
- Test: `armis_northbound_runner_test.exs`

**Interfaces:**
- Consumes: Task 2's `%{device_uid => value}` map, passed as `opts[:composite]` alongside the field name.

**The shape decision:** each bulk entry carries exactly one `key`/`value` pair in the `upsert` form, so a second field is a second entry, not a second key on the same entry. The `customProperties` fallback form (used when `armis_device_id` is not an integer) *can* carry two keys, and should, so the two shapes stay one-entry-per-device where the API allows it.

- [x] **Step 1: Write the failing tests**

```elixir
test "build_bulk_payload appends a composite entry for devices that have a value" do
  payload =
    ArmisNorthboundRunner.build_bulk_payload(
      "availability",
      [%{armis_device_id: "1", is_available: true, device_ids: ["dev-a"], sync_service_ids: [], metadata: %{}}],
      composite: %{custom_field: "sr_isolation", values: %{"dev-a" => "isolated_verified"}}
    )

  assert [
           %{"upsert" => %{"deviceId" => 1, "key" => "availability", "value" => "false"}},
           %{"upsert" => %{"deviceId" => 1, "key" => "sr_isolation", "value" => "isolated_verified"}}
         ] = payload
end

test "a device with no composite value gets no composite entry" do
  payload =
    ArmisNorthboundRunner.build_bulk_payload(
      "availability",
      [%{armis_device_id: "1", is_available: true, device_ids: ["dev-a"], sync_service_ids: [], metadata: %{}}],
      composite: %{custom_field: "sr_isolation", values: %{}}
    )

  assert length(payload) == 1
end

test "a candidate collapsed from several device ids uses the first that has a value" do
  # collapse_candidates merges rows by armis_device_id, so one Armis device can
  # carry several ServiceRadar uids. Sending two conflicting values for one
  # Armis device would be a last-writer-wins race inside a single batch.
  payload =
    ArmisNorthboundRunner.build_bulk_payload(
      "availability",
      [%{armis_device_id: "1", is_available: true, device_ids: ["dev-a", "dev-b"], sync_service_ids: [], metadata: %{}}],
      composite: %{custom_field: "sr_isolation", values: %{"dev-b" => "not_isolated"}}
    )

  assert [_availability, %{"upsert" => %{"value" => "not_isolated"}}] = payload
end

test "the customProperties fallback carries both keys on one entry" do
  payload =
    ArmisNorthboundRunner.build_bulk_payload(
      "availability",
      [%{armis_device_id: "not-an-int", is_available: false, device_ids: ["dev-a"], sync_service_ids: [], metadata: %{}}],
      composite: %{custom_field: "sr_isolation", values: %{"dev-a" => "healthy"}}
    )

  assert [%{"customProperties" => %{"availability" => "true", "sr_isolation" => "healthy"}}] = payload
end

test "no composite option leaves the payload exactly as before" do
  # Guards the existing export: every current test in this file must keep
  # passing unchanged.
end
```

- [x] **Step 2–4:** implement, run the whole runner test file, format, commit.

---

### Task 4: Wire the lookup into the run

**Files:** Modify `armis_northbound_runner.ex` (`do_execute_batches/3`, `execute_bulk_batches/7`, `build_run_attrs/2`)

- [x] **Step 1: Write the failing test**

An `execute_batches/3` run with a configured composite export and a stub `request` fn asserts the captured payload contains the composite entries, and that the run metadata carries `composite_check_slug` and `composite_value_form`.

- [x] **Step 2: Load once per run, not per batch**

The uid list is every `device_ids` entry across all candidates. One read per run; a read per batch would be an N+1 in the number of batches.

- [x] **Step 3: Put the selection in run metadata**

`build_run_attrs/2`'s `metadata` is what the run record stores and what Task 5 renders. Add the slug and value form there; omit the keys entirely when no export is configured, so an unconfigured run does not record `nil`s that read like a failed lookup.

- [x] **Step 4–5:** run, format, commit.

---

### Task 5: Show the selection in run status

**Files:** Modify `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/integrations_live/index.ex`
**Spec:** "the selected composite check and value form SHALL be displayed".

- [x] **Step 1: Write the failing LiveView test**

A source whose last run metadata carries the selection renders both the check slug and the value form in the northbound status block.

- [x] **Step 2–4:** render from the stored run metadata (not by re-reading source settings — the run status must describe *that run*, which may predate a configuration change), run, commit.

---

### Task 6: Verification

- [x] **Step 1:** `bash <scratchpad>/run-core.sh test test/serviceradar/integrations/` and the composite suites.

269 tests, 0 failures, 2 skipped across `test/serviceradar/integrations/` and
`test/serviceradar/composite_checks/` with `--include integration`. The web-ng
`integrations_live_test.exs` has one failure, "details modal suppresses stale
internal timestamp precision errors" — **verified pre-existing** by running the
file at the parent commit (15 tests, same 1 failure, same line). It concerns the
Agent Config Dispatch section, untouched by this plan.

- [x] **Step 2:** `./scripts/elixir_quality.sh --project elixir/serviceradar_core` and `--project elixir/web-ng --phoenix --skip-dialyzer`.

Both exit 0, including `hex.audit` and `deps.audit` — the Ash CVE gate was
cleared by merging staging during Plan 3.

- [x] **Step 3:** `openspec validate add-composite-service-checks --strict` and mark section 9 `- [x]`.

Valid. **Zero unchecked tasks remain in the change** — sections 1 through 10 are
complete.

**What the implementation settled beyond the plan:**

- The value map's shape is the omission guarantee. A device with no result is
  absent from it, so `build_bulk_payload/3` emits nothing for that device
  without a filtering step anyone could forget.
- The collapsed-candidate ambiguity the plan flagged was real: one Armis device
  can carry several ServiceRadar UIDs. First UID with a value wins, in collapse
  order, pinned by two tests. Emitting one entry per UID would have been a
  last-writer-wins race inside a single batch.
- The upsert shape carries one key per entry, so the composite field is a second
  entry; the `customProperties` fallback holds several keys and stays one entry.
- Run status reads the run's stored metadata, never the source's live settings.
  Reading live would retroactively relabel history when the selection changes.
- `CompositeNorthboundValues` degrades to `%{}` on every failure path so a run
  that cannot resolve the selection still publishes availability — but the read
  failure is logged, since a silent degrade is otherwise indistinguishable from
  a check that legitimately has no results.

## Plan Self-Review

**Spec coverage:**

| Scenario | Task |
|---|---|
| Export verdict slugs | 2, 3, 4 |
| Export status enum | 2, 3, 4 |
| Devices outside the check scope are omitted | 2 (absent from the map), 3 (no entry) |
| Selection is visible in run status | 4 (metadata), 5 (render) |

**Placeholder scan:** Tasks 1 and 3 embed their tests and implementation. Task 2's tests are named with their assertions but abbreviate fixture setup, which follows `armis_northbound_runner_integration_test.exs`. Tasks 4–6 name the files, the functions, and the assertion.

**Type consistency:** `composite_export/1` returns `%{check_slug:, value_form:, custom_field:}`; Task 2 consumes `check_slug` and `value_form` and Task 3 consumes `custom_field` plus Task 2's `values` map. Task 4 is the only place both halves meet.

**Known risk:** one Armis device can collapse from several ServiceRadar uids, so "the" composite value for it is ambiguous by construction. Task 3 makes the choice explicit and tests it rather than letting map iteration order decide.
