defmodule ServiceRadar.Security.AuditVersionRetentionWorker do
  @moduledoc """
  Purges stale PaperTrail version rows behind Settings -> Audit -> History.

  Covers every `*_versions` table in the
  `ServiceRadar.Security.AuditHistory.resources/0` allow-list **except** the
  four `remote_access_*_versions` tables
  `ServiceRadar.Edge.RemoteAccessVersionRetentionWorker` already prunes
  (those resources are outside the History allow-list; see that worker's
  moduledoc). Sibling worker and same batched raw-SQL `DELETE` shape as that
  one: a maintenance sweep bypassing Ash/policy overhead is the established
  pattern here, not a new one.

  Per-table retention windows follow the two tiers in
  `helm/serviceradar/values.yaml` (`core.auditHistoryRetention`):

    * **90 days** — execution/event-tier tables: every playbook run, every
      northbound action invocation and event-handler dispatch.
    * **180 days** — config-audit-trail tables: who changed a credential,
      controller, playbook, schedule, repository, action provider or
      descriptor, visibility profile, lockout, dashboard, report schedule,
      or sweep group.

  Every window defaults per tier and is env-overridable per table
  (`AUDIT_RETENTION_<TABLE>_DAYS` -> `config :serviceradar_core,
  #{__MODULE__}, <table>_days: N`); `0` disables pruning for that table,
  matching `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` semantics. `sweep_group_versions`
  joined the History allow-list after the proposal was written and inherits
  the config-audit-trail tier.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @default_batch_size 10_000
  @query_timeout_ms 120_000

  @version_tables [
    # Execution/event tier (90 days).
    {"ansible_playbook_run_versions", :ansible_playbook_run_days, 90},
    {"northbound_action_invocation_versions", :northbound_action_invocation_days, 90},
    {"northbound_action_event_handler_versions", :northbound_action_event_handler_days, 90},
    # Config-audit-trail tier (180 days).
    {"network_credential_secret_versions", :network_credential_secret_days, 180},
    {"network_credential_rule_versions", :network_credential_rule_days, 180},
    {"proxmox_console_session_versions", :proxmox_console_session_days, 180},
    {"ansible_controller_versions", :ansible_controller_days, 180},
    {"ansible_playbook_versions", :ansible_playbook_days, 180},
    {"ansible_playbook_schedule_versions", :ansible_playbook_schedule_days, 180},
    {"ansible_playbook_repository_versions", :ansible_playbook_repository_days, 180},
    {"northbound_action_provider_versions", :northbound_action_provider_days, 180},
    {"northbound_action_descriptor_versions", :northbound_action_descriptor_days, 180},
    {"visibility_profile_versions", :visibility_profile_days, 180},
    {"auth_lockout_versions", :auth_lockout_days, 180},
    {"authored_dashboard_versions", :authored_dashboard_days, 180},
    {"dashboard_report_schedule_versions", :dashboard_report_schedule_days, 180},
    {"sweep_group_versions", :sweep_group_days, 180}
  ]

  @doc """
  The covered `{table, retention_config_key, default_days}` triples.
  """
  @spec version_tables() :: [{String.t(), atom(), pos_integer()}]
  def version_tables, do: @version_tables

  @doc """
  Resolves the effective retention window (days) for `table`: the
  configured override when present, else the tier default.
  """
  @spec retention_days(String.t()) :: integer() | nil
  def retention_days(table) when is_binary(table) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case List.keyfind(@version_tables, table, 0) do
      {_table, key, default} -> Keyword.get(config, key, default)
      nil -> nil
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    deleted =
      @version_tables
      |> Enum.map(fn {table, _key, _default} ->
        prune_table(table, retention_days(table), batch_size)
      end)
      |> Enum.sum()

    Logger.info("AuditVersionRetention: pruned stale version rows", deleted_rows: deleted)
    :ok
  end

  defp prune_table(_table, days, _batch_size) when not is_integer(days), do: 0
  defp prune_table(_table, days, _batch_size) when days <= 0, do: 0

  defp prune_table(table, retention_days, batch_size) when is_integer(retention_days) do
    sql = """
    DELETE FROM platform.#{table}
    WHERE id IN (
      SELECT id
      FROM platform.#{table}
      WHERE version_inserted_at < (now() AT TIME ZONE 'utc') - ($1::int * INTERVAL '1 day')
      ORDER BY version_inserted_at ASC
      LIMIT $2
    )
    """

    case SQL.query(Repo, sql, [retention_days, batch_size], timeout: @query_timeout_ms) do
      {:ok, %Postgrex.Result{num_rows: rows}} ->
        rows

      {:error, reason} ->
        Logger.error("AuditVersionRetention: prune failed",
          table: table,
          reason: inspect(reason)
        )

        0
    end
  end
end
