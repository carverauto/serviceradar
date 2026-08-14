# Composite Checks Engine Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the composite check engine in `serviceradar_core` — authored checks with typed inputs and an ordered decision table, evaluated on a schedule against existing per-agent availability and device metadata, persisting a verdict per device — plus the phase-1 API that lets OpenText Network Automation write the boolean facts a check consumes.

**Architecture:** A composite check is a derivation layer. It never probes: it reads `platform.device_agent_availability` (already populated by sweep ingestion) and `ocsf_devices.metadata`, resolves each declared input to a tri-state, runs an ordered first-match-wins rule table through one pure function, and upserts a result row per `{device_uid, check_id}`. Scope is an SRQL device query resolved through `ServiceRadar.Observability.SRQLRunner`, paged. The same pure evaluator serves the scheduled worker, the debounced per-device refresh, and (in Plan 3) the builder's preview.

**Tech Stack:** Elixir, Ash Framework 3 + AshPostgres, Oban, Ecto migrations against the `platform` schema, Phoenix (web-ng) for the REST endpoint, ExUnit.

**Spec:** `openspec/changes/add-composite-service-checks/` — read `proposal.md` and `design.md` before starting. Every requirement referenced below lives in `specs/composite-checks/spec.md` or `specs/device-inventory/spec.md`.

## Global Constraints

- **Ash only.** Every table gets an Ash resource. No Ecto-only schemas, no raw SQL in business logic. Bulk `Repo.update_all` / `Repo.delete_all` inside a materializer is acceptable and has precedent (`inventory/availability_source_profile_materializer.ex`).
- **Migrations are Ash codegen.** `mix ash.codegen <name>` then `mix ash.migrate`. NEVER `mix ecto.gen.migration` or `mix ecto.migrate`. Hand-written migrations are only for the TimescaleDB/composite-key cases, which this plan does not have.
- **A new Ash domain must be registered in BOTH `config/config.exs` AND `config/test.exs`.** Both files declare `:ash_domains`, and the `test.exs` declaration *replaces* the one in `config.exs`. Since codegen and tests run under `MIX_ENV=test`, registering only in `config.exs` makes the resource invisible: `mix ash.codegen` reports "No changes detected" and silently generates nothing.
- **`priv/resource_snapshots/` is gitignored** (`.gitignore:238`), so a fresh worktree has none. The first `mix ash.codegen` in a new worktree therefore treats all ~218 tables as new and emits a ~475KB create-everything migration. Delete that migration, keep the snapshots it wrote, and re-run codegen — the second pass diffs correctly and emits only your table. Always read the generated migration before applying it; a migration containing tables you did not touch is this failure, not a real diff.
- **There are two migration ledgers.** `platform.schema_migrations` is canonical (what `mix ash.migrate` and production use); `public.schema_migrations` is legacy, and production syncs it forward at startup (`cluster/startup_migrations.ex:1067-1081`). The `srql-fixtures-db-tests` skill bootstraps with `mix ecto.migrate`, which writes only the **legacy** ledger — so a later `mix ash.migrate` sees ~1 applied migration and replays from the first one, failing on `relation "edge_sites" already exists`. After bootstrapping a scratch DB, run the same sync production does before any `ash.migrate`:
  ```sql
  INSERT INTO platform.schema_migrations (version, inserted_at)
  SELECT version, inserted_at FROM public.schema_migrations
  ON CONFLICT (version) DO NOTHING;
  ```
- **Long migrations need a raised ownership timeout.** A full bootstrap against the shared `srql-fixtures` cluster exceeds the default 120s and dies mid-run with `owner ... timed out because it owned the connection for longer than 120000ms`, leaving the DB half-migrated (DDL committed, `schema_migrations` rolled back) and unrecoverable — drop and recreate the scratch DB. Export `SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS=1800000` before the first migrate.
- **Schema is `platform`.** Every table, index, and constraint sets `schema "platform"` in the resource and `prefix: "platform"` in any hand-written migration. Never `public`.
- **No `authorize?: false`.** Background work uses `ServiceRadar.Actors.SystemActor.system(:component_name)`. A Credo check fails the build on `authorize?: false`.
- **No `require_atomic? false`.** If an action cannot be atomic, implement `atomic/3` or restructure it. Atomicity was the single most common source of defects while building this plan — four distinct ones. The rules that emerged:
  - **A validation whose `atomic/3` returns a bare `:ok` is skipped entirely when the action runs atomically.** It will appear to work on create and silently not run on update. Delegate to `validate/3` instead, as `notifications/validations/channel_fallback_chain.ex:50` does.
  - **A change cannot read the incoming value in atomic mode.** Atomic changes live in `changeset.atomics`, not `changeset.attributes`, so `Ash.Changeset.get_attribute/2` returns `nil` and `get_data/2` is unpopulated. A guard written this way silently no-ops (or worse, rejects valid input). Use a **check constraint** for value invariants and a **policy filter** for row-level invariants — both are evaluated by the database and hold in every mode.
  - **The built-in `after_action` change does not implement `atomic/3`**, so attaching one to an update forces the whole action non-atomic. Use an **Ash notifier** for post-commit side effects instead; it receives the record and leaves the action atomic.
  - **Destroys are not atomic, updates are.** A guard tested only against destroy will pass while being broken for update.
- **Struct patterns are compile-time dependencies.** A notifier or worker that pattern-matches `%CompositeCheck{}` while the resource declares that module closes a compile cycle and deadlocks the build with `deadlocked waiting on module`. Match plain maps (`%{state: :enabled, id: id}`) in modules the resource points at.
- **`platform.device_agent_availability.device_uid` is a foreign key onto `ocsf_devices`.** Availability fixtures need a real device row first, or creation fails with `Invalid value provided for device_uid: does not exist`.
- **`system_bypass()` means a system actor skips every policy.** A policy-based invariant tested with a `SystemActor` passes vacuously; test those with an operator actor.
- **web-ng reads different test-DB env vars than serviceradar_core** (`TEST_CNPG_*` / `CNPG_*`, not `SERVICERADAR_TEST_DATABASE_URL`) and skips its whole suite unless `SERVICERADAR_REQUIRE_DB_TESTS=1` is set.
- **Single deployment.** No multitenancy, no per-customer routing, no bypass modes.
- **Composite checks never probe.** No sweep, scan, or agent command may be dispatched from any module in this plan. (`specs/composite-checks/spec.md` — Composite Check Definition)
- **`blocked` means "no positive response from any enabled probe from that vantage point"**, never "provably filtered". Per-target refused-vs-timeout is not carried from the scanner. Use this wording in moduledocs and user-facing strings.
- **Formatting:** `mix format` before every commit. The repo uses Styler, so run the formatter rather than hand-aligning.
- **Verdict status enum is fixed:** `:healthy | :degraded | :down | :unknown`. Verdict slugs are operator-defined and unconstrained beyond a slug pattern.
- **Tri-state input values:** vantage points resolve to `:available | :blocked | :unknown`; metadata facts resolve to `true | false | :unknown`. `:unknown` is a matchable value, never an automatic short-circuit.

## File Structure

Everything lives under `elixir/serviceradar_core/lib/serviceradar/composite_checks/` except the merge wiring, the device fact action, the RBAC catalog entry, and the web-ng endpoint.

**New — domain and resources**
- `composite_checks.ex` — the Ash domain, registering the four resources.
- `composite_checks/composite_check.ex` — authored check: name, slug, scope query, interval, state.
- `composite_checks/composite_check_input.ex` — typed named signal.
- `composite_checks/composite_check_rule.ex` — one decision table row.
- `composite_checks/device_composite_check_result.ex` — per-device verdict.
- `composite_checks/validations/scope_query.ex` — SRQL scope must target devices.
- `composite_checks/validations/input_config.ex` — per-kind config shape.

**New — resolution and evaluation**
- `composite_checks/resolvers.ex` — resolver dispatch by input kind; the seam a future kind plugs into.
- `composite_checks/resolvers/vantage_point.ex` — reads `device_agent_availability`.
- `composite_checks/resolvers/device_metadata.ex` — reads metadata value + provenance.
- `composite_checks/evaluator.ex` — the pure decision table function. No I/O, no aliases to Repo or Ash.
- `composite_checks/rule_generator.ex` — seeds a rule table from vantage point expectations.
- `composite_checks/scope.ex` — SRQL scope resolution and paging.
- `composite_checks/coverage.ex` — per-vantage-point coverage counts over a scope.
- `composite_checks/evaluation.ex` — orchestrates a pass: page scope, resolve, evaluate, upsert, diff.
- `composite_checks/evaluation_worker.ex` — Oban worker, one job per enabled check.
- `composite_checks/refresh.ex` — debounced per-device re-evaluation.
- `composite_checks/verdict_event_writer.ex` — records verdict transition OCSF events.

**Modified**
- `lib/serviceradar/inventory/identity/reassignments.ex` — add `reassign_composite_results/3`.
- `lib/serviceradar/inventory/identity/merge_engine.ex:210-236` — add the resource and the call.
- `lib/serviceradar/inventory/device.ex` — add the `:write_facts` action.
- `lib/serviceradar/identity/rbac/catalog.ex` — add the `composite_checks` section and `devices.facts.write`.
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/device_controller.ex` — add `update_metadata/2`.
- `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:385` — add the PATCH route.

**Why this split:** resolvers, evaluator, and evaluation orchestration are separated because the evaluator must stay pure and independently testable — it is the one piece three callers share, and the correctness of the whole feature rests on it. `scope.ex` and `coverage.ex` are separate from `evaluation.ex` because Plan 3's builder calls them directly without running a pass.

---

### Task 1: Composite check resource and migration

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/validations/scope_query.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_test.exs`
- Modify: `elixir/serviceradar_core/config/config.exs` (add the domain to `ash_domains`)

**Interfaces:**
- Consumes: nothing.
- Produces: `ServiceRadar.CompositeChecks.CompositeCheck` with attributes `id :: uuid`, `name :: string`, `slug :: string`, `description :: string | nil`, `scope_query :: string`, `evaluation_interval_seconds :: integer`, `state :: :draft | :enabled | :disabled`. Code interface: `CompositeCheck.get_by_id(id, opts)`, `CompositeCheck.get_by_slug(slug, opts)`, `CompositeCheck.list_enabled(opts)`.

- [ ] **Step 1: Find how domains are registered**

Run: `rg -n "ash_domains" elixir/serviceradar_core/config/config.exs`

Read the list. You will append `ServiceRadar.CompositeChecks` to it in Step 4.

- [ ] **Step 2: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheckTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck

  defp actor, do: SystemActor.system(:composite_check_test)

  defp create(attrs) do
    CompositeCheck
    |> Ash.Changeset.for_create(:create, attrs, actor: actor())
    |> Ash.create()
  end

  describe "create" do
    test "derives a slug from the name and starts in draft" do
      assert {:ok, check} =
               create(%{
                 name: "PCI Isolation — Managed",
                 scope_query: "in:devices source:armis tag:managed"
               })

      assert check.slug == "pci-isolation-managed"
      assert check.state == :draft
      assert check.evaluation_interval_seconds == 300
    end

    test "rejects a scope that does not target devices" do
      assert {:error, error} =
               create(%{name: "Bad Scope", scope_query: "in:flows src_ip:10.0.0.1"})

      assert Exception.message(error) =~ "must target devices"
    end

    test "rejects a duplicate slug" do
      assert {:ok, _} = create(%{name: "Dupe Check", scope_query: "in:devices"})
      assert {:error, error} = create(%{name: "Dupe Check", scope_query: "in:devices"})
      assert Exception.message(error) =~ "already been taken"
    end
  end

  describe "update" do
    test "renaming does not change the slug" do
      {:ok, check} = create(%{name: "Original Name", scope_query: "in:devices"})

      assert {:ok, renamed} =
               check
               |> Ash.Changeset.for_update(:update, %{name: "Different Name"}, actor: actor())
               |> Ash.update()

      assert renamed.slug == "original-name"
      assert renamed.name == "Different Name"
    end
  end
end
```

- [ ] **Step 3: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.CompositeCheck is not available`.

- [ ] **Step 4: Create the domain**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks do
  @moduledoc """
  Composite service checks: operator-authored verdicts derived from signals that
  other subsystems already produce.

  A composite check scopes a device population with SRQL, declares named typed
  inputs (per-agent reachability, device metadata facts), and maps combinations
  of those inputs onto operator-defined verdicts through an ordered decision
  table. Composite checks never probe — they read `device_agent_availability`
  and device metadata and derive an answer.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.CompositeChecks.CompositeCheck
    resource ServiceRadar.CompositeChecks.CompositeCheckInput
    resource ServiceRadar.CompositeChecks.CompositeCheckRule
    resource ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  end
end
```

Append `ServiceRadar.CompositeChecks` to the `ash_domains` list in `config/config.exs` **and** to the separate `ash_domains` list in `config/test.exs`. The test-env list replaces rather than extends the base one, and codegen runs under `MIX_ENV=test` — registering in only one file makes codegen report "No changes detected" and generate nothing.

Note: the domain references all four resources, so `mix compile` will fail until Tasks 2–4 create them. That is expected; the tests in this task run only after Task 4. If you want a green intermediate state, comment out the three not-yet-created `resource` lines and uncomment them as each task lands.

- [ ] **Step 5: Create the scope validation**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/validations/scope_query.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Validations.ScopeQuery do
  @moduledoc """
  A composite check scope must be a valid SRQL query targeting devices.

  Mirrors `ServiceRadar.Inventory.Validations.AvailabilitySourceProfileTargetQuery`.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :scope_query) do
      query when is_binary(query) and query != "" ->
        query
        |> SRQLQuery.ensure_target(:devices)
        |> validate_device_query()

      _ ->
        {:error, field: :scope_query, message: "is required"}
    end
  end

  defp validate_device_query(query) do
    if SRQLAst.entity(query) == "devices" do
      case SRQLAst.validate(query) do
        :ok -> :ok
        {:error, reason} -> {:error, field: :scope_query, message: "Invalid SRQL query: #{reason}"}
      end
    else
      {:error, field: :scope_query, message: "must target devices"}
    end
  end
end
```

- [ ] **Step 6: Create the resource**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheck do
  @moduledoc """
  An operator-authored composite check.

  The check scopes a device population with SRQL and derives one verdict per
  device from its declared inputs and its ordered rule table. A composite check
  never dispatches a probe: it reads signals other subsystems already persist.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.CompositeChecks.Validations.ScopeQuery

  @create_fields [:name, :description, :scope_query, :evaluation_interval_seconds]
  @update_fields @create_fields

  postgres do
    table "composite_checks"
    repo ServiceRadar.Repo
    schema "platform"

    custom_indexes do
      index ["lower(name)"], unique: true, name: "composite_checks_name_uidx"
      index [:state], name: "composite_checks_state_idx"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :list_enabled, action: :enabled
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :enabled do
      filter expr(state == :enabled)
      prepare build(sort: [name: :asc])
    end

    create :create do
      accept @create_fields
      change ServiceRadar.CompositeChecks.Changes.DeriveSlug
      validate ScopeQuery
    end

    update :update do
      accept @update_fields
      validate ScopeQuery
    end

    update :set_state do
      accept [:state]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    operator_action(:set_state)
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      writable? false
      description "Immutable query handle, derived from the name at creation"
    end

    attribute :description, :string do
      public? true
    end

    attribute :scope_query, :string do
      allow_nil? false
      public? true
      description "SRQL query selecting the devices this check evaluates"
    end

    attribute :evaluation_interval_seconds, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 60, max: 86_400
    end

    attribute :state, :atom do
      allow_nil? false
      default :draft
      public? true
      constraints one_of: [:draft, :enabled, :disabled]
    end

    attribute :last_evaluated_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
```

- [ ] **Step 7: Create the slug derivation change**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/changes/derive_slug.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Changes.DeriveSlug do
  @moduledoc """
  Derives the immutable `slug` from the check name at creation.

  The slug is the check's SRQL handle (`composite.<slug>`), so it must never
  change after creation: saved queries would break.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :name) do
      name when is_binary(name) and name != "" ->
        Ash.Changeset.force_change_attribute(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end

  @doc false
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end
end
```

Note on the test expectation: `"PCI Isolation — Managed"` slugifies to `"pci-isolation-managed"` because the em dash is stripped by the character class and the surrounding spaces collapse to a single hyphen.

- [ ] **Step 8: Generate and apply the migration**

Run:
```bash
cd elixir/serviceradar_core
mix ash.codegen add_composite_checks
mix ash.migrate
```

Open the generated migration and confirm every `create table` and `create index` carries `prefix: "platform"`. If any does not, the resource is missing `schema "platform"` — fix the resource and regenerate rather than editing the migration.

- [ ] **Step 9: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_test.exs`
Expected: PASS, 4 tests.

If the domain fails to compile because Tasks 2–4 resources do not exist yet, temporarily comment out those three `resource` lines in the domain.

- [ ] **Step 10: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks.ex \
        lib/serviceradar/composite_checks/composite_check.ex \
        lib/serviceradar/composite_checks/changes/derive_slug.ex \
        lib/serviceradar/composite_checks/validations/scope_query.ex \
        test/serviceradar/composite_checks/composite_check_test.exs \
        priv/repo/migrations/ config/config.exs
git commit -m "feat(composite-checks): add composite check resource with immutable slug"
```

---

### Task 2: Typed check inputs

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check_input.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/validations/input_config.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_input_test.exs`

**Interfaces:**
- Consumes: `CompositeCheck` from Task 1 (`check_id` belongs_to).
- Produces: `ServiceRadar.CompositeChecks.CompositeCheckInput` with `key :: string`, `label :: string`, `position :: integer`, `kind :: :vantage_point | :device_metadata`, `config :: map`, `expected :: string | nil`. Code interface: `CompositeCheckInput.list_by_check(check_id, opts)`.
- `config` shapes, which Task 6 and Task 7 resolvers read verbatim:
  - `:vantage_point` → `%{"agent_id" => String.t(), "max_age_seconds" => pos_integer() | nil}`
  - `:device_metadata` → `%{"path" => String.t(), "value_type" => "boolean", "max_age_seconds" => pos_integer() | nil}`

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_input_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheckInputTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Input Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp create_input(check, attrs) do
    CompositeCheckInput
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
    |> Ash.create()
  end

  test "creates a vantage point input", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "agent_a",
               label: "agent-a · dmz-01",
               position: 0,
               kind: :vantage_point,
               expected: "available",
               config: %{"agent_id" => "agent-a", "max_age_seconds" => 900}
             })

    assert input.kind == :vantage_point
    assert input.config["agent_id"] == "agent-a"
  end

  test "creates a device metadata input", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "nac",
               label: "NCO nac_applied",
               position: 2,
               kind: :device_metadata,
               config: %{
                 "path" => "nac_applied",
                 "value_type" => "boolean",
                 "max_age_seconds" => 86_400
               }
             })

    assert input.config["path"] == "nac_applied"
  end

  test "rejects a vantage point input with no agent_id", %{check: check} do
    assert {:error, error} =
             create_input(check, %{
               key: "agent_b",
               label: "agent-b",
               position: 1,
               kind: :vantage_point,
               config: %{"max_age_seconds" => 900}
             })

    assert Exception.message(error) =~ "agent_id"
  end

  test "rejects a metadata input with an unsupported value type", %{check: check} do
    assert {:error, error} =
             create_input(check, %{
               key: "weird",
               label: "Weird",
               position: 3,
               kind: :device_metadata,
               config: %{"path" => "x", "value_type" => "blob"}
             })

    assert Exception.message(error) =~ "value_type"
  end

  test "rejects a duplicate key within one check", %{check: check} do
    assert {:ok, _} =
             create_input(check, %{
               key: "agent_a",
               label: "A",
               position: 0,
               kind: :vantage_point,
               config: %{"agent_id" => "agent-a"}
             })

    assert {:error, error} =
             create_input(check, %{
               key: "agent_a",
               label: "A again",
               position: 1,
               kind: :vantage_point,
               config: %{"agent_id" => "agent-z"}
             })

    assert Exception.message(error) =~ "already been taken"
  end

  test "max_age_seconds is optional", %{check: check} do
    assert {:ok, input} =
             create_input(check, %{
               key: "legacy_fact",
               label: "Legacy fact",
               position: 4,
               kind: :device_metadata,
               config: %{"path" => "legacy_flag", "value_type" => "boolean"}
             })

    refute Map.has_key?(input.config, "max_age_seconds")
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_input_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.CompositeCheckInput is not available`.

- [ ] **Step 3: Create the config validation**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/validations/input_config.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Validations.InputConfig do
  @moduledoc """
  Validates the `config` map against the input's `kind`.

  This is the per-kind half of the extension seam: adding an input kind means
  adding a clause here and a resolver module, and nothing else.
  """

  use Ash.Resource.Validation

  @supported_value_types ["boolean"]

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)
    config = Ash.Changeset.get_attribute(changeset, :config) || %{}

    with :ok <- validate_kind(kind, config) do
      validate_max_age(config)
    end
  end

  defp validate_kind(:vantage_point, config) do
    case Map.get(config, "agent_id") do
      agent_id when is_binary(agent_id) and agent_id != "" ->
        :ok

      _ ->
        {:error, field: :config, message: "vantage_point config requires a non-empty agent_id"}
    end
  end

  defp validate_kind(:device_metadata, config) do
    path = Map.get(config, "path")
    value_type = Map.get(config, "value_type")

    cond do
      not (is_binary(path) and path != "") ->
        {:error, field: :config, message: "device_metadata config requires a non-empty path"}

      value_type not in @supported_value_types ->
        {:error,
         field: :config,
         message: "device_metadata config value_type must be one of: #{Enum.join(@supported_value_types, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_kind(_kind, _config), do: :ok

  defp validate_max_age(config) do
    case Map.fetch(config, "max_age_seconds") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, seconds} when is_integer(seconds) and seconds > 0 -> :ok
      {:ok, _} -> {:error, field: :config, message: "max_age_seconds must be a positive integer"}
    end
  end
end
```

- [ ] **Step 4: Create the resource**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check_input.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheckInput do
  @moduledoc """
  A named, typed signal that a composite check consumes.

  Two kinds ship: `:vantage_point` (per-agent reachability from
  `device_agent_availability`) and `:device_metadata` (a scalar fact on the
  device record). Adding a kind requires a resolver module and a clause in
  `ServiceRadar.CompositeChecks.Validations.InputConfig` — rule structure,
  result storage, and the evaluator are unaffected.

  `expected` is an authoring aid used to seed the rule table and to label
  liveness witnesses. The evaluator never reads it.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.CompositeChecks.Validations.InputConfig

  @fields [:check_id, :key, :label, :position, :kind, :config, :expected]

  postgres do
    table "composite_check_inputs"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete, index?: true
    end

    custom_indexes do
      index [:check_id, :position], name: "composite_check_inputs_check_position_idx"
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [position: :asc, key: :asc])
    end

    create :create do
      accept @fields
      validate InputConfig
    end

    update :update do
      accept @fields -- [:check_id]
      validate InputConfig
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      description "Identifier used in rule match maps and result input snapshots"
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:vantage_point, :device_metadata]
    end

    attribute :config, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :expected, :string do
      public? true
      description "Authoring aid used to seed rules and label witnesses; never evaluated"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_key_per_check, [:check_id, :key]
  end
end
```

- [ ] **Step 5: Generate and apply the migration**

```bash
cd elixir/serviceradar_core
mix ash.codegen add_composite_check_inputs
mix ash.migrate
```

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_input_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/composite_check_input.ex \
        lib/serviceradar/composite_checks/validations/input_config.ex \
        test/serviceradar/composite_checks/composite_check_input_test.exs \
        priv/repo/migrations/
git commit -m "feat(composite-checks): add typed check inputs with per-kind config validation"
```

---

### Task 3: Decision table rules with a mandatory catch-all

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check_rule.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/changes/protect_catch_all.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_rule_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check.ex` (create the catch-all after check creation)

**Interfaces:**
- Consumes: `CompositeCheck` (Task 1).
- Produces: `ServiceRadar.CompositeChecks.CompositeCheckRule` with `position :: integer`, `match :: map` (`input_key => value | [values] | "*"`), `verdict :: string`, `verdict_label :: string`, `verdict_description :: string | nil`, `status :: :healthy | :degraded | :down | :unknown`, `catch_all :: boolean`. Code interface: `CompositeCheckRule.list_by_check(check_id, opts)` returning rules sorted by `position` ascending — the order the evaluator in Task 8 depends on.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_rule_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheckRuleTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckRule

  defp actor, do: SystemActor.system(:composite_check_test)

  defp new_check do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Rule Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    check
  end

  test "creating a check creates its catch-all rule" do
    check = new_check()

    assert {:ok, [rule]} = CompositeCheckRule.list_by_check(check.id, actor: actor())
    assert rule.catch_all
    assert rule.verdict == "inconclusive"
    assert rule.status == :unknown
    assert rule.match == %{}
  end

  test "the catch-all cannot be destroyed" do
    check = new_check()
    {:ok, [catch_all]} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:error, error} = Ash.destroy(catch_all, actor: actor())
    assert Exception.message(error) =~ "catch-all"
  end

  test "the catch-all can be relabelled but keeps its wildcard match" do
    check = new_check()
    {:ok, [catch_all]} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:ok, updated} =
             catch_all
             |> Ash.Changeset.for_update(
               :update,
               %{verdict_label: "Not enough signal", match: %{"agent_a" => "available"}},
               actor: actor()
             )
             |> Ash.update()

    assert updated.verdict_label == "Not enough signal"
    assert updated.match == %{}
  end

  test "rules sort by position with the catch-all last" do
    check = new_check()

    for {verdict, position} <- [{"not_isolated", 2}, {"isolated_verified", 0}] do
      assert {:ok, _} =
               CompositeCheckRule
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   check_id: check.id,
                   position: position,
                   match: %{"agent_a" => "available"},
                   verdict: verdict,
                   verdict_label: verdict,
                   status: :healthy
                 },
                 actor: actor()
               )
               |> Ash.create()
    end

    {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert Enum.map(rules, & &1.verdict) == ["isolated_verified", "not_isolated", "inconclusive"]
    assert List.last(rules).catch_all
  end

  test "a non-catch-all rule requires a non-empty match" do
    check = new_check()

    assert {:error, error} =
             CompositeCheckRule
             |> Ash.Changeset.for_create(
               :create,
               %{
                 check_id: check.id,
                 position: 0,
                 match: %{},
                 verdict: "everything",
                 verdict_label: "Everything",
                 status: :healthy
               },
               actor: actor()
             )
             |> Ash.create()

    assert Exception.message(error) =~ "match"
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_rule_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.CompositeCheckRule is not available`.

- [ ] **Step 3: Create the catch-all protection change**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/changes/protect_catch_all.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Changes.ProtectCatchAll do
  @moduledoc """
  Keeps the catch-all rule total and last.

  The catch-all is what makes a decision table total: every input combination
  reaches it if nothing above matched. Allowing it to be deleted, reordered, or
  given a real match map would silently reintroduce unmatched combinations.
  """

  use Ash.Resource.Change

  @catch_all_position 1_000_000

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.action_type do
      :destroy -> prevent_destroy(changeset)
      :update -> pin_catch_all(changeset)
      _ -> changeset
    end
  end

  defp prevent_destroy(changeset) do
    if catch_all?(changeset) do
      Ash.Changeset.add_error(changeset,
        field: :catch_all,
        message: "the catch-all rule cannot be deleted"
      )
    else
      changeset
    end
  end

  defp pin_catch_all(changeset) do
    if catch_all?(changeset) do
      changeset
      |> Ash.Changeset.force_change_attribute(:match, %{})
      |> Ash.Changeset.force_change_attribute(:position, @catch_all_position)
    else
      changeset
    end
  end

  defp catch_all?(changeset) do
    Ash.Changeset.get_data(changeset, :catch_all) == true
  end

  @doc false
  def catch_all_position, do: @catch_all_position
end
```

- [ ] **Step 4: Create the resource**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check_rule.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.CompositeCheckRule do
  @moduledoc """
  One row of a composite check's decision table.

  Rules are evaluated in ascending `position` order and the first match wins.
  `match` maps an input key to a literal value, a list of literal values, or the
  wildcard `"*"`; an input key absent from the map is treated as a wildcard.

  `verdict` is an operator-defined slug carrying the domain meaning. `status` is
  a fixed enum so rollups, colors, and northbound exports work without knowing a
  given deployment's vocabulary.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.CompositeChecks.Changes.ProtectCatchAll

  @fields [:check_id, :position, :match, :verdict, :verdict_label, :verdict_description, :status]

  postgres do
    table "composite_check_rules"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete, index?: true
    end

    custom_indexes do
      index [:check_id, :position], name: "composite_check_rules_check_position_idx"
    end
  end

  code_interface do
    define :list_by_check, action: :by_check, args: [:check_id]
  end

  actions do
    defaults [:read]

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    create :create do
      accept @fields
      validate present(:match), message: "must not be empty for a non-catch-all rule"
    end

    create :create_catch_all do
      description "Creates the mandatory trailing catch-all; called on check creation"
      accept [:check_id, :verdict, :verdict_label, :verdict_description]
      change set_attribute(:catch_all, true)
      change set_attribute(:match, %{})
      change set_attribute(:status, :unknown)
      change set_attribute(:position, ProtectCatchAll.catch_all_position())
    end

    update :update do
      accept @fields -- [:check_id]
      change ProtectCatchAll
    end

    destroy :destroy do
      primary? true
      change ProtectCatchAll
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update, :destroy])
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :match, :map do
      allow_nil? false
      default %{}
      public? true
      description "input_key => literal | [literals] | \"*\"; absent key means wildcard"
    end

    attribute :verdict, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict_label, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict_description, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :unknown
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :catch_all, :boolean do
      allow_nil? false
      default false
      public? true
      writable? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end
  end
end
```

Note: `validate present(:match)` rejects an empty map on `:create` while `:create_catch_all` sets it via `change set_attribute`, bypassing that validation because the catch-all action does not accept `:match`.

- [ ] **Step 5: Create the catch-all on check creation**

In `composite_check.ex`, add to the `create :create` action, after the existing `change`/`validate` lines:

```elixir
    create :create do
      accept @create_fields
      change ServiceRadar.CompositeChecks.Changes.DeriveSlug
      validate ScopeQuery

      change after_action(fn _changeset, check, context ->
               ServiceRadar.CompositeChecks.CompositeCheckRule
               |> Ash.Changeset.for_create(
                 :create_catch_all,
                 %{
                   check_id: check.id,
                   verdict: "inconclusive",
                   verdict_label: "Inconclusive",
                   verdict_description:
                     "One or more inputs were unknown or stale, so no verdict can be asserted"
                 },
                 Ash.Context.to_opts(context)
               )
               |> Ash.create()
               |> case do
                 {:ok, _rule} -> {:ok, check}
                 {:error, error} -> {:error, error}
               end
             end)
    end
```

- [ ] **Step 6: Generate and apply the migration**

```bash
cd elixir/serviceradar_core
mix ash.codegen add_composite_check_rules
mix ash.migrate
```

- [ ] **Step 7: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/composite_check_rule_test.exs test/serviceradar/composite_checks/composite_check_test.exs`
Expected: PASS, 9 tests.

- [ ] **Step 8: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/composite_check_rule.ex \
        lib/serviceradar/composite_checks/changes/protect_catch_all.ex \
        lib/serviceradar/composite_checks/composite_check.ex \
        test/serviceradar/composite_checks/composite_check_rule_test.exs \
        priv/repo/migrations/
git commit -m "feat(composite-checks): add decision table rules with a protected catch-all"
```

---

### Task 4: Per-device result storage

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/device_composite_check_result.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/device_composite_check_result_test.exs`

**Interfaces:**
- Consumes: `CompositeCheck` (Task 1), `CompositeCheckRule` (Task 3).
- Produces: `ServiceRadar.CompositeChecks.DeviceCompositeCheckResult` with `device_uid :: string`, `check_id :: uuid`, `verdict :: string`, `status :: atom`, `matched_rule_id :: uuid | nil`, `inputs :: map`, `evaluated_at :: DateTime.t()`, `changed_at :: DateTime.t()`. Code interface: `list_by_device(device_uid, opts)`, `list_by_check(check_id, opts)`, `get_by_device_check(device_uid, check_id, opts)`. Actions used by later tasks: `:upsert` (Task 11) and `:reassign_device` (Task 5).
- `inputs` snapshot shape, written by Task 11 and read by Plan 3's UI:
  ```elixir
  %{"agent_a" => %{"value" => "available", "observed_at" => "2026-08-11T21:00:00Z", "stale" => false}}
  ```

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/device_composite_check_result_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.DeviceCompositeCheckResultTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Result Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp upsert(check, device_uid, verdict, status, at) do
    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{"agent_a" => %{"value" => "available", "stale" => false}},
        evaluated_at: at,
        changed_at: at
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create()
  end

  test "stores a verdict with its input snapshot", %{check: check} do
    now = DateTime.utc_now()
    assert {:ok, result} = upsert(check, "device-1", "isolated_verified", :healthy, now)

    assert result.verdict == "isolated_verified"
    assert result.status == :healthy
    assert result.inputs["agent_a"]["value"] == "available"
  end

  test "one row per device and check", %{check: check} do
    now = DateTime.utc_now()
    assert {:ok, _} = upsert(check, "device-1", "isolated_verified", :healthy, now)
    assert {:ok, _} = upsert(check, "device-1", "not_isolated", :down, DateTime.add(now, 60))

    assert {:ok, rows} = DeviceCompositeCheckResult.list_by_check(check.id, actor: actor())
    assert length(rows) == 1
    assert hd(rows).verdict == "not_isolated"
  end

  test "reassign_device moves a result to the surviving uid", %{check: check} do
    now = DateTime.utc_now()
    {:ok, result} = upsert(check, "device-loser", "isolated_verified", :healthy, now)

    assert {:ok, moved} =
             result
             |> Ash.Changeset.for_update(:reassign_device, %{device_uid: "device-winner"},
               actor: actor()
             )
             |> Ash.update()

    assert moved.device_uid == "device-winner"
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/device_composite_check_result_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.DeviceCompositeCheckResult is not available`.

- [ ] **Step 3: Create the resource**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/device_composite_check_result.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.DeviceCompositeCheckResult do
  @moduledoc """
  The current composite check verdict for one device.

  Verdicts live here rather than in `ocsf_devices.metadata` deliberately: a
  metadata merge per device per evaluation cycle would rewrite the device row on
  every pass, churning DIRE notifiers, device PubSub, and the device read model
  for data no device consumer needs inline.

  `changed_at` advances only when the verdict actually changes, so it is a real
  transition timestamp rather than a copy of `evaluated_at`.
  """

  use Ash.Resource,
    domain: ServiceRadar.CompositeChecks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @upsert_fields [
    :device_uid,
    :check_id,
    :verdict,
    :status,
    :matched_rule_id,
    :inputs,
    :evaluated_at,
    :changed_at
  ]

  postgres do
    table "device_composite_check_results"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :check, on_delete: :delete, index?: true
    end

    custom_indexes do
      index [:device_uid, :check_id],
        unique: true,
        name: "device_composite_check_results_device_check_uidx"

      index [:device_uid], name: "device_composite_check_results_device_uid_idx"
      index [:check_id, :verdict], name: "device_composite_check_results_check_verdict_idx"
      index [:check_id, :status], name: "device_composite_check_results_check_status_idx"
    end
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
    define :list_by_check, action: :by_check, args: [:check_id]
    define :get_by_device_check, action: :by_device_check, args: [:device_uid, :check_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [evaluated_at: :desc])
    end

    read :by_check do
      argument :check_id, :uuid, allow_nil?: false
      filter expr(check_id == ^arg(:check_id))
      prepare build(sort: [device_uid: :asc])
    end

    read :by_device_check do
      argument :device_uid, :string, allow_nil?: false
      argument :check_id, :uuid, allow_nil?: false
      get? true
      filter expr(device_uid == ^arg(:device_uid) and check_id == ^arg(:check_id))
    end

    create :upsert do
      accept @upsert_fields
      upsert? true
      upsert_identity :unique_device_check
      upsert_fields [:verdict, :status, :matched_rule_id, :inputs, :evaluated_at, :changed_at]
    end

    update :reassign_device do
      description "Repoint the row to a canonical device during an identity merge"
      accept [:device_uid]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type([:create, :update])
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :verdict, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:healthy, :degraded, :down, :unknown]
    end

    attribute :matched_rule_id, :uuid do
      public? true
    end

    attribute :inputs, :map do
      allow_nil? false
      default %{}
      public? true
      description "Per-input resolved value, observation time, and staleness at evaluation"
    end

    attribute :evaluated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :changed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the verdict last changed, not when it was last evaluated"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :check, ServiceRadar.CompositeChecks.CompositeCheck do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_device_check, [:device_uid, :check_id]
  end
end
```

- [ ] **Step 4: Generate and apply the migration**

```bash
cd elixir/serviceradar_core
mix ash.codegen add_device_composite_check_results
mix ash.migrate
```

- [ ] **Step 5: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/`
Expected: PASS, 12 tests. If the domain still has commented-out `resource` lines from Task 1, uncomment all four now — every resource exists.

- [ ] **Step 6: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/device_composite_check_result.ex \
        lib/serviceradar/composite_checks.ex \
        test/serviceradar/composite_checks/device_composite_check_result_test.exs \
        priv/repo/migrations/
git commit -m "feat(composite-checks): add per-device verdict result storage"
```

---

### Task 5: Survive device identity merges

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/identity/reassignments.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/identity/merge_engine.ex` (the `resources` list and the `with` chain in `do_merge_devices/5`, around lines 210–236)
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/identity/merge_engine_test.exs` — or create `test/serviceradar/composite_checks/merge_reassignment_test.exs` if that file does not exist

**Interfaces:**
- Consumes: `DeviceCompositeCheckResult.list_by_device/2`, `.get_by_device_check/3`, `:reassign_device` (Task 4).
- Produces: `ServiceRadar.Inventory.Identity.Reassignments.reassign_composite_results(from_id, to_id, actor) :: :ok | {:error, term()}`.

**Why this task exists:** without it, every verdict strands on the losing UID after a DIRE merge and the device silently loses its compliance state. `DeviceAgentAvailability` already has exactly this wiring — Task 5 mirrors it.

- [ ] **Step 1: Read the existing pattern**

Run: `sed -n '106,136p' elixir/serviceradar_core/lib/serviceradar/inventory/identity/reassignments.ex`

That is `reassign_availability/3`. It handles the collision case — a row whose `{device, agent}` pair already exists on the survivor is destroyed rather than violating the unique identity. Composite results have the same shape with `{device_uid, check_id}`.

- [ ] **Step 2: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/merge_reassignment_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.MergeReassignmentTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Inventory.Identity.Reassignments

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Merge Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    %{check: check}
  end

  defp upsert(check, device_uid, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: now,
        changed_at: now
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  test "moves results from the losing uid to the survivor", %{check: check} do
    upsert(check, "loser", "isolated_verified", :healthy)

    assert :ok = Reassignments.reassign_composite_results("loser", "winner", actor())

    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("loser", actor: actor())
    assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())
    assert row.verdict == "isolated_verified"
  end

  test "drops the losing row when the survivor already has one for that check", %{check: check} do
    upsert(check, "loser", "not_isolated", :down)
    upsert(check, "winner", "isolated_verified", :healthy)

    assert :ok = Reassignments.reassign_composite_results("loser", "winner", actor())

    assert {:ok, []} = DeviceCompositeCheckResult.list_by_device("loser", actor: actor())
    assert {:ok, [row]} = DeviceCompositeCheckResult.list_by_device("winner", actor: actor())
    assert row.verdict == "isolated_verified"
  end
end
```

- [ ] **Step 3: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/merge_reassignment_test.exs`
Expected: FAIL — `function ServiceRadar.Inventory.Identity.Reassignments.reassign_composite_results/3 is undefined`.

- [ ] **Step 4: Add the reassignment function**

In `reassignments.ex`, add the alias near the existing ones:

```elixir
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
```

and add this function immediately after `reassign_availability/3`:

```elixir
  @doc """
  Repoint composite check results to the canonical device. A row whose
  (device, check) pair already exists on the survivor is dropped instead of
  violating the unique identity — the survivor's own verdict is the current one.
  """
  def reassign_composite_results(from_id, to_id, actor) do
    case DeviceCompositeCheckResult.list_by_device(from_id, actor: actor) do
      {:ok, rows} ->
        Enum.reduce_while(rows, :ok, fn row, :ok ->
          case DeviceCompositeCheckResult.get_by_device_check(to_id, row.check_id, actor: actor) do
            {:ok, %DeviceCompositeCheckResult{}} ->
              case Ash.destroy(row, actor: actor) do
                :ok -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end

            _ ->
              row
              |> Ash.Changeset.for_update(:reassign_device, %{device_uid: to_id})
              |> Ash.update(actor: actor)
              |> case do
                {:ok, _} -> {:cont, :ok}
                {:error, error} -> {:halt, {:error, error}}
              end
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end
```

- [ ] **Step 5: Wire it into the merge engine**

In `merge_engine.ex`, add the alias:

```elixir
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
```

Add `DeviceCompositeCheckResult` to the `resources` list in `do_merge_devices/5` so the transaction covers it:

```elixir
    resources = [
      Device,
      DeviceIdentifier,
      DeviceSourceObservation,
      Interface,
      MergeAudit,
      ServiceCheck,
      Alert,
      Agent,
      DeviceAgentAvailability,
      DeviceCompositeCheckResult,
      DeviceAliasState
    ]
```

And add the call to the `with` chain, immediately after the existing `reassign_availability` line:

```elixir
           :ok <- Reassignments.reassign_availability(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_composite_results(from_device_id, to_device_id, actor),
```

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/merge_reassignment_test.exs test/serviceradar/inventory/identity/`
Expected: PASS. The existing merge engine tests must stay green — if any fail, the resource list or the `with` chain was edited incorrectly.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/inventory/identity/reassignments.ex \
        lib/serviceradar/inventory/identity/merge_engine.ex \
        test/serviceradar/composite_checks/merge_reassignment_test.exs
git commit -m "feat(composite-checks): reassign verdicts on device identity merge"
```

---

### Task 6: Vantage point resolver

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/resolvers/vantage_point.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/resolvers/vantage_point_test.exs`

**Interfaces:**
- Consumes: `ServiceRadar.Inventory.DeviceAgentAvailability` (existing; attributes `device_uid`, `agent_id`, `is_available`, `checked_at`).
- Produces: `ServiceRadar.CompositeChecks.Resolvers.VantagePoint.resolve(input, availability_row, now) :: resolution()` where

  ```elixir
  @type resolution :: %{
          value: :available | :blocked | :unknown,
          observed_at: DateTime.t() | nil,
          stale: boolean(),
          reason: nil | :no_result | :stale
        }
  ```

  `input` is a `CompositeCheckInput` struct. `availability_row` is a `DeviceAgentAvailability` struct or `nil`. This function does **no I/O** — Task 11 batch-loads the rows and passes them in. That is what keeps the pass free of N+1 queries.

**Semantics that matter:** `:blocked` means *no positive response from any enabled probe from that vantage point*. It does not mean "provably filtered" — per-target refused-vs-timeout is not carried from the Go scanner into sweep results. Put this in the moduledoc.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/resolvers/vantage_point_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.Resolvers.VantagePointTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.VantagePoint
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  @now ~U[2026-08-11 22:00:00.000000Z]

  defp input(max_age_seconds) do
    config =
      case max_age_seconds do
        nil -> %{"agent_id" => "agent-a"}
        seconds -> %{"agent_id" => "agent-a", "max_age_seconds" => seconds}
      end

    %CompositeCheckInput{key: "agent_a", kind: :vantage_point, config: config}
  end

  defp row(is_available, checked_at) do
    %DeviceAgentAvailability{
      device_uid: "device-1",
      agent_id: "agent-a",
      is_available: is_available,
      checked_at: checked_at
    }
  end

  test "available when the agent reached the device" do
    resolution = VantagePoint.resolve(input(900), row(true, DateTime.add(@now, -60)), @now)

    assert resolution.value == :available
    refute resolution.stale
    assert resolution.reason == nil
  end

  test "blocked when the agent got no positive response" do
    assert %{value: :blocked, stale: false} =
             VantagePoint.resolve(input(900), row(false, DateTime.add(@now, -60)), @now)
  end

  test "unknown with no_result when no row exists" do
    assert %{value: :unknown, reason: :no_result, observed_at: nil} =
             VantagePoint.resolve(input(900), nil, @now)
  end

  test "unknown with stale when the row is older than max_age" do
    checked_at = DateTime.add(@now, -1_000)
    resolution = VantagePoint.resolve(input(900), row(true, checked_at), @now)

    assert resolution.value == :unknown
    assert resolution.reason == :stale
    assert resolution.stale
    assert resolution.observed_at == checked_at
  end

  test "no max_age means the row is never stale" do
    assert %{value: :available, stale: false} =
             VantagePoint.resolve(input(nil), row(true, DateTime.add(@now, -1_000_000)), @now)
  end

  test "a row exactly at max_age is still fresh" do
    assert %{value: :available} =
             VantagePoint.resolve(input(900), row(true, DateTime.add(@now, -900)), @now)
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/resolvers/vantage_point_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Resolvers.VantagePoint is not available`.

- [ ] **Step 3: Implement the resolver**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/resolvers/vantage_point.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Resolvers.VantagePoint do
  @moduledoc """
  Resolves a `:vantage_point` input from a device's latest per-agent
  availability row.

  `:blocked` means *no positive response from any enabled probe from that
  vantage point*. It does NOT mean "provably filtered": per-target
  refused-vs-timeout outcomes are not carried from the scanner into sweep
  results, so a firewalled device and a powered-off device produce the same row.
  Distinguishing them is the job of a second vantage point that is expected to
  reach the device — the liveness witness.

  Pure: the caller batch-loads availability rows and passes the matching row (or
  `nil`) in. Nothing here touches the repo.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  @type value :: :available | :blocked | :unknown
  @type resolution :: %{
          value: value(),
          observed_at: DateTime.t() | nil,
          stale: boolean(),
          reason: nil | :no_result | :stale
        }

  @spec resolve(CompositeCheckInput.t(), DeviceAgentAvailability.t() | nil, DateTime.t()) ::
          resolution()
  def resolve(%CompositeCheckInput{} = input, row, now)

  def resolve(%CompositeCheckInput{}, nil, _now) do
    %{value: :unknown, observed_at: nil, stale: false, reason: :no_result}
  end

  def resolve(%CompositeCheckInput{config: config}, %DeviceAgentAvailability{} = row, now) do
    max_age = Map.get(config, "max_age_seconds")

    if stale?(row.checked_at, max_age, now) do
      %{value: :unknown, observed_at: row.checked_at, stale: true, reason: :stale}
    else
      %{value: value_for(row.is_available), observed_at: row.checked_at, stale: false, reason: nil}
    end
  end

  defp value_for(true), do: :available
  defp value_for(_), do: :blocked

  defp stale?(_checked_at, nil, _now), do: false
  defp stale?(nil, _max_age, _now), do: true

  defp stale?(checked_at, max_age, now) when is_integer(max_age) do
    DateTime.diff(now, checked_at, :second) > max_age
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/resolvers/vantage_point_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 5: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/resolvers/vantage_point.ex \
        test/serviceradar/composite_checks/resolvers/vantage_point_test.exs
git commit -m "feat(composite-checks): add vantage point input resolver"
```

---

### Task 7: Device metadata fact resolver

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/resolvers/device_metadata.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/resolvers/device_metadata_test.exs`

**Interfaces:**
- Consumes: a device metadata map (plain `map()`, not a Device struct — keeps the resolver pure and trivially testable).
- Produces: `ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata.resolve(input, metadata, now) :: resolution()` where `value` is `true | false | :unknown` and the rest of the shape matches Task 6.
- Establishes the provenance key Task 15 writes: `metadata["__fact_provenance"][path] = %{"source" => ..., "updated_at" => iso8601}`.

**Semantics that matter:** `max_age_seconds` is optional. When it is absent the input resolves on the stored value alone and does **not** require provenance — otherwise every metadata key that predates the provenance side-channel would resolve `:unknown` forever. When it is present, missing provenance means `:unknown`.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/resolvers/device_metadata_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.Resolvers.DeviceMetadataTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata

  @now ~U[2026-08-11 22:00:00.000000Z]

  defp input(max_age_seconds) do
    config =
      %{"path" => "nac_applied", "value_type" => "boolean"}
      |> then(fn c ->
        if max_age_seconds, do: Map.put(c, "max_age_seconds", max_age_seconds), else: c
      end)

    %CompositeCheckInput{key: "nac", kind: :device_metadata, config: config}
  end

  defp metadata(value, written_ago_seconds) do
    base = %{"nac_applied" => value}

    case written_ago_seconds do
      nil ->
        base

      seconds ->
        Map.put(base, "__fact_provenance", %{
          "nac_applied" => %{
            "source" => "nco",
            "updated_at" => @now |> DateTime.add(-seconds) |> DateTime.to_iso8601()
          }
        })
    end
  end

  test "fresh boolean fact resolves to its value" do
    assert %{value: true, stale: false} =
             DeviceMetadata.resolve(input(86_400), metadata(true, 7_200), @now)
  end

  test "false is a real value, not unknown" do
    assert %{value: false, stale: false} =
             DeviceMetadata.resolve(input(86_400), metadata(false, 7_200), @now)
  end

  test "stale fact resolves to unknown" do
    assert %{value: :unknown, reason: :stale, stale: true} =
             DeviceMetadata.resolve(input(86_400), metadata(true, 90_000), @now)
  end

  test "absent key resolves to unknown" do
    assert %{value: :unknown, reason: :absent} =
             DeviceMetadata.resolve(input(86_400), %{}, @now)
  end

  test "type mismatch resolves to unknown" do
    assert %{value: :unknown, reason: :type_mismatch} =
             DeviceMetadata.resolve(input(86_400), metadata("yes", 60), @now)
  end

  test "missing provenance with a max_age resolves to unknown" do
    assert %{value: :unknown, reason: :no_provenance} =
             DeviceMetadata.resolve(input(86_400), metadata(true, nil), @now)
  end

  test "missing provenance with no max_age resolves to the stored value" do
    assert %{value: true, stale: false, reason: nil} =
             DeviceMetadata.resolve(input(nil), metadata(true, nil), @now)
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/resolvers/device_metadata_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata is not available`.

- [ ] **Step 3: Implement the resolver**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/resolvers/device_metadata.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata do
  @moduledoc """
  Resolves a `:device_metadata` input from a device's metadata map.

  Freshness comes from the provenance side-channel that the device fact write
  API maintains at `metadata["__fact_provenance"][path]`. `max_age_seconds` is
  optional: without it the input resolves on the stored value alone and requires
  no provenance, so a metadata key written by a path that records none stays
  usable. With it, absent provenance is indistinguishable from an
  arbitrarily-old write and resolves `:unknown`.

  Pure: the caller passes the metadata map in.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput

  @provenance_key "__fact_provenance"

  @type value :: boolean() | :unknown
  @type resolution :: %{
          value: value(),
          observed_at: DateTime.t() | nil,
          stale: boolean(),
          reason: nil | :absent | :stale | :type_mismatch | :no_provenance
        }

  @spec resolve(CompositeCheckInput.t(), map() | nil, DateTime.t()) :: resolution()
  def resolve(input, metadata, now)

  def resolve(%CompositeCheckInput{} = input, nil, now), do: resolve(input, %{}, now)

  def resolve(%CompositeCheckInput{config: config}, metadata, now) when is_map(metadata) do
    path = Map.get(config, "path")
    max_age = Map.get(config, "max_age_seconds")

    case Map.fetch(metadata, path) do
      :error ->
        unknown(:absent, nil)

      {:ok, raw} ->
        case cast(raw, Map.get(config, "value_type")) do
          {:ok, value} -> apply_freshness(value, provenance_at(metadata, path), max_age, now)
          :error -> unknown(:type_mismatch, nil)
        end
    end
  end

  defp cast(value, "boolean") when is_boolean(value), do: {:ok, value}
  defp cast(_value, "boolean"), do: :error
  defp cast(_value, _type), do: :error

  defp apply_freshness(value, _observed_at, nil, _now) do
    %{value: value, observed_at: nil, stale: false, reason: nil}
  end

  defp apply_freshness(_value, nil, _max_age, _now), do: unknown(:no_provenance, nil)

  defp apply_freshness(value, observed_at, max_age, now) do
    if DateTime.diff(now, observed_at, :second) > max_age do
      %{value: :unknown, observed_at: observed_at, stale: true, reason: :stale}
    else
      %{value: value, observed_at: observed_at, stale: false, reason: nil}
    end
  end

  defp provenance_at(metadata, path) do
    with %{} = provenance <- Map.get(metadata, @provenance_key),
         %{} = entry <- Map.get(provenance, path),
         updated_at when is_binary(updated_at) <- Map.get(entry, "updated_at"),
         {:ok, parsed, _offset} <- DateTime.from_iso8601(updated_at) do
      parsed
    else
      _ -> nil
    end
  end

  defp unknown(reason, observed_at) do
    %{value: :unknown, observed_at: observed_at, stale: reason == :stale, reason: reason}
  end

  @doc "The metadata key under which per-fact provenance is stored."
  def provenance_key, do: @provenance_key
end
```

- [ ] **Step 4: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/resolvers/device_metadata_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 5: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/resolvers/device_metadata.ex \
        test/serviceradar/composite_checks/resolvers/device_metadata_test.exs
git commit -m "feat(composite-checks): add device metadata fact resolver with optional freshness"
```

---

### Task 8: The pure evaluator

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluator.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluator_test.exs`

**Interfaces:**
- Consumes: rule structs from Task 3 (only `position`, `match`, `verdict`, `status`, `id`, `catch_all` are read).
- Produces: `ServiceRadar.CompositeChecks.Evaluator.verdict(inputs, rules) :: {:ok, decision()} | {:error, :no_matching_rule}` where

  ```elixir
  @type decision :: %{verdict: String.t(), status: atom(), matched_rule_id: Ash.UUID.t() | nil}
  ```

  `inputs` is `%{input_key => resolved_value}` — the `:value` field of a resolution, not the whole resolution map. Task 11 unwraps.

**This is the single most important module in the plan.** Three callers share it — the scheduled worker, the debounced refresh, and Plan 3's preview — which is what guarantees a preview cannot disagree with production. It must have zero I/O: no `alias ServiceRadar.Repo`, no `Ash.` calls.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluator_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.EvaluatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.Evaluator

  defp rule(position, match, verdict, status, opts \\ []) do
    %CompositeCheckRule{
      id: "rule-#{position}",
      position: position,
      match: match,
      verdict: verdict,
      status: status,
      catch_all: Keyword.get(opts, :catch_all, false)
    }
  end

  # The isolation table from the design mock, verbatim.
  defp isolation_rules do
    [
      rule(0, %{"a" => "available", "b" => "blocked", "nac" => true}, "isolated_verified", :healthy),
      rule(1, %{"a" => "available", "b" => "blocked", "nac" => false}, "isolated_unenforced", :degraded),
      rule(2, %{"a" => "available", "b" => "available"}, "not_isolated", :down),
      rule(3, %{"a" => "blocked", "b" => "blocked"}, "device_unreachable", :degraded),
      rule(4, %{"a" => "blocked", "b" => "available"}, "inverted_reachability", :down),
      rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
    ]
  end

  describe "the isolation decision table" do
    test "isolation observed and config enforced" do
      assert {:ok, %{verdict: "isolated_verified", status: :healthy, matched_rule_id: "rule-0"}} =
               Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => true}, isolation_rules())
    end

    test "isolation observed but config not applied" do
      assert {:ok, %{verdict: "isolated_unenforced", status: :degraded}} =
               Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => false}, isolation_rules())
    end

    test "reachable from the network that should be fenced off" do
      assert {:ok, %{verdict: "not_isolated", status: :down}} =
               Evaluator.verdict(%{"a" => :available, "b" => :available, "nac" => true}, isolation_rules())
    end

    test "nobody can see it, so isolation cannot be proven" do
      assert {:ok, %{verdict: "device_unreachable", status: :degraded}} =
               Evaluator.verdict(%{"a" => :blocked, "b" => :blocked, "nac" => true}, isolation_rules())
    end

    test "the wrong network has access and the right one does not" do
      assert {:ok, %{verdict: "inverted_reachability", status: :down}} =
               Evaluator.verdict(%{"a" => :blocked, "b" => :available, "nac" => false}, isolation_rules())
    end

    test "an unknown input falls through to the catch-all" do
      assert {:ok, %{verdict: "inconclusive", status: :unknown, matched_rule_id: "rule-1000000"}} =
               Evaluator.verdict(%{"a" => :unknown, "b" => :blocked, "nac" => true}, isolation_rules())
    end

    test "a stale nac fact still isolates but cannot confirm enforcement" do
      assert {:ok, %{verdict: "inconclusive"}} =
               Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => :unknown}, isolation_rules())
    end
  end

  describe "matching semantics" do
    test "first match wins even when a later rule also matches" do
      rules = [
        rule(0, %{"a" => "available"}, "first", :healthy),
        rule(1, %{"a" => "available"}, "second", :down),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "first"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "an input key absent from the match map is a wildcard" do
      rules = [
        rule(0, %{"a" => "available"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "matched"}} =
               Evaluator.verdict(%{"a" => :available, "b" => :blocked}, rules)
    end

    test "an explicit wildcard string matches any value" do
      rules = [
        rule(0, %{"a" => "*", "b" => "blocked"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "matched"}} =
               Evaluator.verdict(%{"a" => :unknown, "b" => :blocked}, rules)
    end

    test "a list matcher matches any member" do
      rules = [
        rule(0, %{"a" => ["blocked", "unknown"]}, "not_reachable", :degraded),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "not_reachable"}} = Evaluator.verdict(%{"a" => :unknown}, rules)
      assert {:ok, %{verdict: "not_reachable"}} = Evaluator.verdict(%{"a" => :blocked}, rules)
      assert {:ok, %{verdict: "inconclusive"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "booleans match booleans and their string forms" do
      rules = [
        rule(0, %{"nac" => true}, "enforced", :healthy),
        rule(1, %{"nac" => "false"}, "unenforced", :degraded),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "enforced"}} = Evaluator.verdict(%{"nac" => true}, rules)
      assert {:ok, %{verdict: "unenforced"}} = Evaluator.verdict(%{"nac" => false}, rules)
    end

    test "a match on an input that was not resolved does not match" do
      rules = [
        rule(0, %{"missing" => "available"}, "matched", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "inconclusive"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "rules are evaluated in position order regardless of list order" do
      rules = [
        rule(5, %{"a" => "available"}, "later", :down),
        rule(0, %{"a" => "available"}, "earlier", :healthy),
        rule(1_000_000, %{}, "inconclusive", :unknown, catch_all: true)
      ]

      assert {:ok, %{verdict: "earlier"}} = Evaluator.verdict(%{"a" => :available}, rules)
    end

    test "errors when no rule matches and there is no catch-all" do
      assert {:error, :no_matching_rule} =
               Evaluator.verdict(%{"a" => :available}, [rule(0, %{"a" => "blocked"}, "x", :down)])
    end
  end

  describe "totality" do
    test "every combination of input values matches exactly one rule" do
      values = [:available, :blocked, :unknown]
      nac_values = [true, false, :unknown]

      for a <- values, b <- values, nac <- nac_values do
        inputs = %{"a" => a, "b" => b, "nac" => nac}

        assert {:ok, decision} = Evaluator.verdict(inputs, isolation_rules()),
               "no rule matched #{inspect(inputs)}"

        assert is_binary(decision.verdict)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/evaluator_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Evaluator is not available`.

- [ ] **Step 3: Implement the evaluator**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluator.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Evaluator do
  @moduledoc """
  Decision table evaluation for composite checks. Pure — no I/O, no repo, no Ash.

  Rules are sorted by ascending `position` and the first match wins. A rule
  matches when every key in its `match` map matches the corresponding resolved
  input value. Semantics:

    * a key absent from `match` is a wildcard
    * the string `"*"` is an explicit wildcard
    * a list matches if the value matches any member
    * values compare by their string form, so `:available` matches `"available"`
      and `true` matches `"true"`

  The trailing catch-all rule (empty `match`) is what makes the table total: it
  matches everything, so every input combination resolves to a verdict. A table
  without one can return `{:error, :no_matching_rule}`, which callers treat as a
  configuration fault rather than a verdict.

  This function is shared by the scheduled pass, the per-device refresh, and the
  authoring preview. That sharing is deliberate: it is what guarantees a preview
  cannot produce a different verdict than a persisted evaluation.
  """

  @type input_value :: atom() | boolean() | String.t()
  @type decision :: %{verdict: String.t(), status: atom(), matched_rule_id: term()}

  @wildcard "*"

  @spec verdict(%{optional(String.t()) => input_value()}, [struct()]) ::
          {:ok, decision()} | {:error, :no_matching_rule}
  def verdict(inputs, rules) when is_map(inputs) and is_list(rules) do
    normalized = Map.new(inputs, fn {key, value} -> {to_string(key), normalize(value)} end)

    rules
    |> Enum.sort_by(& &1.position)
    |> Enum.find(&matches?(&1, normalized))
    |> case do
      nil ->
        {:error, :no_matching_rule}

      rule ->
        {:ok, %{verdict: rule.verdict, status: rule.status, matched_rule_id: rule.id}}
    end
  end

  defp matches?(%{match: match}, inputs) when is_map(match) do
    Enum.all?(match, fn {key, matcher} ->
      matches_value?(matcher, Map.get(inputs, to_string(key), :__absent__))
    end)
  end

  defp matches_value?(_matcher, :__absent__), do: false
  defp matches_value?(@wildcard, _value), do: true

  defp matches_value?(matcher, value) when is_list(matcher) do
    Enum.any?(matcher, &matches_value?(&1, value))
  end

  defp matches_value?(matcher, value), do: normalize(matcher) == value

  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: to_string(value)
end
```

- [ ] **Step 4: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/evaluator_test.exs`
Expected: PASS, 15 tests including the 27-combination totality check.

- [ ] **Step 5: Verify the evaluator is actually pure**

Run: `rg -n "Repo|Ash\.|Ecto" elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluator.ex`
Expected: no output. If anything matches, move that code into `evaluation.ex` (Task 11) — the evaluator must stay callable from a unit test with no database.

- [ ] **Step 6: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/evaluator.ex \
        test/serviceradar/composite_checks/evaluator_test.exs
git commit -m "feat(composite-checks): add the pure decision table evaluator"
```

---

### Task 9: Scope resolution and vantage point coverage

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/scope.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/coverage.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/coverage_test.exs`

**Interfaces:**
- Consumes: `ServiceRadar.Observability.SRQLRunner.query_page/2`, `ServiceRadar.SRQLQuery.ensure_target/2`, `ServiceRadar.SRQLAst.entity/1`.
- Produces:
  - `Scope.normalize(query) :: {:ok, String.t()} | {:error, :scope_must_target_devices}`
  - `Scope.stream_uids(query, opts) :: Enumerable.t()` yielding lists of device UIDs, one list per page. `opts[:page_limit]` defaults to 1000, `opts[:runner]` defaults to `SRQLRunner` so tests can inject.
  - `Scope.count(query, opts) :: {:ok, non_neg_integer()} | {:error, term()}`
  - `Coverage.for_check(check, inputs, opts) :: {:ok, [coverage_row()]} | {:error, term()}` where
    ```elixir
    @type coverage_row :: %{
            input_key: String.t(),
            agent_id: String.t(),
            covered: non_neg_integer(),
            total: non_neg_integer()
          }
    ```

**Why a separate module from the evaluation pass:** Plan 3's builder calls `Scope.count/2` and `Coverage.for_check/3` on every keystroke in the scope field, without running an evaluation. Keeping them apart means the builder never risks writing results.

- [ ] **Step 1: Read the paging pattern to copy**

Run: `sed -n '89,122p' elixir/serviceradar_core/lib/serviceradar/inventory/availability_source_profile_materializer.ex`

That is `collect_device_uids/5` — cursor-based paging over `SRQLRunner.query_page/2`, accumulating into a `MapSet`. `Scope.stream_uids/2` is the same traversal expressed as a `Stream.resource/3` so a large scope never materializes every UID at once.

- [ ] **Step 2: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/coverage_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.CoverageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.Scope

  defmodule StubRunner do
    @moduledoc false

    def query_page(_query, opts) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, %{rows: [%{"uid" => "device-1"}, %{"uid" => "device-2"}], next_cursor: "c1"}}

        "c1" ->
          {:ok, %{rows: [%{"uid" => "device-3"}], next_cursor: nil}}
      end
    end
  end

  describe "normalize/1" do
    test "accepts a device query" do
      assert {:ok, normalized} = Scope.normalize("in:devices source:armis")
      assert normalized =~ "devices"
    end

    test "rejects a non-device query" do
      assert {:error, :scope_must_target_devices} = Scope.normalize("in:flows src_ip:10.0.0.1")
    end
  end

  describe "stream_uids/2" do
    test "pages until the cursor runs out" do
      pages =
        "in:devices"
        |> Scope.stream_uids(runner: StubRunner, page_limit: 2)
        |> Enum.to_list()

      assert pages == [["device-1", "device-2"], ["device-3"]]
    end

    test "count sums every page" do
      assert {:ok, 3} = Scope.count("in:devices", runner: StubRunner, page_limit: 2)
    end
  end
end
```

- [ ] **Step 3: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/coverage_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Scope is not available`.

- [ ] **Step 4: Implement Scope**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/scope.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Scope do
  @moduledoc """
  Resolves a composite check's SRQL scope into device UIDs, one page at a time.

  A scope can select a very large device population, so callers stream pages
  rather than collecting every UID. `page_limit` bounds both the SRQL page and
  the per-page input queries the evaluation pass issues.
  """

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @default_page_limit 1_000

  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :scope_must_target_devices}
  def normalize(query) when is_binary(query) do
    normalized = SRQLQuery.ensure_target(query, :devices)

    if SRQLAst.entity(normalized) == "devices" do
      {:ok, normalized}
    else
      {:error, :scope_must_target_devices}
    end
  end

  @spec stream_uids(String.t(), keyword()) :: Enumerable.t()
  def stream_uids(query, opts \\ []) do
    runner = Keyword.get(opts, :runner, SRQLRunner)
    page_limit = Keyword.get(opts, :page_limit, @default_page_limit)

    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :done ->
          {:halt, :done}

        {step, cursor} ->
          query_opts =
            [limit: page_limit]
            |> then(fn o -> if step == :start, do: o, else: Keyword.put(o, :cursor, cursor) end)

          case runner.query_page(query, query_opts) do
            {:ok, %{rows: rows, next_cursor: next_cursor}} ->
              uids = Enum.flat_map(rows, &extract_uid/1)
              next = if blank?(next_cursor), do: :done, else: {:more, next_cursor}
              {[uids], next}

            {:error, reason} ->
              raise "composite check scope query failed: #{inspect(reason)}"
          end
      end,
      fn _ -> :ok end
    )
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(query, opts \\ []) do
    total =
      query
      |> stream_uids(opts)
      |> Enum.reduce(0, fn page, acc -> acc + length(page) end)

    {:ok, total}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp extract_uid(row) when is_map(row) do
    case Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") || Map.get(row, :id) do
      uid when is_binary(uid) and uid != "" -> [uid]
      _ -> []
    end
  end

  defp extract_uid(_row), do: []

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc false
  def default_page_limit, do: @default_page_limit
end
```

- [ ] **Step 5: Implement Coverage**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/coverage.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Coverage do
  @moduledoc """
  Counts, per vantage point, how many devices in a check's scope have a
  non-stale availability row for that agent.

  This is the mitigation for the one structural weakness of a derivation-only
  design: a check whose vantage point has no sweep wired reports `inconclusive`
  forever and looks like it is working. Coverage turns that silence into a
  number the operator sees before enabling.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  @type coverage_row :: %{
          input_key: String.t(),
          agent_id: String.t(),
          covered: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec for_check(struct(), [struct()], keyword()) :: {:ok, [coverage_row()]} | {:error, term()}
  def for_check(check, inputs, opts \\ []) do
    vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

    with {:ok, normalized} <- Scope.normalize(check.scope_query) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {total, counts} =
        normalized
        |> Scope.stream_uids(opts)
        |> Enum.reduce({0, %{}}, fn uids, {total_acc, counts_acc} ->
          {total_acc + length(uids), tally_page(vantage_points, uids, now, counts_acc)}
        end)

      rows =
        Enum.map(vantage_points, fn input ->
          %{
            input_key: input.key,
            agent_id: Map.get(input.config, "agent_id"),
            covered: Map.get(counts, input.key, 0),
            total: total
          }
        end)

      {:ok, rows}
    end
  end

  defp tally_page(vantage_points, uids, now, counts) do
    Enum.reduce(vantage_points, counts, fn input, acc ->
      agent_id = Map.get(input.config, "agent_id")
      max_age = Map.get(input.config, "max_age_seconds")

      count =
        DeviceAgentAvailability
        |> where([r], r.device_uid in ^uids and r.agent_id == ^agent_id)
        |> apply_freshness(max_age, now)
        |> select([r], count(r.id))
        |> Repo.one()
        |> Kernel.||(0)

      Map.update(acc, input.key, count, &(&1 + count))
    end)
  end

  defp apply_freshness(query, nil, _now), do: query

  defp apply_freshness(query, max_age, now) when is_integer(max_age) do
    cutoff = DateTime.add(now, -max_age, :second)
    where(query, [r], r.checked_at >= ^cutoff)
  end
end
```

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/coverage_test.exs`
Expected: PASS, 4 tests. `Coverage.for_check/3` is exercised end-to-end in Task 17 where real availability rows exist.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/scope.ex \
        lib/serviceradar/composite_checks/coverage.ex \
        test/serviceradar/composite_checks/coverage_test.exs
git commit -m "feat(composite-checks): add scope paging and vantage point coverage"
```

---

### Task 10: Seed rules from vantage point expectations

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/rule_generator.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/rule_generator_test.exs`

**Interfaces:**
- Consumes: `CompositeCheckInput` structs (Task 2) — reads `key`, `kind`, `expected`.
- Produces: `RuleGenerator.generate(inputs) :: [rule_attrs()]` where `rule_attrs` is a map ready for `CompositeCheckRule` `:create`: `%{position:, match:, verdict:, verdict_label:, verdict_description:, status:}`. The catch-all is **not** generated — it already exists from Task 3.

**The semantic that matters:** `expected` seeds rules and nothing else. The evaluator never reads it. Once generated, the rule table is authoritative and freely editable; regeneration warns before overwriting. Assert this in the test so a later refactor cannot quietly make expectations load-bearing.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/rule_generator_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.RuleGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Evaluator
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.RuleGenerator

  defp vantage(key, expected) do
    %CompositeCheckInput{
      key: key,
      kind: :vantage_point,
      expected: expected,
      config: %{"agent_id" => key}
    }
  end

  defp fact(key) do
    %CompositeCheckInput{
      key: key,
      kind: :device_metadata,
      config: %{"path" => key, "value_type" => "boolean"}
    }
  end

  defp as_rules(attrs_list) do
    attrs_list
    |> Enum.map(&struct(CompositeCheckRule, Map.put(&1, :id, "rule-#{&1.position}")))
    |> Kernel.++([
      %CompositeCheckRule{
        id: "catch-all",
        position: 1_000_000,
        match: %{},
        verdict: "inconclusive",
        status: :unknown,
        catch_all: true
      }
    ])
  end

  test "generates the four isolation cases for two vantage points and a fact" do
    inputs = [vantage("a", "available"), vantage("b", "blocked"), fact("nac")]

    verdicts = inputs |> RuleGenerator.generate() |> Enum.map(& &1.verdict)

    assert verdicts == [
             "isolated_verified",
             "isolated_unenforced",
             "not_isolated",
             "device_unreachable",
             "inverted_reachability"
           ]
  end

  test "generated rules classify the expected pattern as healthy" do
    rules =
      [vantage("a", "available"), vantage("b", "blocked"), fact("nac")]
      |> RuleGenerator.generate()
      |> as_rules()

    assert {:ok, %{verdict: "isolated_verified", status: :healthy}} =
             Evaluator.verdict(%{"a" => :available, "b" => :blocked, "nac" => true}, rules)

    assert {:ok, %{verdict: "not_isolated", status: :down}} =
             Evaluator.verdict(%{"a" => :available, "b" => :available, "nac" => true}, rules)

    assert {:ok, %{verdict: "device_unreachable", status: :degraded}} =
             Evaluator.verdict(%{"a" => :blocked, "b" => :blocked, "nac" => true}, rules)
  end

  test "omits the fact rows when no metadata input is declared" do
    verdicts =
      [vantage("a", "available"), vantage("b", "blocked")]
      |> RuleGenerator.generate()
      |> Enum.map(& &1.verdict)

    assert verdicts == [
             "isolated_verified",
             "not_isolated",
             "device_unreachable",
             "inverted_reachability"
           ]

    refute "isolated_unenforced" in verdicts
  end

  test "generates nothing useful without two vantage points" do
    assert RuleGenerator.generate([vantage("a", "available")]) == []
  end

  test "positions are sequential and leave room before the catch-all" do
    rules = RuleGenerator.generate([vantage("a", "available"), vantage("b", "blocked")])

    assert Enum.map(rules, & &1.position) == [0, 1, 2, 3]
    assert Enum.all?(rules, &(&1.position < 1_000_000))
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/rule_generator_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.RuleGenerator is not available`.

- [ ] **Step 3: Implement the generator**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/rule_generator.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.RuleGenerator do
  @moduledoc """
  Seeds a decision table from vantage point expectations.

  Generation is an authoring convenience only. The evaluator never reads
  `expected`; once rules exist they are the sole source of evaluation semantics
  and may be edited freely. Regenerating warns before discarding edits.

  The generated table covers the four cases two vantage points can produce, and
  splits the expected case on a boolean fact when one is declared:

    * expected pattern + fact true  -> isolated_verified   (healthy)
    * expected pattern + fact false -> isolated_unenforced (degraded)
    * both reachable                -> not_isolated        (down)
    * neither reachable             -> device_unreachable  (degraded)
    * inverted                      -> inverted_reachability (down)

  Anything not covered falls through to the check's catch-all.
  """

  @spec generate([struct()]) :: [map()]
  def generate(inputs) when is_list(inputs) do
    vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

    with [witness | _] <- Enum.filter(vantage_points, &(&1.expected == "available")),
         [probe | _] <- Enum.filter(vantage_points, &(&1.expected == "blocked")) do
      fact = Enum.find(inputs, &(&1.kind == :device_metadata))

      witness.key
      |> rows(probe.key, fact)
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> Map.put(row, :position, index) end)
    else
      _ -> []
    end
  end

  defp rows(witness_key, probe_key, nil) do
    [
      row(%{witness_key => "available", probe_key => "blocked"}, "isolated_verified", :healthy,
        "Isolation observed from every vantage point that should not reach it"),
      not_isolated(witness_key, probe_key),
      device_unreachable(witness_key, probe_key),
      inverted(witness_key, probe_key)
    ]
  end

  defp rows(witness_key, probe_key, fact) do
    [
      row(
        %{witness_key => "available", probe_key => "blocked", fact.key => true},
        "isolated_verified",
        :healthy,
        "Isolation observed, and the config that enforces it is in place"
      ),
      row(
        %{witness_key => "available", probe_key => "blocked", fact.key => false},
        "isolated_unenforced",
        :degraded,
        "Blocked today, but not by device config — likely an upstream ACL that could change"
      ),
      not_isolated(witness_key, probe_key),
      device_unreachable(witness_key, probe_key),
      inverted(witness_key, probe_key)
    ]
  end

  defp not_isolated(witness_key, probe_key) do
    row(
      %{witness_key => "available", probe_key => "available"},
      "not_isolated",
      :down,
      "Reachable from a network that should be fenced off"
    )
  end

  defp device_unreachable(witness_key, probe_key) do
    row(
      %{witness_key => "blocked", probe_key => "blocked"},
      "device_unreachable",
      :degraded,
      "Nobody can see it — the device is probably down, so isolation cannot be proven either way"
    )
  end

  defp inverted(witness_key, probe_key) do
    row(
      %{witness_key => "blocked", probe_key => "available"},
      "inverted_reachability",
      :down,
      "The wrong network has access and the right one does not — check routing or agent placement"
    )
  end

  defp row(match, verdict, status, description) do
    %{
      match: match,
      verdict: verdict,
      verdict_label: verdict |> String.replace("_", " ") |> String.capitalize(),
      verdict_description: description,
      status: status
    }
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/rule_generator_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/rule_generator.ex \
        test/serviceradar/composite_checks/rule_generator_test.exs
git commit -m "feat(composite-checks): seed decision tables from vantage point expectations"
```

---

### Task 11: The evaluation pass

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluation.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluation_test.exs`

**Interfaces:**
- Consumes: `Scope.normalize/1` and `.stream_uids/2` (Task 9), `Resolvers.VantagePoint.resolve/3` (Task 6), `Resolvers.DeviceMetadata.resolve/3` (Task 7), `Evaluator.verdict/2` (Task 8), `DeviceCompositeCheckResult` `:upsert` (Task 4).
- Produces:
  - `Evaluation.run(check, opts) :: {:ok, summary()} | {:error, term()}` where
    ```elixir
    @type summary :: %{
            evaluated: non_neg_integer(),
            transitions: [transition()],
            removed: non_neg_integer()
          }
    @type transition :: %{
            device_uid: String.t(),
            check_id: Ash.UUID.t(),
            from_verdict: String.t() | nil,
            to_verdict: String.t(),
            from_status: atom() | nil,
            to_status: atom(),
            inputs: map()
          }
    ```
  - `Evaluation.evaluate_devices(check, inputs, rules, uids, opts) :: {:ok, [evaluation_row()]}` — resolves and evaluates without persisting. Plan 3's preview calls exactly this, which is what makes preview and production share a code path.

**Two design points to preserve:**

1. **No N+1.** Per page, issue exactly one availability query and one device-metadata query, then resolve in memory. The resolvers from Tasks 6 and 7 are pure precisely so this is possible.
2. **Mark-and-sweep for scope exit.** Rather than accumulating every evaluated UID to diff against, stamp `evaluated_at` with the pass start time and afterwards delete this check's rows whose `evaluated_at` is older than it. Bounded memory regardless of scope size.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluation_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.EvaluationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  defmodule ScopeRunner do
    @moduledoc false
    def query_page(_query, _opts) do
      uids = Process.get(:scope_uids, ["device-1"])
      {:ok, %{rows: Enum.map(uids, &%{"uid" => &1}), next_cursor: nil}}
    end
  end

  defp availability(device_uid, agent_id, is_available, checked_at) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: is_available,
        checked_at: checked_at
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp build_check do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Eval #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    inputs =
      for {key, expected, position} <- [{"a", "available", 0}, {"b", "blocked", 1}] do
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          %{
            check_id: check.id,
            key: key,
            label: key,
            position: position,
            kind: :vantage_point,
            expected: expected,
            config: %{"agent_id" => "agent-#{key}", "max_age_seconds" => 900}
          },
          actor: actor()
        )
        |> Ash.create!()
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    check
  end

  setup do
    Process.put(:scope_uids, ["device-1"])
    %{check: build_check()}
  end

  defp run(check) do
    Evaluation.run(check, actor: actor(), runner: ScopeRunner)
  end

  test "two agents disagreeing produces the isolated verdict", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, summary} = run(check)
    assert summary.evaluated == 1

    assert {:ok, result} =
             DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "isolated_verified"
    assert result.status == :healthy
    assert result.inputs["a"]["value"] == "available"
    assert result.inputs["b"]["value"] == "blocked"
  end

  test "reachable from both is a real finding", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", true, now)

    assert {:ok, _} = run(check)

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "not_isolated"
    assert result.status == :down
  end

  test "unreachable from every vantage point is not compliant", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", false, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, _} = run(check)

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "device_unreachable"
    assert result.status == :degraded
  end

  test "a missing vantage point falls through to inconclusive", %{check: check} do
    availability("device-1", "agent-a", true, DateTime.utc_now())

    assert {:ok, _} = run(check)

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "inconclusive"
    assert result.inputs["b"]["reason"] == "no_result"
  end

  test "a stale availability row falls through to inconclusive", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, DateTime.add(now, -5_000))

    assert {:ok, _} = run(check)

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "inconclusive"
    assert result.inputs["b"]["stale"]
  end

  test "changed_at advances only when the verdict changes", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, first} = run(check)
    assert [%{from_verdict: nil, to_verdict: "isolated_verified"}] = first.transitions

    {:ok, initial} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert {:ok, second} = run(check)
    assert second.transitions == []

    {:ok, again} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert again.changed_at == initial.changed_at
    assert DateTime.compare(again.evaluated_at, initial.evaluated_at) in [:gt, :eq]
  end

  test "a device leaving scope loses its result row", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, _} = run(check)

    Process.put(:scope_uids, ["device-2"])
    assert {:ok, summary} = run(check)
    assert summary.removed == 1

    assert {:error, _} =
             DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/evaluation_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Evaluation is not available`.

- [ ] **Step 3: Implement the pass**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluation.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Evaluation do
  @moduledoc """
  Runs one evaluation pass for a composite check.

  Per page of the scope, exactly one availability query and one device-metadata
  query are issued; resolution and evaluation happen in memory, because the
  resolvers and the evaluator are pure. That is what keeps a pass over a large
  scope from becoming an N+1.

  Scope exit is handled by mark-and-sweep rather than by diffing UID sets: every
  row written in a pass carries the pass start time in `evaluated_at`, and rows
  older than that at the end of the pass belonged to devices that are no longer
  in scope. Memory stays bounded no matter how large the scope is.
  """

  import Ecto.Query

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluator
  alias ServiceRadar.CompositeChecks.Resolvers
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Repo

  require Logger

  @type transition :: %{
          device_uid: String.t(),
          check_id: Ash.UUID.t(),
          from_verdict: String.t() | nil,
          to_verdict: String.t(),
          from_status: atom() | nil,
          to_status: atom(),
          inputs: map()
        }

  @type summary :: %{
          evaluated: non_neg_integer(),
          transitions: [transition()],
          removed: non_neg_integer()
        }

  @spec run(struct(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    started_at = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, normalized} <- Scope.normalize(check.scope_query),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check.id, actor: actor) do
      {evaluated, transitions} =
        normalized
        |> Scope.stream_uids(opts)
        |> Enum.reduce({0, []}, fn uids, {count, acc} ->
          {:ok, rows} = evaluate_devices(check, inputs, rules, uids, opts)
          page_transitions = persist_page(check, rows, started_at, actor)
          {count + length(rows), acc ++ page_transitions}
        end)

      removed = sweep_out_of_scope(check, started_at)

      {:ok, %{evaluated: evaluated, transitions: transitions, removed: removed}}
    end
  end

  @doc """
  Resolves inputs and evaluates verdicts for a set of device UIDs without
  persisting anything. The authoring preview calls this directly, which is what
  guarantees preview and production cannot disagree.
  """
  @spec evaluate_devices(struct(), [struct()], [struct()], [String.t()], keyword()) ::
          {:ok, [map()]}
  def evaluate_devices(check, inputs, rules, uids, opts \\ [])

  def evaluate_devices(_check, _inputs, _rules, [], _opts), do: {:ok, []}

  def evaluate_devices(check, inputs, rules, uids, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    availability = load_availability(inputs, uids)
    metadata = load_metadata(inputs, uids)

    rows =
      Enum.map(uids, fn uid ->
        resolutions = resolve_inputs(inputs, uid, availability, metadata, now)
        values = Map.new(resolutions, fn {key, resolution} -> {key, resolution.value} end)

        {verdict, status, matched_rule_id} =
          case Evaluator.verdict(values, rules) do
            {:ok, decision} ->
              {decision.verdict, decision.status, decision.matched_rule_id}

            {:error, :no_matching_rule} ->
              Logger.warning("composite check has no matching rule and no catch-all",
                check_id: check.id,
                device_uid: uid
              )

              {"inconclusive", :unknown, nil}
          end

        %{
          device_uid: uid,
          verdict: verdict,
          status: status,
          matched_rule_id: matched_rule_id,
          inputs: snapshot(resolutions)
        }
      end)

    {:ok, rows}
  end

  defp resolve_inputs(inputs, uid, availability, metadata, now) do
    Map.new(inputs, fn input ->
      resolution =
        case input.kind do
          :vantage_point ->
            agent_id = Map.get(input.config, "agent_id")
            row = get_in(availability, [uid, agent_id])
            Resolvers.VantagePoint.resolve(input, row, now)

          :device_metadata ->
            Resolvers.DeviceMetadata.resolve(input, Map.get(metadata, uid, %{}), now)
        end

      {input.key, resolution}
    end)
  end

  defp snapshot(resolutions) do
    Map.new(resolutions, fn {key, resolution} ->
      {key,
       %{
         "value" => to_string(resolution.value),
         "observed_at" => resolution.observed_at && DateTime.to_iso8601(resolution.observed_at),
         "stale" => resolution.stale,
         "reason" => resolution.reason && to_string(resolution.reason)
       }}
    end)
  end

  defp load_availability(inputs, uids) do
    agent_ids =
      inputs
      |> Enum.filter(&(&1.kind == :vantage_point))
      |> Enum.map(&Map.get(&1.config, "agent_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if agent_ids == [] do
      %{}
    else
      DeviceAgentAvailability
      |> where([r], r.device_uid in ^uids and r.agent_id in ^agent_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.device_uid)
      |> Map.new(fn {uid, rows} -> {uid, Map.new(rows, &{&1.agent_id, &1})} end)
    end
  end

  defp load_metadata(inputs, uids) do
    if Enum.any?(inputs, &(&1.kind == :device_metadata)) do
      Device
      |> where([d], d.uid in ^uids)
      |> select([d], {d.uid, d.metadata})
      |> Repo.all()
      |> Map.new()
    else
      %{}
    end
  end

  defp persist_page(check, rows, started_at, actor) do
    existing =
      DeviceCompositeCheckResult
      |> where([r], r.check_id == ^check.id and r.device_uid in ^Enum.map(rows, & &1.device_uid))
      |> Repo.all()
      |> Map.new(&{&1.device_uid, &1})

    Enum.flat_map(rows, fn row ->
      prior = Map.get(existing, row.device_uid)
      changed? = is_nil(prior) or prior.verdict != row.verdict
      changed_at = if changed?, do: started_at, else: prior.changed_at

      DeviceCompositeCheckResult
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: row.device_uid,
          check_id: check.id,
          verdict: row.verdict,
          status: row.status,
          matched_rule_id: row.matched_rule_id,
          inputs: row.inputs,
          evaluated_at: started_at,
          changed_at: changed_at
        },
        actor: actor,
        upsert?: true,
        upsert_identity: :unique_device_check
      )
      |> Ash.create!()

      if changed? do
        [
          %{
            device_uid: row.device_uid,
            check_id: check.id,
            from_verdict: prior && prior.verdict,
            to_verdict: row.verdict,
            from_status: prior && prior.status,
            to_status: row.status,
            inputs: row.inputs
          }
        ]
      else
        []
      end
    end)
  end

  defp sweep_out_of_scope(check, started_at) do
    {count, _} =
      DeviceCompositeCheckResult
      |> where([r], r.check_id == ^check.id and r.evaluated_at < ^started_at)
      |> Repo.delete_all()

    count
  end
end
```

- [ ] **Step 4: Create the resolver dispatch module**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/resolvers.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Resolvers do
  @moduledoc """
  Namespace for input resolvers.

  Adding an input kind means adding a module here, a clause in
  `ServiceRadar.CompositeChecks.Validations.InputConfig`, and a clause in
  `ServiceRadar.CompositeChecks.Evaluation.resolve_inputs/5`. Rule structure,
  result storage, and the evaluator are unaffected — that is the extension seam.
  """

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.CompositeChecks.Resolvers.VantagePoint

  defdelegate resolve_vantage_point(input, row, now), to: VantagePoint, as: :resolve
  defdelegate resolve_device_metadata(input, metadata, now), to: DeviceMetadata, as: :resolve
end
```

Note: `Evaluation` references `Resolvers.VantagePoint` and `Resolvers.DeviceMetadata` directly rather than through the delegates, so this module exists for documentation and for external callers. If Credo flags the unused delegates, delete them and keep the moduledoc.

- [ ] **Step 5: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/evaluation_test.exs`
Expected: PASS, 7 tests.

If `DeviceAgentAvailability` create fails on a required attribute the fixture omits, run `rg -n "allow_nil\? false" lib/serviceradar/inventory/device_agent_availability.ex` and add the missing fields to the fixture rather than loosening the resource.

- [ ] **Step 6: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/evaluation.ex \
        lib/serviceradar/composite_checks/resolvers.ex \
        test/serviceradar/composite_checks/evaluation_test.exs
git commit -m "feat(composite-checks): add the batched evaluation pass with scope-exit sweep"
```

---

### Task 12: Verdict transition events

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/verdict_event_writer.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/verdict_event_writer_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluation.ex` (emit at the end of `run/2`)

**Interfaces:**
- Consumes: `Evaluation.run/2`'s `transitions` list (Task 11), `ServiceRadar.Monitoring.OcsfEvent` `:record`, `ServiceRadar.EventWriter.OCSF` helpers, `ServiceRadar.Actors.SystemActor`.
- Produces: `VerdictEventWriter.write_transitions(check, transitions) :: :ok`.

**The path, and why it is not JetStream:** the AGENTS.md JetStream-first rule governs *metrics*. Verdicts are derived state, and core-originated OCSF events go straight to `ocsf_events` through a system-actor `Ash.create/3` — see `credentials/credential_event_writer.ex:281`. Do not build a JetStream producer for this.

**Failure must not cascade.** A verdict has already been persisted by the time an event is written; failing the pass because the event write failed would discard correct results. Log and swallow, exactly as `record_event/1` does at `credential_event_writer.ex:289-296`.

- [ ] **Step 1: Read the pattern to mirror**

Run: `sed -n '/defp base_event_attrs/,/^  end/p' elixir/serviceradar_core/lib/serviceradar/credentials/credential_event_writer.ex`

That helper is private to its module. Copy its shape into the new writer rather than making it public — the two event families want different `actor`, `log_name`, and `correlation_uid` values, and a shared helper would accumulate options for no benefit.

- [ ] **Step 2: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/verdict_event_writer_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.VerdictEventWriterTest do
  use ServiceRadar.DataCase, async: false

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
  alias ServiceRadar.Monitoring.OcsfEvent

  defp actor, do: SystemActor.system(:composite_check_test)

  defp check do
    %{id: Ash.UUID.generate(), name: "PCI Isolation", slug: "pci-isolation"}
  end

  defp transition(from, to) do
    %{
      device_uid: "device-1",
      check_id: Ash.UUID.generate(),
      from_verdict: from,
      to_verdict: to,
      from_status: :healthy,
      to_status: :down,
      inputs: %{"a" => %{"value" => "available"}, "b" => %{"value" => "available"}}
    }
  end

  defp events_for(log_name) do
    OcsfEvent
    |> Ash.Query.filter(log_name == ^log_name)
    |> Ash.read!(actor: actor())
  end

  test "writes one event per transition" do
    assert :ok =
             VerdictEventWriter.write_transitions(check(), [
               transition("isolated_verified", "not_isolated")
             ])

    assert [event] = events_for("composite_check.verdict.changed")
    assert event.message =~ "not_isolated"
    assert event.unmapped["from_verdict"] == "isolated_verified"
    assert event.unmapped["to_verdict"] == "not_isolated"
    assert event.unmapped["device_uid"] == "device-1"
  end

  test "an empty transition list writes nothing" do
    assert :ok = VerdictEventWriter.write_transitions(check(), [])
    assert events_for("composite_check.verdict.changed") == []
  end

  test "a first-time verdict records a nil from_verdict" do
    assert :ok = VerdictEventWriter.write_transitions(check(), [transition(nil, "isolated_verified")])

    assert [event] = events_for("composite_check.verdict.changed")
    assert event.unmapped["from_verdict"] == nil
  end
end
```

- [ ] **Step 3: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/verdict_event_writer_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.VerdictEventWriter is not available`.

- [ ] **Step 4: Implement the writer**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/verdict_event_writer.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.VerdictEventWriter do
  @moduledoc """
  Records an OCSF event when a device's composite check verdict changes.

  Verdicts are derived state, not metrics, so they follow the core-originated
  OCSF event path (a system-actor `Ash.create/3` into `ocsf_events`) rather than
  JetStream. See `ServiceRadar.Credentials.CredentialEventWriter` for the same
  pattern.

  Event write failures are logged and swallowed. The verdict has already been
  persisted by the time this runs, and failing the pass over a missing audit row
  would discard correct results.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @log_name "composite_check.verdict.changed"

  @spec write_transitions(map(), [map()]) :: :ok
  def write_transitions(_check, []), do: :ok

  def write_transitions(check, transitions) when is_list(transitions) do
    Enum.each(transitions, &write_transition(check, &1))
    :ok
  end

  defp write_transition(check, transition) do
    attrs = event_attrs(check, transition)

    Ash.create(OcsfEvent, attrs,
      action: :record,
      actor: SystemActor.system(:composite_check_verdict_writer),
      domain: ServiceRadar.Monitoring
    )

    :ok
  rescue
    exception ->
      Logger.warning("Failed to write composite check verdict event",
        check_id: Map.get(check, :id),
        device_uid: Map.get(transition, :device_uid),
        reason: Exception.message(exception)
      )

      :ok
  end

  defp event_attrs(check, transition) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_for(transition.to_status)
    status_id = OCSF.status_success()
    now = DateTime.utc_now()

    unmapped = %{
      "event_family" => "composite_check_verdict",
      "check_id" => to_string(Map.get(check, :id)),
      "check_slug" => Map.get(check, :slug),
      "check_name" => Map.get(check, :name),
      "device_uid" => transition.device_uid,
      "from_verdict" => transition.from_verdict,
      "to_verdict" => transition.to_verdict,
      "from_status" => transition.from_status && to_string(transition.from_status),
      "to_status" => to_string(transition.to_status),
      "inputs" => transition.inputs
    }

    %{
      time: now,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message:
        "Composite check #{Map.get(check, :name)} verdict for #{transition.device_uid} changed " <>
          "from #{transition.from_verdict || "none"} to #{transition.to_verdict}",
      status_id: status_id,
      status: OCSF.status_name(status_id),
      metadata:
        OCSF.build_metadata(
          product_name: "ServiceRadar Core",
          correlation_uid: "composite_check:#{Map.get(check, :id)}:#{transition.device_uid}"
        ),
      observables: [],
      actor: %{user: %{uid: "system", name: "ServiceRadar Composite Checks"}},
      log_name: @log_name,
      log_provider: "serviceradar.core",
      unmapped: unmapped,
      raw_data: Jason.encode!(unmapped)
    }
  end

  defp severity_for(:down), do: OCSF.severity_high()
  defp severity_for(:degraded), do: OCSF.severity_medium()
  defp severity_for(_), do: OCSF.severity_informational()

  @doc false
  def log_name, do: @log_name
end
```

If any `OCSF.*` helper name does not exist, run `rg -n "def severity_|def status_|def activity_log|def class_|def category_|def type_uid|def build_metadata" elixir/serviceradar_core/lib/serviceradar/event_writer/ocsf.ex` and use the real names. Do not invent helpers.

- [ ] **Step 5: Emit from the evaluation pass**

In `evaluation.ex`, add the alias:

```elixir
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
```

and in `run/2`, replace the final tuple construction with:

```elixir
      removed = sweep_out_of_scope(check, started_at)

      if Keyword.get(opts, :emit_events?, true) do
        VerdictEventWriter.write_transitions(check, transitions)
      end

      {:ok, %{evaluated: evaluated, transitions: transitions, removed: removed}}
```

The `:emit_events?` option lets Plan 3's preview reuse the pass without polluting the event stream. It defaults to `true` so production behavior needs no opt-in.

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/`
Expected: PASS. The Task 11 evaluation tests still pass — they run with events enabled, which is fine.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/verdict_event_writer.ex \
        lib/serviceradar/composite_checks/evaluation.ex \
        test/serviceradar/composite_checks/verdict_event_writer_test.exs
git commit -m "feat(composite-checks): record OCSF events on verdict transitions"
```

---

### Task 13: Scheduled evaluation worker

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluation_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluation_worker_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check.ex` (reschedule on state and interval changes)

**Interfaces:**
- Consumes: `Evaluation.run/2` (Task 11), `CompositeCheck.list_enabled/1` (Task 1), `ServiceRadar.SweepJobs.ObanSupport`.
- Produces: `EvaluationWorker.ensure_scheduled(check) :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}` and `EvaluationWorker.cancel(check_id) :: :ok`.

**Why the periodic pass is load-bearing, not a fallback:** two transitions produce no event at all. An input aging past `max_age` (nothing happens — the clock just moves) and scope membership drift as inventory syncs (the device did not change from this check's perspective). Both are only discoverable by looking. Do not let a later optimization delete this worker in favor of event-driven refresh alone.

- [ ] **Step 1: Read the scheduling pattern**

Run: `sed -n '50,110p' elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_monitor_worker.ex`

Note `ObanSupport.available?/0` and `ObanSupport.safe_insert/1` — sweep groups are creatable even when the scheduler is down, and composite checks must behave the same way. A check save must never fail because Oban is unavailable.

- [ ] **Step 2: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/evaluation_worker_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.EvaluationWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.EvaluationWorker

  defp actor, do: SystemActor.system(:composite_check_test)

  defp build_check(state) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Worker #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    if state == :enabled do
      {:ok, enabled} =
        check
        |> Ash.Changeset.for_update(:set_state, %{state: :enabled}, actor: actor())
        |> Ash.update()

      enabled
    else
      check
    end
  end

  test "perform evaluates an enabled check and returns a summary" do
    check = build_check(:enabled)

    assert {:ok, summary} =
             EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => check.id}})

    assert is_integer(summary.evaluated)
  end

  test "perform is a no-op for a disabled check" do
    check = build_check(:draft)

    assert {:ok, :skipped} =
             EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => check.id}})
  end

  test "perform discards cleanly when the check no longer exists" do
    assert {:cancel, _reason} =
             EvaluationWorker.perform(%Oban.Job{args: %{"check_id" => Ash.UUID.generate()}})
  end
end
```

- [ ] **Step 3: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/evaluation_worker_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.EvaluationWorker is not available`.

- [ ] **Step 4: Implement the worker**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluation_worker.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.EvaluationWorker do
  @moduledoc """
  Evaluates one composite check on its configured interval, then reschedules
  itself.

  The periodic pass is required even though inputs also drive an event-driven
  refresh: an input aging past its `max_age` produces no event, and neither does
  a device entering or leaving the scope as inventory syncs. Both are only
  discoverable by re-evaluating.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 30, keys: [:check_id], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"check_id" => check_id}}) do
    actor = SystemActor.system(:composite_check_evaluation)

    case CompositeCheck.get_by_id(check_id, actor: actor) do
      {:ok, %CompositeCheck{state: :enabled} = check} ->
        result = Evaluation.run(check, actor: actor)
        reschedule(check)
        handle_result(check, result)

      {:ok, %CompositeCheck{}} ->
        {:ok, :skipped}

      {:error, _reason} ->
        {:cancel, "composite check #{check_id} no longer exists"}
    end
  end

  defp handle_result(check, {:ok, summary}) do
    Logger.debug("composite check evaluated",
      check_id: check.id,
      evaluated: summary.evaluated,
      transitions: length(summary.transitions),
      removed: summary.removed
    )

    {:ok, summary}
  end

  defp handle_result(check, {:error, reason} = error) do
    Logger.warning("composite check evaluation failed",
      check_id: check.id,
      reason: inspect(reason)
    )

    error
  end

  @doc """
  Schedules the next evaluation for a check. Safe to call when Oban is
  unavailable — a check must remain saveable when the scheduler is down.
  """
  def ensure_scheduled(%CompositeCheck{state: :enabled} = check) do
    if ObanSupport.available?() do
      %{check_id: check.id}
      |> new(schedule_in: check.evaluation_interval_seconds)
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  def ensure_scheduled(%CompositeCheck{}), do: {:ok, :already_scheduled}

  @doc "Cancels any pending evaluation jobs for a check."
  def cancel(check_id) do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == ^to_string(__MODULE__))
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where([j], fragment("? ->> 'check_id' = ?", j.args, ^to_string(check_id)))
    |> Oban.cancel_all_jobs()

    :ok
  rescue
    _ -> :ok
  end

  defp reschedule(check), do: ensure_scheduled(check)
end
```

- [ ] **Step 5: Reconcile scheduling on state change**

In `composite_check.ex`, replace the `update :set_state` action with:

```elixir
    update :set_state do
      accept [:state]

      change after_action(fn _changeset, check, _context ->
               case check.state do
                 :enabled -> ServiceRadar.CompositeChecks.EvaluationWorker.ensure_scheduled(check)
                 _ -> ServiceRadar.CompositeChecks.EvaluationWorker.cancel(check.id)
               end

               {:ok, check}
             end)
    end
```

Note the `after_action` deliberately ignores the scheduling result. A check must save even when Oban is down — the same contract sweep groups have. Surfacing "scheduling is deferred" to the operator is Plan 3's job.

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/`
Expected: PASS.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/evaluation_worker.ex \
        lib/serviceradar/composite_checks/composite_check.ex \
        test/serviceradar/composite_checks/evaluation_worker_test.exs
git commit -m "feat(composite-checks): add the scheduled evaluation worker"
```

---

### Task 14: Debounced per-device refresh

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/refresh.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/refresh_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/refresh_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex` (call `Refresh.enqueue/1` after upserting availability)

**Interfaces:**
- Consumes: `Evaluation.evaluate_devices/5` (Task 11), `DeviceCompositeCheckResult.list_by_device/2` (Task 4).
- Produces: `Refresh.enqueue(device_uid) :: :ok` — fire-and-forget, never raises, never blocks ingestion.

**Scope of the refresh, stated plainly:** it re-evaluates only the enabled checks that **already have a result row** for that device. A device newly entering a check's scope is picked up by the periodic pass within one interval. The alternative — re-running every enabled check's SRQL scope with a UID filter on every sweep result — would issue one SRQL translation and query per check per device per sweep cycle, which is a far worse trade than a bounded delay on scope entry. Write this reasoning into the moduledoc so it is not "fixed" later.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/refresh_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.RefreshTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Refresh
  alias ServiceRadar.CompositeChecks.RefreshWorker
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Refresh #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    inputs =
      for {key, expected, position} <- [{"a", "available", 0}, {"b", "blocked", 1}] do
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          %{
            check_id: check.id,
            key: key,
            label: key,
            position: position,
            kind: :vantage_point,
            expected: expected,
            config: %{"agent_id" => "agent-#{key}", "max_age_seconds" => 900}
          },
          actor: actor()
        )
        |> Ash.create!()
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    {:ok, enabled} =
      check
      |> Ash.Changeset.for_update(:set_state, %{state: :enabled}, actor: actor())
      |> Ash.update()

    now = DateTime.utc_now()

    seed_result(enabled, "device-1", "device_unreachable", :degraded, now)

    %{check: enabled, now: now}
  end

  defp seed_result(check, device_uid, verdict, status, at) do
    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: at,
        changed_at: at
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  defp availability(device_uid, agent_id, is_available, at) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{device_uid: device_uid, agent_id: agent_id, is_available: is_available, checked_at: at},
      actor: actor()
    )
    |> Ash.create!()
  end

  test "refreshes the verdict for a device with an existing result", %{check: check, now: now} do
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, refreshed} =
             RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-1"}})

    assert refreshed == 1

    {:ok, result} =
      DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())

    assert result.verdict == "isolated_verified"
  end

  test "does nothing for a device with no result rows" do
    assert {:ok, 0} = RefreshWorker.perform(%Oban.Job{args: %{"device_uid" => "device-unknown"}})
  end

  test "enqueue never raises when Oban is unavailable" do
    assert :ok = Refresh.enqueue("device-1")
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/refresh_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Refresh is not available`.

- [ ] **Step 3: Implement the refresh entry point**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/refresh.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Refresh do
  @moduledoc """
  Debounced per-device re-evaluation, triggered when one of a device's input
  signals changes.

  ## What this refreshes, and what it deliberately does not

  Only the enabled checks that already hold a result row for the device are
  re-evaluated. A device newly entering a check's scope is picked up by the
  periodic pass instead.

  The alternative — re-running every enabled check's SRQL scope with a UID
  filter on every sweep result — costs one SRQL translation and query per check
  per device per sweep cycle. That is a far worse trade than a bounded delay on
  scope entry, which is why this asymmetry is intentional rather than an
  oversight.

  `enqueue/1` never raises and never blocks the caller: it runs inside sweep
  result ingestion, which must not fail because a composite check refresh could
  not be scheduled.
  """

  alias ServiceRadar.CompositeChecks.RefreshWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @spec enqueue(String.t()) :: :ok
  def enqueue(device_uid) when is_binary(device_uid) and device_uid != "" do
    if ObanSupport.available?() do
      %{device_uid: device_uid}
      |> RefreshWorker.new()
      |> ObanSupport.safe_insert()
    end

    :ok
  rescue
    exception ->
      Logger.debug("composite check refresh not enqueued",
        device_uid: device_uid,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_device_uid), do: :ok
end
```

- [ ] **Step 4: Implement the refresh worker**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/refresh_worker.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.RefreshWorker do
  @moduledoc """
  Re-evaluates one device against the enabled composite checks that already hold
  a result for it.

  Oban's `unique` window is the debounce: several input changes for the same
  device inside the window collapse into one evaluation.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 30, keys: [:device_uid], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.VerdictEventWriter

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_uid" => device_uid}}) do
    actor = SystemActor.system(:composite_check_refresh)
    now = DateTime.utc_now()

    with {:ok, results} <- DeviceCompositeCheckResult.list_by_device(device_uid, actor: actor) do
      refreshed =
        results
        |> Enum.map(& &1.check_id)
        |> Enum.uniq()
        |> Enum.count(&refresh_check(&1, device_uid, now, actor))

      {:ok, refreshed}
    end
  end

  defp refresh_check(check_id, device_uid, now, actor) do
    with {:ok, %CompositeCheck{state: :enabled} = check} <-
           CompositeCheck.get_by_id(check_id, actor: actor),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check_id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check_id, actor: actor),
         {:ok, [row]} <-
           Evaluation.evaluate_devices(check, inputs, rules, [device_uid], now: now),
         {:ok, prior} <-
           DeviceCompositeCheckResult.get_by_device_check(device_uid, check_id, actor: actor) do
      changed? = prior.verdict != row.verdict

      DeviceCompositeCheckResult
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: device_uid,
          check_id: check_id,
          verdict: row.verdict,
          status: row.status,
          matched_rule_id: row.matched_rule_id,
          inputs: row.inputs,
          evaluated_at: now,
          changed_at: if(changed?, do: now, else: prior.changed_at)
        },
        actor: actor,
        upsert?: true,
        upsert_identity: :unique_device_check
      )
      |> Ash.create!()

      if changed? do
        VerdictEventWriter.write_transitions(check, [
          %{
            device_uid: device_uid,
            check_id: check_id,
            from_verdict: prior.verdict,
            to_verdict: row.verdict,
            from_status: prior.status,
            to_status: row.status,
            inputs: row.inputs
          }
        ])
      end

      true
    else
      _ -> false
    end
  end
end
```

- [ ] **Step 5: Trigger the refresh from sweep ingestion**

Run: `rg -n "DeviceAgentAvailability" elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`

Find where the per-agent availability row is upserted. Immediately after a successful upsert, add:

```elixir
    ServiceRadar.CompositeChecks.Refresh.enqueue(device_uid)
```

Do not wrap it in a `with` or let its return value affect ingestion — `enqueue/1` always returns `:ok`, and ingestion must not fail because a refresh could not be scheduled.

- [ ] **Step 6: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/ test/serviceradar/sweep_jobs/`
Expected: PASS. The sweep ingestion tests must stay green.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/refresh.ex \
        lib/serviceradar/composite_checks/refresh_worker.ex \
        lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex \
        test/serviceradar/composite_checks/refresh_test.exs
git commit -m "feat(composite-checks): refresh verdicts when input signals change"
```

---

### Task 15: Device fact writes with server-stamped provenance

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/device.ex` (add the `:write_facts` action)
- Create: `elixir/serviceradar_core/lib/serviceradar/inventory/changes/merge_device_facts.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/inventory/device_facts_test.exs`

**Interfaces:**
- Consumes: `Resolvers.DeviceMetadata.provenance_key/0` (Task 7) — the two must agree on `"__fact_provenance"` or freshness silently never resolves.
- Produces: a `:write_facts` update action on `ServiceRadar.Inventory.Device` accepting an argument `facts :: map` and writing, for each key, `metadata[key] = value` plus `metadata["__fact_provenance"][key] = %{"source" => actor_label, "updated_at" => iso8601_now}`.

**Bounds, all enforced server-side:** key pattern `^[a-z][a-z0-9_]{0,63}$`, scalar values only (boolean, number, binary), at most 32 externally written facts per device, and the reserved keys `passive_fingerprint` and `__fact_provenance` rejected outright. Any invalid fact rejects the **whole** request — a partial write would leave the caller believing all facts landed.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/inventory/device_facts_test.exs`:

```elixir
defmodule ServiceRadar.Inventory.DeviceFactsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Inventory.Device

  defp actor, do: SystemActor.system(:device_facts_test)

  defp write(device, facts) do
    device
    |> Ash.Changeset.for_update(:write_facts, %{facts: facts}, actor: actor())
    |> Ash.update()
  end

  setup do
    %{device: create_device_fixture()}
  end

  test "writes the plain value and server-stamped provenance", %{device: device} do
    assert {:ok, updated} = write(device, %{"nac_applied" => true})

    assert updated.metadata["nac_applied"] == true

    provenance = updated.metadata[DeviceMetadata.provenance_key()]["nac_applied"]
    assert is_binary(provenance["updated_at"])
    assert {:ok, _dt, _} = DateTime.from_iso8601(provenance["updated_at"])
    assert is_binary(provenance["source"])
  end

  test "preserves unrelated metadata", %{device: device} do
    {:ok, device} = write(device, %{"first" => true})
    {:ok, device} = write(device, %{"second" => false})

    assert device.metadata["first"] == true
    assert device.metadata["second"] == false
  end

  test "a caller-supplied timestamp is ignored", %{device: device} do
    before = DateTime.utc_now()
    {:ok, updated} = write(device, %{"nac_applied" => true, "updated_at" => "1999-01-01T00:00:00Z"})

    {:ok, stamped, _} =
      updated.metadata
      |> get_in([DeviceMetadata.provenance_key(), "nac_applied", "updated_at"])
      |> DateTime.from_iso8601()

    assert DateTime.compare(stamped, before) in [:gt, :eq]
  end

  test "rejects an invalid key and writes nothing", %{device: device} do
    assert {:error, error} = write(device, %{"NacApplied" => true})
    assert Exception.message(error) =~ "NacApplied"

    {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: actor())
    refute Map.has_key?(reloaded.metadata, "NacApplied")
  end

  test "rejects a non-scalar value", %{device: device} do
    assert {:error, error} = write(device, %{"nested" => %{"a" => 1}})
    assert Exception.message(error) =~ "scalar"
  end

  test "rejects a reserved key", %{device: device} do
    assert {:error, error} = write(device, %{"passive_fingerprint" => true})
    assert Exception.message(error) =~ "reserved"
  end

  test "rejects writing the provenance key directly", %{device: device} do
    assert {:error, _} = write(device, %{"__fact_provenance" => true})
  end

  test "enforces the per-device fact cap", %{device: device} do
    facts = Map.new(1..32, fn i -> {"fact_#{i}", true} end)
    assert {:ok, device} = write(device, facts)

    assert {:error, error} = write(device, %{"fact_33" => true})
    assert Exception.message(error) =~ "cap"
  end
end
```

Note: `create_device_fixture/0` must come from the existing test support. Run `rg -n "def create_device_fixture|def device_fixture" elixir/serviceradar_core/test/support/` and use the real helper name; if none exists, create the device inline with `Device`'s existing create action and reuse that snippet in every test in this file.

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/inventory/device_facts_test.exs`
Expected: FAIL — no such action `:write_facts`.

- [ ] **Step 3: Implement the change module**

Create `elixir/serviceradar_core/lib/serviceradar/inventory/changes/merge_device_facts.ex`:

```elixir
defmodule ServiceRadar.Inventory.Changes.MergeDeviceFacts do
  @moduledoc """
  Merges externally supplied scalar facts into device metadata and stamps
  per-key provenance.

  The plain value is written at its own key so every existing metadata consumer
  sees it unchanged. Provenance is written alongside under
  `__fact_provenance`, which is what lets a composite check enforce a maximum
  age without asking the caller to send timestamps — and, because it is
  server-stamped, prevents a caller from back-dating a compliance signal.

  Any invalid fact rejects the whole request. A partial write would leave the
  caller believing every fact landed.
  """

  use Ash.Resource.Change

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata

  @key_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @reserved_keys ~w(passive_fingerprint)
  @max_facts 32

  @impl true
  def change(changeset, _opts, context) do
    facts = Ash.Changeset.get_argument(changeset, :facts) || %{}
    existing = Ash.Changeset.get_data(changeset, :metadata) || %{}

    with :ok <- validate_facts(facts),
         :ok <- validate_cap(existing, facts) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :metadata,
        merge(existing, facts, source(context))
      )
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :facts, message: message)
    end
  end

  defp validate_facts(facts) when is_map(facts) and map_size(facts) > 0 do
    Enum.reduce_while(facts, :ok, fn {key, value}, :ok ->
      cond do
        key == DeviceMetadata.provenance_key() ->
          {:halt, {:error, "#{key} is reserved and cannot be written as a fact"}}

        key in @reserved_keys ->
          {:halt, {:error, "#{key} is reserved for internal enrichment"}}

        not Regex.match?(@key_pattern, to_string(key)) ->
          {:halt,
           {:error, "#{key} is not a valid fact key (lowercase letters, digits, underscores)"}}

        not scalar?(value) ->
          {:halt, {:error, "#{key} must be a scalar value (boolean, number, or string)"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_facts(_facts), do: {:error, "at least one fact is required"}

  defp validate_cap(existing, facts) do
    written = existing |> Map.get(DeviceMetadata.provenance_key(), %{}) |> Map.keys()
    total = written |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(facts))) |> MapSet.size()

    if total > @max_facts do
      {:error, "writing these facts would exceed the per-device cap of #{@max_facts}"}
    else
      :ok
    end
  end

  defp merge(existing, facts, source) do
    stamped_at = DateTime.utc_now() |> DateTime.to_iso8601()
    provenance_key = DeviceMetadata.provenance_key()
    provenance = Map.get(existing, provenance_key, %{})

    Enum.reduce(facts, existing, fn {key, value}, acc ->
      acc
      |> Map.put(key, value)
      |> Map.put(
        provenance_key,
        Map.put(
          Map.get(acc, provenance_key, provenance),
          key,
          %{"source" => source, "updated_at" => stamped_at}
        )
      )
    end)
  end

  defp scalar?(value), do: is_boolean(value) or is_number(value) or is_binary(value)

  defp source(context) do
    case context do
      %{actor: %{name: name}} when is_binary(name) -> name
      %{actor: %{id: id}} -> to_string(id)
      _ -> "unknown"
    end
  end

  @doc false
  def max_facts, do: @max_facts
end
```

- [ ] **Step 4: Add the action to Device**

In `device.ex`, add to the `actions do` block:

```elixir
    update :write_facts do
      description "Merge externally supplied scalar facts into metadata with server-stamped provenance"
      accept []

      argument :facts, :map, allow_nil?: false

      change ServiceRadar.Inventory.Changes.MergeDeviceFacts
    end
```

Then add the policy. Find the existing `policies do` block and add:

```elixir
    operator_action(:write_facts)
```

alongside the other operator action declarations. Confirm which helper the file already uses — run `rg -n "operator_action" elixir/serviceradar_core/lib/serviceradar/inventory/device.ex` and match the existing style rather than introducing a second one.

- [ ] **Step 5: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/inventory/device_facts_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 6: Prove the resolver and the writer agree**

This is the one cross-module contract that fails silently if broken — a mismatch means every fact resolves `:unknown` forever with no error anywhere.

Add to `test/serviceradar/inventory/device_facts_test.exs`:

```elixir
  test "a written fact resolves as fresh through the composite resolver", %{device: device} do
    alias ServiceRadar.CompositeChecks.CompositeCheckInput

    {:ok, updated} = write(device, %{"nac_applied" => true})

    input = %CompositeCheckInput{
      key: "nac",
      kind: :device_metadata,
      config: %{"path" => "nac_applied", "value_type" => "boolean", "max_age_seconds" => 3_600}
    }

    assert %{value: true, stale: false} =
             DeviceMetadata.resolve(input, updated.metadata, DateTime.utc_now())
  end
```

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/inventory/device_facts_test.exs`
Expected: PASS, 9 tests.

- [ ] **Step 7: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/inventory/device.ex \
        lib/serviceradar/inventory/changes/merge_device_facts.ex \
        test/serviceradar/inventory/device_facts_test.exs
git commit -m "feat(devices): add bounded fact writes with server-stamped provenance"
```

---

### Task 16: The NCO-facing fact endpoint and RBAC

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/device_controller.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (near line 385, beside `get("/devices/:uid", DeviceController, :show)`)
- Create: `elixir/web-ng/test/phoenix/controllers/api/device_facts_controller_test.exs`
- Create: `docs/docs/nco-device-facts.md`

**Interfaces:**
- Consumes: the `:write_facts` action from Task 15.
- Produces: `PATCH /api/devices/:uid/metadata`, body `{"facts": {"nac_applied": true}}`, gated on `devices.facts.write`. Responses: `200` with the updated fact set, `404` unknown device, `403` unauthorized, `422` bounds violation with the offending key named.

**This is phase 1 of the NCO integration.** NCO already performs the configuration validation; all it needs is a one-line PATCH. Phase 2 replaces this ingress with the signed Wasm plugin writing `device_source_observations.source_metadata`, at which point the `device_metadata` input kind gains a `source:` option — authored checks do not change. Do not build toward phase 2 here.

- [ ] **Step 1: Read the existing controller and route conventions**

Run:
```bash
rg -n "def show" -A20 elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/device_controller.ex
sed -n '378,392p' elixir/web-ng/lib/serviceradar_web_ng_web/router.ex
```

Match the existing pipeline, actor resolution, and error rendering. Do not introduce a new auth pattern — the endpoint must work for both session principals and API tokens exactly as the existing device routes do.

- [ ] **Step 2: Add the RBAC permissions**

In `catalog.ex`, add to the `devices` section's `permissions` list:

```elixir
        %{
          key: "devices.facts.write",
          label: "Write device facts",
          description:
            "Set bounded scalar facts on device metadata via the API (used by external validation tools)",
          default_roles: @operator_roles
        },
```

And add a new section after the `devices` section:

```elixir
    %{
      section: "composite_checks",
      label: "Composite Checks",
      permissions: [
        %{
          key: "composite_checks.view",
          label: "View composite checks",
          description: "View composite check definitions and device verdicts",
          default_roles: @all_roles
        },
        %{
          key: "composite_checks.manage",
          label: "Manage composite checks",
          description: "Create, edit, enable, and delete composite checks",
          default_roles: @operator_roles
        },
        %{
          key: "composite_checks.evaluate",
          label: "Run composite check previews",
          description: "Run an on-demand composite check evaluation without persisting results",
          default_roles: @operator_roles
        }
      ]
    },
```

Run `rg -n "@all_roles|@operator_roles|@admin_roles" elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex | head -5` first and use whatever those module attributes are actually named in the file.

- [ ] **Step 3: Write the failing test**

Create `elixir/web-ng/test/phoenix/controllers/api/device_facts_controller_test.exs`:

```elixir
defmodule ServiceRadarWebNGWeb.API.DeviceFactsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  describe "PATCH /api/devices/:uid/metadata" do
    test "writes a fact and returns it", %{conn: conn} do
      device = create_device_fixture()
      conn = authenticate_operator(conn)

      conn =
        patch(conn, ~p"/api/devices/#{device.uid}/metadata", %{
          "facts" => %{"nac_applied" => true}
        })

      assert %{"facts" => %{"nac_applied" => %{"value" => true, "updated_at" => updated_at}}} =
               json_response(conn, 200)

      assert {:ok, _dt, _} = DateTime.from_iso8601(updated_at)
    end

    test "returns 404 for an unknown device", %{conn: conn} do
      conn = authenticate_operator(conn)
      conn = patch(conn, ~p"/api/devices/does-not-exist/metadata", %{"facts" => %{"a" => true}})

      assert json_response(conn, 404)
    end

    test "returns 422 naming the offending key", %{conn: conn} do
      device = create_device_fixture()
      conn = authenticate_operator(conn)

      conn =
        patch(conn, ~p"/api/devices/#{device.uid}/metadata", %{
          "facts" => %{"NacApplied" => true}
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert to_string(inspect(errors)) =~ "NacApplied"
    end

    test "returns 403 without the permission", %{conn: conn} do
      device = create_device_fixture()
      conn = authenticate_viewer(conn)

      conn =
        patch(conn, ~p"/api/devices/#{device.uid}/metadata", %{"facts" => %{"a" => true}})

      assert json_response(conn, 403)
    end
  end
end
```

Run `rg -n "def authenticate_operator|def authenticate_viewer|def create_device_fixture" elixir/web-ng/test/support/` and use the real helper names; substitute throughout if they differ.

- [ ] **Step 4: Run the test and watch it fail**

Run: `cd elixir/web-ng && mix test test/phoenix/controllers/api/device_facts_controller_test.exs`
Expected: FAIL — no route matches PATCH.

- [ ] **Step 5: Add the route**

In `router.ex`, beside the existing device API route:

```elixir
    get("/devices/:uid", DeviceController, :show)
    patch("/devices/:uid/metadata", DeviceController, :update_metadata)
```

- [ ] **Step 6: Add the controller action**

In `device_controller.ex`:

```elixir
  @doc """
  Sets bounded scalar facts on a device's metadata.

  Phase-1 ingress for external validation tools (OpenText Network Automation).
  The value is written plainly so existing metadata consumers see it, and
  server-stamped provenance is recorded alongside so composite checks can
  enforce a maximum age. Caller-supplied timestamps are ignored.
  """
  def update_metadata(conn, %{"uid" => uid} = params) do
    actor = current_actor(conn)

    with :ok <- authorize(actor, "devices.facts.write"),
         {:ok, device} <- Device.get_by_uid(uid, false, actor: actor),
         {:ok, updated} <-
           device
           |> Ash.Changeset.for_update(:write_facts, %{facts: Map.get(params, "facts", %{})},
             actor: actor
           )
           |> Ash.update() do
      json(conn, %{"facts" => rendered_facts(updated)})
    end
  end

  defp rendered_facts(device) do
    provenance = Map.get(device.metadata, "__fact_provenance", %{})

    Map.new(provenance, fn {key, entry} ->
      {key,
       %{
         "value" => Map.get(device.metadata, key),
         "source" => Map.get(entry, "source"),
         "updated_at" => Map.get(entry, "updated_at")
       }}
    end)
  end
```

`authorize/2` and `current_actor/1` must be whatever this controller already uses — read the `show/2` action from Step 1 and mirror it exactly. Error rendering (404/403/422) should fall through to the existing `FallbackController`; if `with` clauses in this controller currently return bare tuples, match that convention.

- [ ] **Step 7: Run the tests**

Run: `cd elixir/web-ng && mix test test/phoenix/controllers/api/device_facts_controller_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 8: Document the integration**

Create `docs/docs/nco-device-facts.md` covering: the endpoint and method, how to obtain a token with `devices.facts.write`, a `curl` example writing `nac_applied`, the key and value bounds, the 32-fact cap, that provenance is server-stamped and caller timestamps are ignored, and the consequence for composite checks — a fact older than an input's `max_age` resolves `unknown`, so NCO must re-write a fact at least once per configured window even when the value has not changed. Markdown must be ASCII only.

- [ ] **Step 9: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
cd ../web-ng && mix format
cd ../..
git add elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex \
        elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/device_controller.ex \
        elixir/web-ng/lib/serviceradar_web_ng_web/router.ex \
        elixir/web-ng/test/phoenix/controllers/api/device_facts_controller_test.exs \
        docs/docs/nco-device-facts.md
git commit -m "feat(devices): add the external fact write endpoint and composite check RBAC"
```

---

### Task 17: Enable-time validations — liveness witness and coverage

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/composite_checks/readiness.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/composite_checks/readiness_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/composite_checks/composite_check.ex` (gate `:set_state` on readiness)

**Interfaces:**
- Consumes: `Coverage.for_check/3` (Task 9), `CompositeCheckInput.list_by_check/2` (Task 2).
- Produces: `Readiness.check(check, opts) :: {:ok, report()}` where
  ```elixir
  @type report :: %{
          blocking: [problem()],
          warnings: [problem()],
          coverage: [Coverage.coverage_row()]
        }
  @type problem :: %{code: atom(), message: String.t()}
  ```
  Plan 3 renders `report` directly in the builder, which is why it returns structured problems rather than a bare boolean.

**The two validations, and why they are not polish:**

- **Liveness witness.** A check with two or more vantage points must have at least one expected `available`. Without it, "blocked everywhere" is the expected pattern and a powered-off device satisfies the check perfectly — the check would certify dead devices as compliant. This is the single most important correctness property in the whole feature.
- **Coverage.** Zero coverage on any vantage point blocks enabling unless explicitly acknowledged, because a derivation-only check with no underlying sweep reports `inconclusive` forever while looking healthy.

- [ ] **Step 1: Write the failing test**

Create `elixir/serviceradar_core/test/serviceradar/composite_checks/readiness_test.exs`:

```elixir
defmodule ServiceRadar.CompositeChecks.ReadinessTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Readiness
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  defmodule ScopeRunner do
    @moduledoc false
    def query_page(_query, _opts),
      do: {:ok, %{rows: [%{"uid" => "device-1"}, %{"uid" => "device-2"}], next_cursor: nil}}
  end

  defp build_check(expectations) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Ready #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    for {{key, expected}, position} <- Enum.with_index(expectations) do
      CompositeCheckInput
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          key: key,
          label: key,
          position: position,
          kind: :vantage_point,
          expected: expected,
          config: %{"agent_id" => "agent-#{key}"}
        },
        actor: actor()
      )
      |> Ash.create!()
    end

    check
  end

  defp availability(device_uid, agent_id) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: true,
        checked_at: DateTime.utc_now()
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp report(check) do
    {:ok, report} = Readiness.check(check, actor: actor(), runner: ScopeRunner)
    report
  end

  test "all-blocked expectations block enabling" do
    check = build_check([{"a", "blocked"}, {"b", "blocked"}])

    assert %{blocking: blocking} = report(check)
    assert Enum.any?(blocking, &(&1.code == :no_liveness_witness))
    assert Enum.find(blocking, &(&1.code == :no_liveness_witness)).message =~ "powered-off"
  end

  test "a single vantage point is exempt from the witness rule" do
    check = build_check([{"a", "blocked"}])

    refute Enum.any?(report(check).blocking, &(&1.code == :no_liveness_witness))
  end

  test "zero coverage blocks enabling" do
    check = build_check([{"a", "available"}, {"b", "blocked"}])
    availability("device-1", "agent-a")
    availability("device-2", "agent-a")

    blocking = report(check).blocking
    problem = Enum.find(blocking, &(&1.code == :no_coverage))

    assert problem
    assert problem.message =~ "agent-b"
  end

  test "partial coverage warns but does not block" do
    check = build_check([{"a", "available"}, {"b", "blocked"}])
    availability("device-1", "agent-a")
    availability("device-2", "agent-a")
    availability("device-1", "agent-b")

    report = report(check)

    refute Enum.any?(report.blocking, &(&1.code == :no_coverage))
    warning = Enum.find(report.warnings, &(&1.code == :partial_coverage))
    assert warning.message =~ "1 of 2"
  end

  test "full coverage with a witness is clean" do
    check = build_check([{"a", "available"}, {"b", "blocked"}])

    for uid <- ["device-1", "device-2"], agent <- ["agent-a", "agent-b"] do
      availability(uid, agent)
    end

    assert %{blocking: [], warnings: []} = report(check)
  end

  test "enabling is rejected while a blocking problem exists" do
    check = build_check([{"a", "blocked"}, {"b", "blocked"}])

    assert {:error, error} =
             check
             |> Ash.Changeset.for_update(:set_state, %{state: :enabled}, actor: actor())
             |> Ash.update()

    assert Exception.message(error) =~ "liveness witness"
  end

  test "acknowledging a coverage gap allows enabling" do
    check = build_check([{"a", "available"}, {"b", "blocked"}])

    assert {:ok, enabled} =
             check
             |> Ash.Changeset.for_update(
               :set_state,
               %{state: :enabled, acknowledge_coverage_gap: true},
               actor: actor()
             )
             |> Ash.update()

    assert enabled.state == :enabled
  end
end
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/readiness_test.exs`
Expected: FAIL — `module ServiceRadar.CompositeChecks.Readiness is not available`.

- [ ] **Step 3: Implement Readiness**

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/readiness.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Readiness do
  @moduledoc """
  Decides whether a composite check is safe to enable, and explains why not.

  Two properties are enforced here rather than left to the operator:

  **Liveness witness.** A check with two or more vantage points must expect at
  least one of them to reach the device. Without a witness, "blocked from
  everywhere" is the expected pattern, and a powered-off device satisfies it
  perfectly — the check would certify dead devices as compliant. This is the
  single most important correctness property of a multi-vantage-point check.

  **Coverage.** Because composite checks derive rather than probe, a vantage
  point with no underlying sweep produces `inconclusive` forever while the check
  looks perfectly healthy. Zero coverage blocks enabling unless the operator
  explicitly acknowledges the gap.

  Returns structured problems rather than a boolean so the builder can render
  each one in place.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Coverage

  @type problem :: %{code: atom(), message: String.t()}
  @type report :: %{blocking: [problem()], warnings: [problem()], coverage: [map()]}

  @spec check(struct(), keyword()) :: {:ok, report()} | {:error, term()}
  def check(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, coverage} <- Coverage.for_check(check, inputs, opts) do
      vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

      blocking =
        witness_problem(vantage_points) ++ Enum.flat_map(coverage, &zero_coverage_problem/1)

      warnings = Enum.flat_map(coverage, &partial_coverage_problem/1)

      {:ok, %{blocking: blocking, warnings: warnings, coverage: coverage}}
    end
  end

  defp witness_problem(vantage_points) when length(vantage_points) < 2, do: []

  defp witness_problem(vantage_points) do
    if Enum.any?(vantage_points, &(&1.expected == "available")) do
      []
    else
      [
        %{
          code: :no_liveness_witness,
          message:
            "At least one vantage point must be expected to reach the device. Without a " <>
              "liveness witness, a powered-off device is indistinguishable from a perfectly " <>
              "isolated one."
        }
      ]
    end
  end

  defp zero_coverage_problem(%{covered: 0, total: total, agent_id: agent_id}) when total > 0 do
    [
      %{
        code: :no_coverage,
        message:
          "No sweep from #{agent_id} covers this scope: 0 of #{total} devices have results. " <>
            "Every device will evaluate as inconclusive."
      }
    ]
  end

  defp zero_coverage_problem(_row), do: []

  defp partial_coverage_problem(%{covered: covered, total: total, agent_id: agent_id})
       when covered > 0 and covered < total do
    [
      %{
        code: :partial_coverage,
        message:
          "#{agent_id} has results for #{covered} of #{total} devices in scope. " <>
            "The remaining #{total - covered} will evaluate as inconclusive."
      }
    ]
  end

  defp partial_coverage_problem(_row), do: []
end
```

- [ ] **Step 4: Gate enabling on readiness**

In `composite_check.ex`, replace the `update :set_state` action from Task 13 with:

```elixir
    update :set_state do
      accept [:state]

      argument :acknowledge_coverage_gap, :boolean, default: false

      change ServiceRadar.CompositeChecks.Changes.EnforceReadiness

      change after_action(fn _changeset, check, _context ->
               case check.state do
                 :enabled -> ServiceRadar.CompositeChecks.EvaluationWorker.ensure_scheduled(check)
                 _ -> ServiceRadar.CompositeChecks.EvaluationWorker.cancel(check.id)
               end

               {:ok, check}
             end)
    end
```

Create `elixir/serviceradar_core/lib/serviceradar/composite_checks/changes/enforce_readiness.ex`:

```elixir
defmodule ServiceRadar.CompositeChecks.Changes.EnforceReadiness do
  @moduledoc """
  Blocks enabling a composite check that cannot produce meaningful verdicts.

  Coverage gaps are acknowledgeable — an operator may knowingly enable a check
  ahead of the sweep that will feed it. A missing liveness witness is not: it is
  a correctness fault, not a timing one.
  """

  use Ash.Resource.Change

  alias ServiceRadar.CompositeChecks.Readiness

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_attribute(changeset, :state) == :enabled do
      enforce(changeset, context)
    else
      changeset
    end
  end

  defp enforce(changeset, context) do
    acknowledged? = Ash.Changeset.get_argument(changeset, :acknowledge_coverage_gap)

    case Readiness.check(changeset.data, actor: context.actor) do
      {:ok, %{blocking: blocking}} ->
        blocking
        |> Enum.reject(&(acknowledged? and &1.code == :no_coverage))
        |> case do
          [] -> changeset
          [problem | _] -> Ash.Changeset.add_error(changeset, field: :state, message: problem.message)
        end

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "could not evaluate readiness: #{inspect(reason)}"
        )
    end
  end
end
```

Note: `Readiness.check/2` calls `Coverage.for_check/3`, which runs the scope query. The `readiness_test.exs` cases that go through `:set_state` therefore hit the real `SRQLRunner`. If that is unavailable in the test environment, pass the runner through by adding `argument :runner, :atom` — but try the real path first; `in:devices` against an empty test database is a valid query returning zero rows.

- [ ] **Step 5: Run the tests**

Run: `cd elixir/serviceradar_core && mix test test/serviceradar/composite_checks/`
Expected: PASS. The Task 13 worker test enables a check with no inputs — a zero-vantage-point check has no blocking problems, so it still passes.

- [ ] **Step 6: Format and commit**

```bash
cd elixir/serviceradar_core && mix format
git add lib/serviceradar/composite_checks/readiness.ex \
        lib/serviceradar/composite_checks/changes/enforce_readiness.ex \
        lib/serviceradar/composite_checks/composite_check.ex \
        test/serviceradar/composite_checks/readiness_test.exs
git commit -m "feat(composite-checks): require a liveness witness and vantage point coverage"
```

---

### Task 18: Full verification

**Files:** none created; this task runs gates and fixes what they surface.

- [ ] **Step 1: Run the full core test suite**

Run: `cd elixir/serviceradar_core && mix test > /tmp/core-test.log 2>&1; echo "exit=$?"; tail -40 /tmp/core-test.log`

Redirect rather than piping to `tail` — a pipe reports `tail`'s exit code, not the test suite's, so a failing suite would look green.

Expected: `exit=0`. Pay particular attention to `test/serviceradar/inventory/identity/` (Task 5 modified the merge engine) and `test/serviceradar/sweep_jobs/` (Task 14 modified the ingestor).

- [ ] **Step 2: Run the web-ng test suite**

Run: `cd elixir/web-ng && mix test > /tmp/webng-test.log 2>&1; echo "exit=$?"; tail -40 /tmp/webng-test.log`
Expected: `exit=0`.

- [ ] **Step 3: Run the quality gates**

```bash
./scripts/elixir_quality.sh --project elixir/serviceradar_core > /tmp/core-quality.log 2>&1
echo "exit=$?"; tail -30 /tmp/core-quality.log
./scripts/elixir_quality.sh --project elixir/web-ng --phoenix > /tmp/webng-quality.log 2>&1
echo "exit=$?"; tail -30 /tmp/webng-quality.log
```

Both must exit 0. Credo will fail on any `authorize?: false` — if it does, replace it with a `SystemActor`.

- [ ] **Step 4: Run DB-backed tests against the shared fixture**

Use the `srql-fixtures-db-tests` skill. The scope resolution in Tasks 9, 11, and 17 goes through the real SRQL NIF against real Postgres, so a green local run against an empty database does not prove much on its own.

- [ ] **Step 5: Verify no direct metric writes were introduced**

Run: `rg -n "metrics\.|MetricBatch|JetStream" elixir/serviceradar_core/lib/serviceradar/composite_checks/`
Expected: no output. Composite checks derive state; they must not publish or persist metrics.

- [ ] **Step 6: Verify the evaluator stayed pure**

Run: `rg -n "Repo|Ash\.|Ecto|DateTime.utc_now" elixir/serviceradar_core/lib/serviceradar/composite_checks/evaluator.ex`
Expected: no output. If `DateTime.utc_now/0` crept in, the evaluator became time-dependent and its tests became flaky-by-construction — move it to the caller.

- [ ] **Step 7: Validate the spec still matches what was built**

Run: `openspec validate add-composite-service-checks --strict`
Expected: valid. If implementation forced a deviation from the spec, update the spec delta in the same commit rather than leaving them divergent.

- [ ] **Step 8: Commit any fixes**

```bash
git add -A
git commit -m "test(composite-checks): fix issues surfaced by full verification"
```

---

## Plan Self-Review

Checked against `openspec/changes/add-composite-service-checks/specs/composite-checks/spec.md` and `specs/device-inventory/spec.md`.

**Spec coverage — every requirement maps to a task:**

| Requirement | Task |
|---|---|
| Composite Check Definition | 1 |
| Typed Check Inputs | 2 |
| Vantage Point Resolution | 6 |
| Device Metadata Fact Resolution | 7 |
| Ordered Decision Table | 3, 8 |
| Expectation-Seeded Rule Generation | 10 |
| Liveness Witness Validation | 17 |
| Vantage Point Coverage Readiness | 9, 17 |
| Verdict Persistence | 4, 11 |
| Shared Evaluator | 8, 11 |
| Periodic Evaluation | 11, 13 |
| Event-Driven Refresh | 14 |
| Verdict Change Events | 12 |
| On-Demand Preview | 11 (`evaluate_devices/5`); UI in Plan 3 |
| Result Reassignment On Device Merge | 5 |
| Evaluation Error Handling | 11, 12, 13 |
| Composite Check Authorization | 16 (catalog); resource policies in 1–4 |
| External Device Fact Write API | 15, 16 |
| Device Fact Write Bounds | 15 |

**Deferred to later plans, deliberately:** SRQL `composite.<slug>` exposure (Plan 2), the builder UI and preview rendering (Plan 3), Armis northbound export (Plan 4). The regeneration-warning half of Expectation-Seeded Rule Generation is UI behavior and lands in Plan 3; Task 10 provides the generator it calls.

**Gaps found and closed during review:**

1. *Evaluation Error Handling* required that a failed pass retain results and mark them stale. Task 11's mark-and-sweep would **delete** rows on a partial failure, since unevaluated rows keep an old `evaluated_at`. Fixed below.
2. *Composite Check Authorization* had no test proving a viewer cannot manage a check. Added below.

- [ ] **Task 11 fix — do not sweep after a failed pass**

In `evaluation.ex`, the reduce must not swallow a page failure. Replace the `Enum.reduce` in `run/2` with a form that tracks failure, and skip the sweep when any page failed:

```elixir
      {evaluated, transitions, failed?} =
        normalized
        |> Scope.stream_uids(opts)
        |> Enum.reduce({0, [], false}, fn uids, {count, acc, failed} ->
          case evaluate_devices(check, inputs, rules, uids, opts) do
            {:ok, rows} ->
              {count + length(rows), acc ++ persist_page(check, rows, started_at, actor), failed}

            {:error, reason} ->
              Logger.warning("composite check page evaluation failed",
                check_id: check.id,
                reason: inspect(reason)
              )

              {count, acc, true}
          end
        end)

      removed = if failed?, do: 0, else: sweep_out_of_scope(check, started_at)
```

Add a test to `evaluation_test.exs` asserting that when a page fails, existing result rows survive:

```elixir
  test "a failed page does not delete existing results", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)
    assert {:ok, _} = run(check)

    defmodule FailingRunner do
      def query_page(_query, _opts), do: {:error, :boom}
    end

    assert_raise RuntimeError, fn ->
      Evaluation.run(check, actor: actor(), runner: FailingRunner)
    end

    assert {:ok, _} =
             DeviceCompositeCheckResult.get_by_device_check("device-1", check.id, actor: actor())
  end
```

Note that `Scope.stream_uids/2` currently *raises* on a runner error. Either keep that and let the worker's Oban retry handle it — in which case the sweep never runs, which is the correct outcome — or convert it to a tuple and use the reduce above. Pick one and make the test match; the requirement is only that results are never deleted by a pass that did not complete.

- [ ] **Authorization fix — add the viewer test**

Add to `test/serviceradar/composite_checks/composite_check_test.exs`:

```elixir
  test "a viewer cannot create a composite check" do
    viewer = %{id: Ash.UUID.generate(), role: :viewer}

    assert {:error, %Ash.Error.Forbidden{}} =
             CompositeCheck
             |> Ash.Changeset.for_create(
               :create,
               %{name: "Viewer Attempt", scope_query: "in:devices"},
               actor: viewer
             )
             |> Ash.create()
  end
```

If the actor shape differs, run `rg -n "role: :viewer" elixir/serviceradar_core/test/ | head -3` and copy the existing convention.

**Type consistency:** verified. `Evaluator.verdict/2` returns `{:ok, %{verdict:, status:, matched_rule_id:}}` in Task 8 and is destructured that way in Task 11. Resolvers return `%{value:, observed_at:, stale:, reason:}` in Tasks 6 and 7 and are consumed with those exact keys in `Evaluation.snapshot/1`. `DeviceMetadata.provenance_key/0` is defined in Task 7 and used in Tasks 15 and 16. `ProtectCatchAll.catch_all_position/0` is defined in Task 3 and used in its own resource.

**Placeholder scan:** no TBD, TODO, "implement later", or "similar to Task N" remains. Every code step carries the actual code.

