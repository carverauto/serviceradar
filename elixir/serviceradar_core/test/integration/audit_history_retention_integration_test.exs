defmodule ServiceRadar.AuditHistoryRetentionIntegrationTest do
  @moduledoc """
  DB-backed coverage for the add-audit-history-retention-compression
  workers: `ServiceRadar.Security.AuditVersionRetentionWorker` (batched raw
  SQL over the PaperTrail version tables), and the single-table
  `ApiEventsRetentionWorker` / `SecurityEventsRetentionWorker` pair.

  Seeds rows on both sides of each retention boundary and drives the public
  `perform/1` of every worker, asserting only rows older than the effective
  window are deleted: at tier defaults, under a per-table override, with a
  table disabled at 0, and under a batch_size smaller than the seeded row
  count (one perform deletes at most batch_size rows per table).

  DB-gated; run with:

      mix test --include integration \\
        test/integration/audit_history_retention_integration_test.exs
  """
  use ServiceRadar.DataCase, async: false

  alias Ash.Seed
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Jobs.SecurityEventsRetentionWorker
  alias ServiceRadar.Observability.ApiEvent
  alias ServiceRadar.Observability.ApiEventsRetentionWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.AuditVersionRetentionWorker
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    prev_audit = Application.get_env(:serviceradar_core, AuditVersionRetentionWorker)
    prev_api = Application.get_env(:serviceradar_core, ApiEventsRetentionWorker)
    prev_security = Application.get_env(:serviceradar_core, SecurityEventsRetentionWorker)

    on_exit(fn ->
      restore_env(AuditVersionRetentionWorker, prev_audit)
      restore_env(ApiEventsRetentionWorker, prev_api)
      restore_env(SecurityEventsRetentionWorker, prev_security)
    end)

    :ok
  end

  test "version worker prunes only rows past the 180-day config-trail default" do
    Application.delete_env(:serviceradar_core, AuditVersionRetentionWorker)

    old_id = insert_version_row("auth_lockout_versions", 200)
    recent_id = insert_version_row("auth_lockout_versions", 10)

    assert :ok = AuditVersionRetentionWorker.perform(%Oban.Job{})

    assert count_rows("auth_lockout_versions") == 1
    refute row_exists("auth_lockout_versions", old_id)
    assert row_exists("auth_lockout_versions", recent_id)
  end

  test "version worker honors a per-table override window" do
    # 10 days is inside the 180-day default but outside a 5-day override,
    # so this row's deletion proves the override (not the tier) drove the cut.
    Application.put_env(:serviceradar_core, AuditVersionRetentionWorker, auth_lockout_days: 5)

    old_id = insert_version_row("auth_lockout_versions", 200)
    mid_id = insert_version_row("auth_lockout_versions", 10)

    assert :ok = AuditVersionRetentionWorker.perform(%Oban.Job{})

    assert count_rows("auth_lockout_versions") == 0
    refute row_exists("auth_lockout_versions", old_id)
    refute row_exists("auth_lockout_versions", mid_id)
  end

  test "version worker skips a table disabled at 0" do
    Application.put_env(:serviceradar_core, AuditVersionRetentionWorker, auth_lockout_days: 0)

    old_id = insert_version_row("auth_lockout_versions", 200)

    assert :ok = AuditVersionRetentionWorker.perform(%Oban.Job{})

    assert row_exists("auth_lockout_versions", old_id)
  end

  test "version worker deletes at most batch_size rows per table per run" do
    Application.put_env(:serviceradar_core, AuditVersionRetentionWorker, batch_size: 2)

    for _ <- 1..5, do: insert_version_row("sweep_group_versions", 200)

    assert :ok = AuditVersionRetentionWorker.perform(%Oban.Job{})

    # 5 stale rows, batch_size 2: one perform must leave 3 behind rather
    # than attempting an unbounded delete.
    assert count_rows("sweep_group_versions") == 3

    assert :ok = AuditVersionRetentionWorker.perform(%Oban.Job{})
    assert count_rows("sweep_group_versions") == 1
  end

  test "api events worker prunes only rows past its default window" do
    Application.delete_env(:serviceradar_core, ApiEventsRetentionWorker)

    old_id = insert_api_event(200)
    recent_id = insert_api_event(10)

    assert :ok = ApiEventsRetentionWorker.perform(%Oban.Job{})

    assert count_rows("api_events") == 1
    refute row_exists("api_events", old_id)
    assert row_exists("api_events", recent_id)
  end

  test "security events worker still prunes at 90 days with no override set" do
    # No configured retention_days: the hardcoded 90-day default must hold
    # (no behavior regression from the new env wiring).
    Application.delete_env(:serviceradar_core, SecurityEventsRetentionWorker)

    old_id = insert_security_event(200)
    recent_id = insert_security_event(10)

    assert :ok = SecurityEventsRetentionWorker.perform(%Oban.Job{})

    assert count_rows("security_events") == 1
    refute row_exists("security_events", old_id)
    assert row_exists("security_events", recent_id)
  end

  ## Seeding helpers (all identifiers synthetic)

  defp insert_version_row(table, days_ago) do
    id = Ecto.UUID.generate()
    occurred = DateTime.shift(DateTime.utc_now(), day: -days_ago)

    SQL.query!(
      Repo,
      "INSERT INTO platform.#{table} " <>
        "(id, version_action_type, version_action_name, version_source_id, " <>
        "version_inserted_at, version_updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $5)",
      [Ecto.UUID.dump!(id), "create", "create", Ecto.UUID.dump!(Ecto.UUID.generate()), occurred]
    )

    id
  end

  defp insert_api_event(days_ago) do
    event =
      Seed.seed!(ApiEvent, %{
        record_id: Ecto.UUID.generate(),
        resource: ServiceRadar.Observability.StatefulAlertRule,
        action: "update",
        action_type: :update,
        occurred_at: DateTime.shift(DateTime.utc_now(), day: -days_ago)
      })

    event.id
  end

  defp insert_security_event(days_ago) do
    event =
      Seed.seed!(SecurityEvent, %{
        kind: :other,
        severity: :info,
        occurred_at: DateTime.shift(DateTime.utc_now(), day: -days_ago)
      })

    event.id
  end

  ## Read helpers

  defp count_rows(table) do
    %Postgrex.Result{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM platform.#{table}", [])

    count
  end

  defp row_exists(table, id) do
    %Postgrex.Result{rows: [[count]]} =
      SQL.query!(Repo, "SELECT count(*) FROM platform.#{table} WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    count == 1
  end

  defp restore_env(module, prev) do
    if is_nil(prev) do
      Application.delete_env(:serviceradar_core, module)
    else
      Application.put_env(:serviceradar_core, module, prev)
    end
  end
end
