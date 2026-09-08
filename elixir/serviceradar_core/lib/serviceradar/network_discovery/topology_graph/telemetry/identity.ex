defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Identity do
  @moduledoc false

  import Ecto.Query

  alias ServiceRadar.Repo

  def build_device_identity(device_uids) when is_list(device_uids) do
    uid_set =
      device_uids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    ip_to_uid =
      case MapSet.size(uid_set) do
        0 ->
          %{}

        _ ->
          uid_list = MapSet.to_list(uid_set)

          from(d in "ocsf_devices",
            where: fragment("? = ANY(?)", d.uid, type(^uid_list, {:array, :string})),
            select: {d.uid, d.ip}
          )
          |> Repo.all()
          |> Enum.reduce(%{}, &reduce_device_ip_row/2)
      end

    %{uid_set: uid_set, ip_to_uid: ip_to_uid}
  end

  def telemetry_metric_device_ids(%{uid_set: uid_set, ip_to_uid: ip_to_uid}) do
    Enum.uniq(MapSet.to_list(uid_set) ++ Map.keys(ip_to_uid))
  end

  def telemetry_metric_ips(%{ip_to_uid: ip_to_uid}) when is_map(ip_to_uid),
    do: Map.keys(ip_to_uid)

  def canonical_metric_device_id(device_id, target_ip, identity) do
    cond do
      is_binary(device_id) and
          MapSet.member?(Map.get(identity, :uid_set, MapSet.new()), device_id) ->
        device_id

      is_binary(device_id) ->
        ip = extract_metric_device_ip(device_id)
        Map.get(Map.get(identity, :ip_to_uid, %{}), ip)

      true ->
        nil
    end || Map.get(Map.get(identity, :ip_to_uid, %{}), extract_metric_device_ip(target_ip))
  end

  def extract_metric_device_ip(value) when is_binary(value) do
    normalized = normalize_ip(value)

    cond do
      valid_ip?(normalized) ->
        normalized

      String.contains?(value, ":") ->
        case String.split(String.trim(value), ":", parts: 2) do
          [partition, candidate] when partition != "sr" ->
            candidate = normalize_ip(candidate)
            if valid_ip?(candidate), do: candidate

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  def extract_metric_device_ip(_), do: nil

  defp normalize_ip(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp valid_ip?(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp valid_ip?(_), do: false

  defp reduce_device_ip_row({uid, ip}, acc) do
    with true <- is_binary(uid),
         true <- is_binary(ip),
         trimmed when trimmed != "" <- String.trim(ip) do
      Map.put(acc, trimmed, uid)
    else
      _ -> acc
    end
  end
end
