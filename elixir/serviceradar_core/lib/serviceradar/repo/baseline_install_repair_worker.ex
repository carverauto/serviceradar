defmodule ServiceRadar.Repo.BaselineInstallRepairWorker do
  @moduledoc """
  Gives a database created from an older schema baseline the state that baseline left out.

  Until the baseline carried them, a database created from it never got the rows the migrations
  it covers seed, nor any TimescaleDB compression setting, compression policy or retention
  policy those migrations configure: the baseline records the migrations as applied and they
  never run. The current baseline carries both, in sections `ServiceRadar.Repo.SchemaBootstrap`
  can read back, so this worker repairs an older install from them rather than from a second
  copy of the migrations' values:

    * a compression setting is applied to a hypertable whose compression is off;
    * every compression and retention policy is added unless the hypertable already has one,
      so a policy an operator or a runtime owner has since changed is left alone;
    * a table's seed rows are inserted only while the table is empty, so rows an operator has
      created since are never duplicated or overwritten.

  It runs only on a database the baseline created (`platform.serviceradar_schema_baselines`
  exists); a replayed database already has all of this. Enqueued once by migration
  `20261115233000_repair_baseline_install_state`. Every step is idempotent, so a retry repeats
  only what is still missing.

  Two pieces have their own owners and are skipped: compression on `timeseries_metrics`
  (`ServiceRadar.Observability.DataRetentionWorker`) and the default SNMP profile (migration
  `20261115191431_attach_standard_snmp_templates_to_default_profile`).

  `ALTER TABLE ... SET (timescaledb.compress ...)` takes an exclusive lock on a hypertable that
  ingestion writes to, so it runs under a short `lock_timeout`; on timeout the job fails and
  Oban retries it later instead of queueing writers behind it.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.SchemaBootstrap

  require Logger

  @compression_owned_elsewhere ~w(timeseries_metrics)
  @seed_owned_elsewhere ~w(snmp_profiles)
  @lock_timeout "10s"

  @compression_setting ~r/\AALTER TABLE platform\.(\w+) SET \(timescaledb\.compress\b/
  @policy ~r/\.add_(compression|retention)_policy\('platform\.(\w+)'/
  @seed_insert ~r/\AINSERT INTO platform\.(\w+) /

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if baseline_install?() do
      with :ok <-
             repair_policies(SchemaBootstrap.baseline_section_statements!(:timescaledb_policies)) do
        repair_seed_rows(SchemaBootstrap.baseline_section_statements!(:seed_data))
      end
    else
      :ok
    end
  end

  defp baseline_install? do
    %{rows: [[present?]]} =
      Repo.query!("SELECT to_regclass('platform.serviceradar_schema_baselines') IS NOT NULL")

    present?
  end

  defp repair_policies(statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case repair_policy(statement) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp repair_policy(statement) do
    cond do
      match = Regex.run(@compression_setting, statement, capture: :all_but_first) ->
        [table] = match
        enable_compression(table, statement)

      match = Regex.run(@policy, statement, capture: :all_but_first) ->
        [kind, table] = match
        add_policy(kind, table, statement)

      true ->
        :ok
    end
  end

  defp enable_compression(table, _statement) when table in @compression_owned_elsewhere, do: :ok

  defp enable_compression(table, statement) do
    if compression_enabled?(table) do
      :ok
    else
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")
          Repo.query!(statement)
        end)

      Logger.info("Enabled compression on a baseline-created hypertable", table: table)
      :ok
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning("Could not enable compression; will retry",
        table: table,
        error: Exception.message(error)
      )

      {:error, error}
  end

  defp add_policy("compression", table, _statement) when table in @compression_owned_elsewhere,
    do: :ok

  # A compression policy needs compression on, which the setting statement before it ensured.
  defp add_policy("compression", table, statement) do
    if compression_enabled?(table) and not has_policy?("policy_compression", table) do
      Repo.query!(statement)
    end

    :ok
  end

  defp add_policy("retention", table, statement) do
    if !has_policy?("policy_retention", table), do: Repo.query!(statement)
    :ok
  end

  defp compression_enabled?(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT compression_enabled FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform' AND hypertable_name = $1
        """,
        [table]
      )

    rows == [[true]]
  end

  defp has_policy?(proc_name, table) do
    %{rows: [[present?]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM timescaledb_information.jobs
          WHERE proc_name = $1 AND hypertable_schema = 'platform' AND hypertable_name = $2
        )
        """,
        [proc_name, table]
      )

    present?
  end

  # The section disables user triggers around each table's rows, which is right for an empty
  # database being created and wrong for a live one: here the rows go in like any other write.
  defp repair_seed_rows(statements) do
    statements
    |> Enum.flat_map(fn statement ->
      case Regex.run(@seed_insert, statement, capture: :all_but_first) do
        [table] -> [{table, statement}]
        nil -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reject(fn {table, _} -> table in @seed_owned_elsewhere end)
    |> Enum.each(fn {table, inserts} -> seed_if_empty(table, inserts) end)
  end

  defp seed_if_empty(table, inserts) do
    Repo.transaction(fn ->
      %{rows: [[empty?]]} =
        Repo.query!("SELECT NOT EXISTS (SELECT 1 FROM platform.#{table})")

      if empty? do
        Enum.each(inserts, &Repo.query!/1)
        Logger.info("Seeded a baseline-created table", table: table, rows: length(inserts))
      end
    end)
  end
end
