defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.Summary do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  def load_summary(srql_mod, scope, base) do
    queries = [
      {"#{base} stats:sum(bytes_total) as total_bytes", :total_bytes, "total_bytes"},
      {"#{base} stats:sum(packets_total) as total_packets", :total_packets, "total_packets"},
      {"#{base} stats:count(*) as flow_count", :flow_count, "flow_count"},
      {"#{base} stats:count_distinct(src_endpoint_ip) as unique_talkers", :unique_talkers, "unique_talkers"}
    ]

    queries
    |> Enum.map(fn {q, key, field_alias} ->
      Task.async(fn -> {key, query_single_stat(srql_mod, scope, q, field_alias)} end)
    end)
    |> safe_await_many(10_000)
  end

  def query_single_stat(srql_mod, scope, query, field_alias) do
    srql_mod
    |> srql_results(query, scope)
    |> List.first()
    |> row_payload()
    |> get_field(field_alias)
    |> to_number()
  end

  # §38.1: the actual time span the returned data covers, so rate values
  # (Total Bandwidth, Top-N, gauge) can divide by the *covered* span instead of
  # the requested window — recovering the true rate when the collector has been
  # up for less than the window or data has gaps. Returns the span in seconds
  # (max_time - min_time), or nil if it can't be determined.
  def load_data_span(srql_mod, scope, base) do
    queries = [
      {"#{base} stats:min(time) as min_time", "min_time"},
      {"#{base} stats:max(time) as max_time", "max_time"}
    ]

    results =
      queries
      |> Enum.map(fn {q, alias_name} ->
        Task.async(fn ->
          {alias_name,
           srql_mod
           |> srql_results(q, scope)
           |> List.first()
           |> row_payload()
           |> get_field(alias_name)}
        end)
      end)
      |> safe_await_many(10_000)

    with min_str when is_binary(min_str) <- Map.get(results, :min_time),
         max_str when is_binary(max_str) <- Map.get(results, :max_time),
         {:ok, min_dt, _} <- DateTime.from_iso8601(min_str),
         {:ok, max_dt, _} <- DateTime.from_iso8601(max_str) do
      max(0, DateTime.diff(max_dt, min_dt, :second))
    else
      _ -> nil
    end
  end

  def load_timeseries(srql_mod, scope, base, tw) do
    bucket = timeseries_bucket(tw)
    query = "#{base} bucket:#{bucket} agg:sum value_field:bytes_total"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: to_number(row["value"] || row["bytes_total"] || 0)
          }
        end)

      _ ->
        []
    end
  end
end
