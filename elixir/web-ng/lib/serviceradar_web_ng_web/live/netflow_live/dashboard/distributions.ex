defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.Distributions do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Summary

  require Ash.Query

  def load_subnet_distribution(srql_mod, scope, base) do
    cidrs =
      case NetflowLocalCidr
           |> Ash.Query.for_read(:list)
           |> Ash.Query.filter(enabled == true)
           |> Ash.read(scope: scope) do
        {:ok, entries} -> ash_results(entries)
        _ -> []
      end

    if cidrs == [] do
      []
    else
      # Query traffic per local CIDR — run in parallel to avoid sequential round-trips.
      cidrs
      |> Enum.take(10)
      |> Task.async_stream(
        &query_cidr_bytes(&1, srql_mod, scope, base),
        max_concurrency: 5,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        _ -> []
      end)
      |> Enum.reject(&((&1.bytes || 0) <= 0))
      |> Enum.sort_by(& &1.bytes, :desc)
    end
  end

  defp query_cidr_bytes(cidr, srql_mod, scope, base) do
    cidr_str = to_string(cidr.cidr)
    src_query = "#{base} src_cidr:#{srql_quote(cidr_str)} stats:sum(bytes_total) as bytes_total"
    dst_query = "#{base} dst_cidr:#{srql_quote(cidr_str)} stats:sum(bytes_total) as bytes_total"

    src_bytes = Summary.query_single_stat(srql_mod, scope, src_query, "bytes_total")
    dst_bytes = Summary.query_single_stat(srql_mod, scope, dst_query, "bytes_total")
    bytes = src_bytes + dst_bytes

    %{cidr: cidr_str, label: cidr.label || cidr_str, bytes: bytes}
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  def load_tcp_flag_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by tcp_flags_label sort:count:desc limit:10"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        label: get_field(p, "tcp_flags_label") || "unknown",
        count: to_number(get_field(p, "count"))
      }
    end)
  end

  def load_flow_rate_timeseries(srql_mod, scope, base, tw) do
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    query = "#{base} bucket:#{bucket} agg:count"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          count = to_number(row["value"] || row["count"] || row["flow_count"] || 0)

          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: Float.round(count / bucket_secs, 2)
          }
        end)

      _ ->
        []
    end
  end

  def load_duration_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by duration_bucket"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        bucket: get_field(p, "duration_bucket") || "unknown",
        count: to_number(get_field(p, "count"))
      }
    end)
  end
end
