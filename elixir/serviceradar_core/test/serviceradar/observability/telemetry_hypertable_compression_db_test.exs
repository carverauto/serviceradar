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
    %{segmentby: segmentby, orderby: orderby} = compression_settings(table)

    %{
      segmentby: csv_columns(segmentby),
      orderby: order_columns(orderby),
      compress_after: interval_text(compress_after(table))
    }
  end

  # TimescaleDB consumes timescaledb.compress_segmentby/compress_orderby into
  # its catalog when compression is enabled and strips them from
  # pg_class.reloptions, so the settings view (not reloptions) is the source
  # of truth. A row with NULL settings means compression never landed.
  defp compression_settings(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT segmentby, orderby
        FROM timescaledb_information.hypertable_compression_settings
        WHERE hypertable = to_regclass($1)
        """,
        ["platform.#{table}"]
      )

    case rows do
      [[segmentby, orderby]] when is_binary(segmentby) and is_binary(orderby) ->
        %{segmentby: segmentby, orderby: orderby}

      other ->
        %{rows: debug_rows} =
          SQL.query!(
            Repo,
            "SELECT hypertable::text, segmentby, orderby FROM timescaledb_information.hypertable_compression_settings",
            []
          )

        flunk(
          "expected compression settings for platform.#{table}, got #{inspect(other)}; settings view: #{inspect(debug_rows)}"
        )
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
