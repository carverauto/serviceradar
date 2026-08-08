defmodule ServiceRadar.ColdTier.Admin do
  @moduledoc """
  Operator-only cold-tier actions (task 2.6: two-phase disable + emergency
  drop). Every function here requires an explicit confirmation token and is
  loudly audited — nothing in the scheduled pipeline calls this module.

  On a release: `bin/serviceradar_core rpc "ServiceRadar.ColdTier.Admin.<fn>(...)"`.
  In dev: the `mix sr.cold_tier.*` tasks wrap these.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  require Logger

  @waive_token "DISCARD-UNEXPORTED"
  @drop_token "DROP-WITHOUT-EXPORT"
  @query_timeout_ms 300_000

  @doc """
  Second phase of disabling the cold tier: acknowledge that un-exported data
  may be discarded and clear the residue state (boundaries + non-verified
  manifest rows) that keeps the retention fence engaged after
  `SERVICERADAR_COLD_TIER_ENABLED` is unset. After this, standard retention
  policies re-arm on the next retention run.

      waive(:all, confirm: "#{@waive_token}")
      waive("logs", confirm: "#{@waive_token}")
  """
  @spec waive(:all | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def waive(scope, opts \\ [])

  def waive(scope, opts) do
    with :ok <- require_token(opts, @waive_token),
         {:ok, tables} <- resolve_scope(scope) do
      if Registry.enabled?() do
        {:error, :cold_tier_still_enabled}
      else
        results =
          Map.new(tables, fn table ->
            %{num_rows: manifest} =
              SQL.query!(
                Repo,
                "DELETE FROM platform.cold_chunk_exports WHERE table_name = $1 AND status <> 'verified'",
                [table],
                timeout: @query_timeout_ms
              )

            %{num_rows: boundaries} =
              SQL.query!(
                Repo,
                "DELETE FROM platform.cold_tier_boundaries WHERE table_name = $1",
                [table],
                timeout: @query_timeout_ms
              )

            {table, %{manifest_rows_discarded: manifest, boundaries_cleared: boundaries}}
          end)

        Logger.error(
          "Cold tier WAIVED by operator: residue cleared; standard retention " <>
            "re-arms on the next retention run and un-exported data past the " <>
            "hot window WILL be dropped",
          results: inspect(results)
        )

        {:ok, results}
      end
    end
  end

  @doc """
  Emergency pressure relief: drop chunks of `table` older than `upto`
  (ISO8601), bypassing the export gate. Only for a stalled cold tier that is
  about to fill the primary volume. Data in the dropped range that was not
  verified-exported is PERMANENTLY LOST.

      emergency_drop("timeseries_metrics", "2026-07-01T00:00:00Z", confirm: "#{@drop_token}")
  """
  @spec emergency_drop(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def emergency_drop(table, upto, opts \\ []) do
    with :ok <- require_token(opts, @drop_token),
         true <- Registry.member?(table) || {:error, {:not_a_registry_table, table}},
         {:ok, cutoff, _} <- DateTime.from_iso8601(upto) do
      %{rows: [[unexported]]} =
        SQL.query!(
          Repo,
          """
          SELECT count(*)
          FROM timescaledb_information.chunks c
          LEFT JOIN platform.cold_chunk_exports m
            ON m.table_name = $1 AND m.chunk_name = c.chunk_name AND m.status = 'verified'
          WHERE c.hypertable_schema = 'platform' AND c.hypertable_name = $1
            AND c.range_end <= $2 AND m.id IS NULL
          """,
          [table, cutoff],
          timeout: @query_timeout_ms
        )

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT drop_chunks($1::regclass, older_than => $2::timestamptz)",
          ["platform.#{table}", cutoff],
          timeout: @query_timeout_ms
        )

      Logger.error(
        "Cold tier EMERGENCY DROP executed by operator: chunks dropped bypassing " <>
          "the export gate; #{unexported} chunk(s) in the range had NO verified " <>
          "export and are permanently lost",
        table: table,
        upto: upto,
        dropped_chunks: length(rows),
        unexported_chunks: unexported
      )

      {:ok, %{dropped_chunks: length(rows), unexported_chunks_lost: unexported}}
    end
  end

  defp require_token(opts, token) do
    if Keyword.get(opts, :confirm) == token do
      :ok
    else
      {:error, {:confirmation_required, "pass confirm: \"#{token}\""}}
    end
  end

  defp resolve_scope(:all), do: {:ok, Registry.table_names()}

  defp resolve_scope(table) when is_binary(table) do
    if Registry.member?(table), do: {:ok, [table]}, else: {:error, {:not_a_registry_table, table}}
  end
end
