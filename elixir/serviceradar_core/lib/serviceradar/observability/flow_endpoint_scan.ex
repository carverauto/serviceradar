defmodule ServiceRadar.Observability.FlowEndpointScan do
  @moduledoc false

  @default_page_size 5_000
  @fields ["src_endpoint_ip", "dst_endpoint_ip"]
  @placeholders ["", "—", "-", "Unknown"]

  @spec default_page_size() :: pos_integer()
  def default_page_size, do: @default_page_size

  # Every endpoint address seen in the window. `page_size` is the size of one
  # fetch, not a bound on the result: a full page continues from the last
  # address it returned, and only a short page ends the scan. The window is
  # fixed to absolute timestamps once so it cannot slide between pages.
  @spec discover(pos_integer(), pos_integer(), module(), DateTime.t()) :: [String.t()]
  def discover(window_seconds, page_size, runner, now \\ DateTime.utc_now())
      when is_integer(window_seconds) and window_seconds > 0 and is_integer(page_size) and
             page_size > 0 do
    finish = DateTime.truncate(now, :second)
    start = DateTime.add(finish, -window_seconds, :second)
    range = "[#{DateTime.to_iso8601(start)},#{DateTime.to_iso8601(finish)}]"

    @fields
    |> Enum.flat_map(&scan_field(&1, range, page_size, runner, nil, []))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in @placeholders))
    |> Enum.uniq()
  end

  defp scan_field(field, range, page_size, runner, after_ip, acc) do
    query = page_query(field, range, page_size, after_ip)

    case runner.query_page(query, []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        ips = Enum.flat_map(rows, &endpoint_ip(&1, field))
        acc = [ips | acc]
        last = rows |> List.last() |> endpoint_ip(field)

        if length(rows) < page_size or last == [] do
          acc |> Enum.reverse() |> Enum.concat()
        else
          scan_field(field, range, page_size, runner, hd(last), acc)
        end

      {:ok, other} ->
        raise "flow endpoint scan returned an unexpected page: #{inspect(other)}"

      {:error, reason} ->
        raise "flow endpoint scan failed: #{inspect(reason)}"
    end
  end

  defp page_query(field, range, page_size, after_ip) do
    ~s|in:flows time:#{range} window_scan:true stats:"sum(bytes_total) as total_bytes by #{field}" | <>
      keyset_filter(field, after_ip) <>
      "sort:#{field}:asc limit:#{page_size}"
  end

  defp keyset_filter(_field, nil), do: ""

  defp keyset_filter(field, ip) do
    if String.contains?(ip, ["\"", "'", "`"]) do
      raise "flow endpoint scan cannot continue past #{inspect(ip)}"
    end

    ~s|#{field}:">#{ip}" |
  end

  defp endpoint_ip(%{"result" => %{} = payload}, field), do: endpoint_ip(payload, field)

  defp endpoint_ip(row, field) when is_map(row) do
    case Map.get(row, field) do
      ip when is_binary(ip) -> [ip]
      _ -> []
    end
  end

  defp endpoint_ip(_row, _field), do: []
end
