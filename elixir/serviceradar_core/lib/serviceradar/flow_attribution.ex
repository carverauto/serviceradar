defmodule ServiceRadar.FlowAttribution do
  @moduledoc """
  Persists netprobe process attributions (5-tuple -> process) pushed by agents,
  and correlates them against collected NetFlow/sFlow in `ocsf_network_activity`.

  NetFlow remains the authoritative flow source — netprobe only supplies the WHO.
  `persist/3` writes each pushed `FlowAttributionEvent` to `flow_process_attributions`;
  `correlate/0` joins recent attributions against recent NetFlow (either direction)
  and stamps matching flows with `event_type=attributed_flow` + the process context,
  which the web UI (`/observability/flows/attributed`) reads.
  """

  alias Netprobepb.FlowAttributionEvent

  require Logger

  @schema "platform"
  @table "flow_process_attributions"
  @correlation_window_minutes 15
  @retention_minutes 60

  @doc "Persist a batch of pushed attribution events."
  @spec persist([FlowAttributionEvent.t()], String.t() | nil, String.t() | nil) :: :ok
  def persist(events, partition_id, agent_id) when is_list(events) do
    rows =
      events
      |> Enum.map(&row_from_event(&1, partition_id, agent_id))
      |> Enum.reject(&is_nil/1)

    if rows != [] do
      ServiceRadar.Repo.insert_all(@table, rows, prefix: @schema)
    end

    :ok
  rescue
    error ->
      Logger.warning("FlowAttribution.persist failed: #{inspect(error)}")
      :ok
  end

  def persist(_events, _partition_id, _agent_id), do: :ok

  defp row_from_event(%FlowAttributionEvent{} = event, partition_id, agent_id) do
    with proto when is_integer(proto) <- transport_to_proto(event.transport_protocol),
         true <- is_binary(event.local_ip) and event.local_ip != "",
         true <- is_binary(event.remote_ip) and event.remote_ip != "" do
      %{
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
        container_id: blank_to_nil(event.container_id)
      }
    else
      _ -> nil
    end
  end

  defp row_from_event(_event, _partition_id, _agent_id), do: nil

  @doc """
  Correlate recent attributions with recent NetFlow and stamp matches as
  `attributed_flow`. Direction-agnostic (matches src->dst or dst->src). Idempotent.
  """
  @spec correlate() :: {:ok, non_neg_integer()} | {:error, term()}
  def correlate do
    sql = """
    UPDATE #{@schema}.ocsf_network_activity AS f
    SET ocsf_payload = f.ocsf_payload
      || jsonb_build_object(
           'event_type', 'attributed_flow',
           'agent_id', a.agent_id,
           'attribution', jsonb_strip_nulls(jsonb_build_object(
             'pid', a.pid,
             'comm', a.comm,
             'redacted_cmdline', a.cmdline,
             'uid', a.uid,
             'container_id', a.container_id
           ))
         )
    FROM #{@schema}.#{@table} AS a
    WHERE f.time > now() - interval '#{@correlation_window_minutes} minutes'
      AND a.observed_at > now() - interval '#{@correlation_window_minutes} minutes'
      AND (f.ocsf_payload ->> 'event_type') IS DISTINCT FROM 'attributed_flow'
      AND f.partition = a.partition
      AND f.protocol_num = a.proto
      AND (
            (f.src_endpoint_ip = a.local_ip AND f.dst_endpoint_ip = a.remote_ip
             AND f.src_endpoint_port = a.local_port AND f.dst_endpoint_port = a.remote_port)
         OR (f.src_endpoint_ip = a.remote_ip AND f.dst_endpoint_ip = a.local_ip
             AND f.src_endpoint_port = a.remote_port AND f.dst_endpoint_port = a.local_port)
          )
    """

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, %{num_rows: num_rows}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete attributions older than the retention window."
  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune do
    sql =
      "DELETE FROM #{@schema}.#{@table} WHERE observed_at < now() - interval '#{@retention_minutes} minutes'"

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, %{num_rows: num_rows}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

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

  # IANA protocol numbers (mirrors AttributedFlowJoiner.transport_to_proto).
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
