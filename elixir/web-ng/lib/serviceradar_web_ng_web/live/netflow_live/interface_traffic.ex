defmodule ServiceRadarWebNGWeb.NetflowLive.InterfaceTraffic do
  @moduledoc false

  @top_interface_limit 5

  def top_interface_queries(base, limit \\ @top_interface_limit) when is_binary(base) do
    %{
      ingress:
        "#{base} stats:sum(bytes_total) as bytes_total by sampler_address,input_snmp,in_if_name,in_if_speed_bps sort:bytes_total:desc limit:#{limit}",
      egress:
        "#{base} stats:sum(bytes_total) as bytes_total by sampler_address,output_snmp,out_if_name,out_if_speed_bps sort:bytes_total:desc limit:#{limit}"
    }
  end

  def project_top_interfaces(ingress_rows, egress_rows, limit \\ @top_interface_limit) do
    [
      {ingress_rows, :ingress},
      {egress_rows, :egress}
    ]
    |> Enum.flat_map(fn {rows, direction} ->
      rows
      |> List.wrap()
      |> Enum.map(&project_direction_row(&1, direction))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.reduce(%{}, &merge_direction_row/2)
    |> Map.values()
    |> Enum.reject(&((&1.bytes || 0) <= 0))
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(limit)
  end

  def interface_key(sampler, if_index) when is_binary(sampler) and is_integer(if_index) do
    payload = Jason.encode!(%{"sampler" => sampler, "if_index" => if_index})
    Base.url_encode64(payload, padding: false)
  end

  def find_interface(top_interfaces, key) when is_binary(key) do
    Enum.find(top_interfaces, &(&1.key == key))
  end

  def find_interface(_top_interfaces, _key), do: nil

  def timeseries_query(base, %{sampler: sampler, if_index: if_index}, direction, bucket, value_field)
      when direction in [:ingress, :egress] do
    snmp_filter =
      case direction do
        :ingress -> "input_snmp:#{if_index}"
        :egress -> "output_snmp:#{if_index}"
      end

    "#{base} sampler_address:#{srql_quote(sampler)} #{snmp_filter} bucket:#{bucket} agg:sum value_field:#{value_field}"
  end

  def with_p95(%{} = iface, ingress_rows, egress_rows, bucket_secs) do
    values =
      [ingress_rows, egress_rows]
      |> Enum.flat_map(&downsample_values/1)
      |> Enum.group_by(fn {t, _v} -> t end, fn {_t, v} -> v end)
      |> Map.values()
      |> Enum.map(&Enum.sum/1)

    Map.put(iface, :p95_bps, percentile_95(values) * 8 / max(bucket_secs, 1))
  end

  defp project_direction_row(row, direction) do
    payload = row_payload(row)
    sampler = get_field(payload, "sampler_address")
    if_index = payload |> get_field(snmp_field(direction)) |> to_int()
    bytes = payload |> get_field("bytes_total") |> to_number()

    with true <- is_binary(sampler),
         sampler = String.trim(sampler),
         true <- sampler != "",
         true <- is_integer(if_index) and if_index > 0 do
      %{
        key: interface_key(sampler, if_index),
        sampler: sampler,
        if_index: if_index,
        label: interface_label(payload, direction, sampler, if_index),
        bytes: bytes,
        packets: 0,
        capacity_bps: payload |> get_field(speed_field(direction)) |> to_number(),
        ingress_bytes: if(direction == :ingress, do: bytes, else: 0),
        egress_bytes: if(direction == :egress, do: bytes, else: 0),
        p95_bps: 0
      }
    else
      _ -> nil
    end
  end

  defp merge_direction_row(row, acc) do
    Map.update(acc, row.key, row, fn existing ->
      %{
        existing
        | bytes: existing.bytes + row.bytes,
          ingress_bytes: existing.ingress_bytes + row.ingress_bytes,
          egress_bytes: existing.egress_bytes + row.egress_bytes,
          capacity_bps: max(existing.capacity_bps, row.capacity_bps),
          label: choose_label(existing.label, row.label)
      }
    end)
  end

  defp interface_label(payload, direction, sampler, if_index) do
    payload
    |> get_field(name_field(direction))
    |> normalize_label()
    |> case do
      nil -> "#{sampler} if#{if_index}"
      label -> label
    end
  end

  defp choose_label(existing, incoming) do
    normalize_label(existing) || normalize_label(incoming) || existing || incoming
  end

  defp normalize_label(label) when is_binary(label) do
    label = String.trim(label)

    if label == "" or String.downcase(label) == "unknown" do
      nil
    else
      label
    end
  end

  defp normalize_label(_), do: nil

  defp downsample_values(rows) do
    rows
    |> List.wrap()
    |> Enum.map(fn row ->
      payload = row_payload(row)

      {get_field(payload, "timestamp") || get_field(payload, "bucket") || get_field(payload, "time_bucket"),
       get_field(payload, "value") || get_field(payload, "bytes_total")}
    end)
    |> Enum.filter(fn {t, _v} -> not is_nil(t) end)
    |> Enum.map(fn {t, v} -> {t, to_number(v)} end)
  end

  defp percentile_95([]), do: 0

  defp percentile_95(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    idx = min(n - 1, ceil(0.95 * n) - 1)
    Enum.at(sorted, idx) || 0
  end

  defp name_field(:ingress), do: "in_if_name"
  defp name_field(:egress), do: "out_if_name"
  defp snmp_field(:ingress), do: "input_snmp"
  defp snmp_field(:egress), do: "output_snmp"
  defp speed_field(:ingress), do: "in_if_speed_bps"
  defp speed_field(:egress), do: "out_if_speed_bps"

  defp get_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp row_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp row_payload(%{payload: payload}) when is_map(payload), do: payload
  defp row_payload(%{} = row), do: row
  defp row_payload(_), do: %{}

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  defp to_number(nil), do: 0
  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp srql_quote(value) when is_binary(value) do
    escaped = String.replace(value, ~s("), ~s(\\"))
    ~s("#{escaped}")
  end
end
