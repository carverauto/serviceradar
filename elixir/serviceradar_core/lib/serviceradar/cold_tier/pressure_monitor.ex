defmodule ServiceRadar.ColdTier.PressureMonitor do
  @moduledoc """
  Export-stall pressure relief, alerting side (task 2.6; design D5).

  When exports stall, the drop gate holds chunks and the primary volume
  fills — this platform has had exactly that outage class. The monitor
  computes the headroom picture every exporter run and raises escalating
  alerts long before the volume is at risk:

    * database bytes vs the provisioned volume (from
      `SERVICERADAR_CNPG_STORAGE_SIZE`, which the control plane already
      projects, or an explicit bytes override) — thresholds 70/85/95%;
    * held chunks per registry table (older than the hot window but not yet
      droppable because export/verification hasn't caught up), with bytes.

  Alert-only: nothing here ever drops data. The operator-acknowledged
  emergency path is `ServiceRadar.ColdTier.Admin.emergency_drop/3`.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 120_000
  @thresholds [{95, :error}, {85, :error}, {70, :warning}]

  @type report :: %{
          volume_bytes: non_neg_integer() | nil,
          database_bytes: non_neg_integer() | nil,
          usage_pct: float() | nil,
          held: [%{table: String.t(), chunks: non_neg_integer(), bytes: non_neg_integer()}]
        }

  @doc "Compute the pressure picture and emit alerts. Returns the report for telemetry."
  @spec check() :: report()
  def check do
    report = %{
      volume_bytes: volume_bytes(),
      database_bytes: database_bytes(),
      usage_pct: nil,
      held: held_chunks()
    }

    report = %{report | usage_pct: usage_pct(report)}
    alert(report)
    report
  end

  defp usage_pct(%{volume_bytes: v, database_bytes: d})
       when is_integer(v) and v > 0 and is_integer(d),
       do: Float.round(d * 100 / v, 1)

  defp usage_pct(_), do: nil

  defp alert(%{usage_pct: pct, held: held} = report) do
    held_total = Enum.sum(Enum.map(held, & &1.bytes))

    case pct && Enum.find(@thresholds, fn {t, _} -> pct >= t end) do
      {threshold, level} ->
        Logger.log(
          level,
          "Cold tier pressure: database volume #{report.usage_pct}% used " <>
            "(threshold #{threshold}%) with #{format_bytes(held_total)} held " <>
            "past retention awaiting export — if exports are stalled, resolve the " <>
            "analytics head / object store before the volume fills; emergency " <>
            "path: ServiceRadar.ColdTier.Admin.emergency_drop/3",
          usage_pct: report.usage_pct,
          database_bytes: report.database_bytes,
          volume_bytes: report.volume_bytes,
          held: inspect(held)
        )

      nil ->
        if held != [] do
          Logger.info("Cold tier: chunks held past retention awaiting export",
            held: inspect(held),
            held_bytes: held_total
          )
        end
    end
  end

  # Volume consumers on the primary PVC. pg_database_size alone understates
  # real usage — WAL is often the largest non-heap consumer, and a stalled
  # exporter holds chunks that keep both growing (review F34). Sum every
  # database plus the WAL directory, all best-effort so a permission or
  # version quirk degrades to whatever is available rather than nil-ing out
  # the whole pressure check.
  defp database_bytes do
    db = scalar_bytes("SELECT sum(pg_database_size(datname))::bigint FROM pg_database")
    wal = scalar_bytes("SELECT coalesce(sum(size), 0)::bigint FROM pg_ls_waldir()")

    case {db, wal} do
      {nil, nil} -> nil
      {d, w} -> (d || 0) + (w || 0)
    end
  end

  defp scalar_bytes(sql) do
    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, %{rows: [[bytes]]}} when is_integer(bytes) -> bytes
      _ -> nil
    end
  end

  # Chunks held past each registry table's hot retention, in one query.
  #
  # Driven off `timescaledb_information.chunks` — which lists chunks of
  # EXISTING hypertables only — so tables absent from a deployment are
  # skipped naturally, without a `chunks_detailed_size(<name>::regclass)`
  # cast that errors on a missing relation. Chunk sizes come straight from
  # `pg_total_relation_size` on each chunk's own relation. The registry's
  # per-table hot windows are supplied as a VALUES list (table names + integer
  # day counts come from the registry, never from user input).
  defp held_chunks do
    windows =
      Enum.map_join(Registry.tables(), ",\n", fn e ->
        "('#{e.table}', #{Registry.hot_retention_days(e)})"
      end)

    sql = """
    SELECT c.hypertable_name,
           count(*),
           coalesce(
             sum(pg_total_relation_size(format('%I.%I', c.chunk_schema, c.chunk_name)::regclass)),
             0
           )::bigint
    FROM timescaledb_information.chunks c
    JOIN (VALUES #{windows}) AS r(name, hot_days) ON r.name = c.hypertable_name
    WHERE c.hypertable_schema = 'platform'
      AND c.range_end < now() - (r.hot_days * INTERVAL '1 day')
    GROUP BY c.hypertable_name
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        for [table, chunks, bytes] <- rows, chunks > 0 do
          %{table: table, chunks: chunks, bytes: bytes}
        end

      _ ->
        []
    end
  end

  @doc "Provisioned primary volume in bytes, from configuration. Nil when unknown."
  @spec volume_bytes() :: non_neg_integer() | nil
  def volume_bytes do
    explicit = System.get_env("SERVICERADAR_COLD_TIER_PRIMARY_VOLUME_BYTES")
    k8s_size = System.get_env("SERVICERADAR_CNPG_STORAGE_SIZE")

    cond do
      is_binary(explicit) and explicit != "" -> parse_int(explicit)
      is_binary(k8s_size) and k8s_size != "" -> parse_k8s_quantity(k8s_size)
      true -> nil
    end
  end

  @doc false
  def parse_k8s_quantity(quantity) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)\s*(Ki|Mi|Gi|Ti|Pi|K|M|G|T|P)?$/i, String.trim(quantity)) do
      [_, number] ->
        parse_int(number)

      [_, number, unit] ->
        {value, _} = Float.parse(number)
        round(value * unit_multiplier(unit))

      _ ->
        nil
    end
  end

  defp unit_multiplier(unit) do
    case String.downcase(unit) do
      "ki" -> 1024
      "mi" -> 1024 ** 2
      "gi" -> 1024 ** 3
      "ti" -> 1024 ** 4
      "pi" -> 1024 ** 5
      "k" -> 1000
      "m" -> 1000 ** 2
      "g" -> 1000 ** 3
      "t" -> 1000 ** 4
      "p" -> 1000 ** 5
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> nil
    end
  end

  @gib 1_073_741_824
  @mib 1_048_576

  defp format_bytes(bytes) when bytes >= @gib, do: "#{Float.round(bytes / @gib, 1)}GiB"
  defp format_bytes(bytes) when bytes >= @mib, do: "#{Float.round(bytes / @mib, 1)}MiB"
  defp format_bytes(bytes), do: "#{bytes}B"
end
