defmodule ServiceRadar.FlowAttribution.EventRows do
  @moduledoc false

  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent

  @spec from_event(FlowAttributionEvent.t() | term(), String.t() | nil, String.t() | nil) ::
          map() | nil
  def from_event(%FlowAttributionEvent{} = event, partition_id, agent_id) do
    with proto when is_integer(proto) <- transport_to_proto(event.transport_protocol),
         true <- is_binary(event.local_ip) and event.local_ip != "",
         true <- is_binary(event.remote_ip) and event.remote_ip != "" do
      put_attribution_key(%{
        observed_at: observed_at(event),
        partition: partition_id || "default",
        agent_id: agent_id,
        proto: proto,
        local_ip: event.local_ip,
        local_port: event.local_port || 0,
        remote_ip: event.remote_ip,
        remote_port: event.remote_port || 0,
        pid: zero_to_nil(event.pid),
        comm: blank_to_nil(event.comm),
        cmdline: cmdline_to_string(event.redacted_cmdline),
        uid: zero_to_nil(event.uid),
        container_id: blank_to_nil(event.container_id),
        workload_identity: workload_identity_to_map(event.workload_identity)
      })
    else
      _ -> nil
    end
  end

  def from_event(_event, _partition_id, _agent_id), do: nil

  defp observed_at(%FlowAttributionEvent{observed_at_unix_nano: ns})
       when is_integer(ns) and ns > 0 do
    DateTime.from_unix!(ns, :nanosecond)
  rescue
    _ -> DateTime.utc_now()
  end

  defp observed_at(_event), do: DateTime.utc_now()

  defp zero_to_nil(n) when is_integer(n) and n > 0, do: n
  defp zero_to_nil(_), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp cmdline_to_string(list) when is_list(list), do: list |> Enum.join(" ") |> blank_to_nil()
  defp cmdline_to_string(value) when is_binary(value), do: blank_to_nil(value)
  defp cmdline_to_string(_), do: nil

  defp workload_identity_to_map(nil), do: nil

  defp workload_identity_to_map(identity) do
    %{
      "pod_sandbox_id" => blank_to_nil(Map.get(identity, :pod_sandbox_id)),
      "pod_name" => blank_to_nil(Map.get(identity, :pod_name)),
      "pod_namespace" => blank_to_nil(Map.get(identity, :pod_namespace)),
      "pod_uid" => blank_to_nil(Map.get(identity, :pod_uid)),
      "container_id" => blank_to_nil(Map.get(identity, :container_id)),
      "container_name" => blank_to_nil(Map.get(identity, :container_name)),
      "image" => blank_to_nil(Map.get(identity, :image)),
      "image_ref" => blank_to_nil(Map.get(identity, :image_ref)),
      "runtime_pid" => zero_to_nil(Map.get(identity, :runtime_pid)),
      "cgroup_path" => blank_to_nil(Map.get(identity, :cgroup_path)),
      "runtime_source" => blank_to_nil(Map.get(identity, :runtime_source)),
      "confidence" => blank_to_nil(Map.get(identity, :confidence)),
      "degradation_reason" => blank_to_nil(Map.get(identity, :degradation_reason)),
      "labels" => empty_map_to_nil(Map.get(identity, :labels)),
      "annotations" => empty_map_to_nil(Map.get(identity, :annotations))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> empty_map_to_nil()
  end

  defp empty_map_to_nil(value) when value == %{}, do: nil
  defp empty_map_to_nil(value) when is_map(value), do: value
  defp empty_map_to_nil(_value), do: nil

  # Socket-scoped identity: one attribution row per (agent, 5-tuple), not per
  # process. Host and container views of the same socket must collapse so a
  # later containerized owner can replace a host-only dual emit (e.g. k3s-agent
  # vs beam on the same pod IP:port) without process-name denylists.
  defp put_attribution_key(row) do
    key_parts = [
      Map.get(row, :agent_id),
      Map.fetch!(row, :proto),
      Map.fetch!(row, :local_ip),
      Map.fetch!(row, :local_port),
      Map.fetch!(row, :remote_ip),
      Map.fetch!(row, :remote_port)
    ]

    Map.put(row, :attribution_key, attribution_key(key_parts))
  end

  defp attribution_key(parts) do
    parts
    |> Enum.map_join(<<31>>, &key_part/1)
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp key_part(nil), do: ""
  defp key_part(value), do: to_string(value)

  # IANA protocol numbers.
  defp transport_to_proto(transport) when is_binary(transport) do
    case String.downcase(transport) do
      "tcp" -> 6
      "udp" -> 17
      "icmp" -> 1
      "icmp6" -> 58
      "icmpv6" -> 58
      "ipv6-icmp" -> 58
      _ -> nil
    end
  end

  defp transport_to_proto(transport) when is_integer(transport), do: transport
  defp transport_to_proto(_), do: nil
end
