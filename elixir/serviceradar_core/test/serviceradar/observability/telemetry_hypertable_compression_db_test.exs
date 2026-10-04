defmodule ServiceRadar.Observability.TelemetryHypertableCompressionDbTest do
  @moduledoc """
  Catalog proof that the two largest raw hypertables are compressed behind
  their continuous-aggregate refresh windows.
  """

  use ServiceRadar.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @moduletag :integration

  test "compresses metrics after 6 days and flows after 32 days" do
    assert compression("timeseries_metrics") == %{
             segmentby: ["device_id", "metric_type", "metric_name"],
             orderby: ["timestamp", "gateway_id", "series_key"],
             compress_after: "6 days"
           }

    assert compression("ocsf_network_activity") == %{
             segmentby: ["partition", "protocol_num"],
             orderby: ["time", "flow_uid"],
             compress_after: "32 days"
           }
  end

  defp compression(table) do
    options = reloptions(table)

    %{
      segmentby: csv_columns(option!(options, "timescaledb.compress_segmentby")),
      orderby: order_columns(option!(options, "timescaledb.compress_orderby")),
      compress_after: interval_text(compress_after(table))
    }
  end

  defp reloptions(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT option
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        CROSS JOIN LATERAL unnest(relation.reloptions) AS option
        WHERE namespace.nspname = 'platform' AND relation.relname = $1
        """,
        [table]
      )

    Enum.map(rows, fn [option] -> option end)
  end

  defp option!(options, name) do
    prefix = name <> "="

    case Enum.find(options, &String.starts_with?(&1, prefix)) do
      nil -> flunk("#{name} missing from #{inspect(options)}")
      option -> String.replace_prefix(option, prefix, "")
    end
  end

  defp csv_columns(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp order_columns(value) do
    value
    |> String.split(",")
    |> Enum.map(fn part ->
      part
      |> String.trim()
      |> String.trim("\"")
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.trim("\"")
    end)
  end

  defp compress_after(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT config->>'compress_after'
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_compression'
          AND hypertable_schema = 'platform'
          AND hypertable_name = $1
        """,
        [table]
      )

    case rows do
      [[interval]] when is_binary(interval) -> interval
      other -> flunk("expected one compression policy for #{table}, got #{inspect(other)}")
    end
  end

  defp interval_text(interval) do
    interval
    |> String.trim()
    |> String.replace(~r/\s+00:00:00\z/, "")
  end
end
