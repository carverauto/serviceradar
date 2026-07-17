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

  defp database_bytes do
    case SQL.query(Repo, "SELECT pg_database_size(current_database())", [],
           timeout: @query_timeout_ms
         ) do
      {:ok, %{rows: [[bytes]]}} -> bytes
      _ -> nil
    end
  end

  defp held_chunks do
    Enum.flat_map(Registry.tables(), fn entry ->
      sql = """
      SELECT count(*), coalesce(sum(d.total_bytes), 0)
      FROM timescaledb_information.chunks c
      JOIN chunks_detailed_size($1::regclass) d ON d.chunk_name = c.chunk_name
      WHERE c.hypertable_schema = 'platform'
        AND c.hypertable_name = $2
        AND c.range_end < now() - ($3 * INTERVAL '1 day')
      """

      params = ["platform.#{entry.table}", entry.table, Registry.hot_retention_days(entry)]

      case SQL.query(Repo, sql, params, timeout: @query_timeout_ms) do
        {:ok, %{rows: [[chunks, bytes]]}} when chunks > 0 ->
          [%{table: entry.table, chunks: chunks, bytes: bytes}]

        _ ->
          []
      end
    end)
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
