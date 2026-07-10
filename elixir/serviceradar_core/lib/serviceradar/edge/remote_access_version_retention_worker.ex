defmodule ServiceRadar.Edge.RemoteAccessVersionRetentionWorker do
  @moduledoc """
  Purges stale remote-access PaperTrail version rows.

  The parent resources are configured with `ON DELETE CASCADE`, so this worker
  covers long-lived source rows whose version history should age out separately.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @default_retention_days 90
  @default_batch_size 10_000
  @query_timeout_ms 120_000

  @version_tables [
    {"remote_access_session_versions", :session_version_retention_days},
    {"remote_access_request_versions", :request_version_retention_days},
    {"remote_access_desktop_target_versions", :desktop_target_version_retention_days},
    {"remote_access_host_key_versions", :host_key_version_retention_days}
  ]

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    deleted =
      @version_tables
      |> Enum.map(fn {table, retention_key} ->
        prune_table(table, retention_days(config, retention_key), batch_size)
      end)
      |> Enum.sum()

    Logger.info("RemoteAccessVersionRetention: pruned stale version rows", deleted_rows: deleted)
    :ok
  end

  defp retention_days(config, key), do: Keyword.get(config, key, @default_retention_days)

  defp prune_table(_table, nil, _batch_size), do: 0

  defp prune_table(table, retention_days, batch_size)
       when is_integer(retention_days) and retention_days > 0 do
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
        Logger.error("RemoteAccessVersionRetention: prune failed",
          table: table,
          reason: inspect(reason)
        )

        0
    end
  end

  defp prune_table(_table, _retention_days, _batch_size), do: 0
end
