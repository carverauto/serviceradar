defmodule ServiceRadar.EventWriter.AttributedFlowJoiner do
  @moduledoc """
  ETS-backed TTL cache that joins host-slice `FlowMessage`s with sidecar
  `FlowAttributionEvent`s on a canonical 5-tuple key and republishes the merged
  result to `flow.attributed.<self_partition_id>` for the existing
  `EventWriter.Processors.Flows` consumer.

  ## Inputs

    * `put_host_slice/3` — a `Flowpb.AttributedFlowMessage` arriving on
      `flow.host-slice.<agent-id>` (attribution field empty); decoded by
      `ServiceRadar.EventWriter.HostSliceSubscriber`.
    * `put_attribution/3` — a `Netprobepb.FlowAttributionEvent` decoded by
      `ServiceRadar.StatusHandler` from a `FlowAttributionEventBatch` carried
      inside a `Monitoring.GatewayServiceStatus` envelope with
      `source == "flow-attribution"`.

  ## Canonical key

  The join key is a flat tuple
  `{proto_num, ip_lo, port_lo, ip_hi, port_hi}` where the pair with the
  numerically-smaller IP binary sorts first. IPs are stored as 4-byte (IPv4)
  or 16-byte (IPv6) binaries — never as strings — so TCP reply flows match
  their forward direction without redundant entries. Partition is **not** part
  of the key: partition only arrives with attribution (and is cert-derived);
  including it would prevent host-slice records from being looked up.

  ## TTL + eviction

  Default TTL is 60 s (configurable via `:ttl_ms`). A periodic sweep runs every
  10 s and removes expired entries via `:ets.select_delete/2`. A soft cap of
  250 000 entries is enforced with oldest-eviction, modelled on
  `ServiceRadar.Identity.IdentityCache`.

  ## Security — published partition

  The published subject `flow.attributed.<P>` always uses
  `state.self_partition_id` (the partition this core-elx instance owns, from
  `SERVICERADAR_OTX_PARTITION`), **never** any field from an agent-supplied
  record. Agents are NATS-denied from publishing `flow.attributed.>`, so this
  module is the only writer; using a server-controlled partition value
  preserves the post-B-4 security boundary.
  """

  use GenServer

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowAttribution
  alias Flowpb.FlowMessage
  alias Netprobepb.FlowAttributionEvent
  alias ServiceRadar.NATS.Connection

  require Logger

  @table_name :serviceradar_attributed_flow_join
  @default_ttl_ms to_timeout(minute: 1)
  @cleanup_interval_ms to_timeout(second: 10)
  @max_size 250_000
  @eviction_scan_chunk 1_000

  @attributed_flow_event_type "attributed_flow"
  @attributed_flow_subject_prefix "flow.attributed."

  @telemetry_host_slice [:serviceradar, :event_writer, :attributed_flow, :host_slice_received]
  @telemetry_attribution [:serviceradar, :event_writer, :attributed_flow, :attribution_received]
  @telemetry_joined [:serviceradar, :event_writer, :attributed_flow, :joined_and_published]
  @telemetry_orphan [:serviceradar, :event_writer, :attributed_flow, :orphan_timeout_drops]
  @telemetry_publish_failed [:serviceradar, :event_writer, :attributed_flow, :publish_failed]
  @telemetry_evicted [:serviceradar, :event_writer, :attributed_flow, :evicted_oversize]

  # Client API

  @doc """
  Starts the joiner.

  ## Options

    * `:ttl_ms` — entry TTL in milliseconds (default: 60 000).
    * `:max_size` — soft cap on entries (default: 250 000).
    * `:self_partition_id` — the partition this core-elx instance owns. If
      omitted, falls back to `Application.get_env(:serviceradar_core,
      ServiceRadar.EventWriter.AttributedFlowJoiner)[:self_partition_id]` and
      finally to `"default"`.
    * `:publisher` — `{module, function, extra_args}` used to publish merged
      messages (default: `{ServiceRadar.NATS.Connection, :publish, []}`).
      Tests can inject a stub.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ingest a host-slice `AttributedFlowMessage` (attribution field empty).

  Returns `:ok | {:published, count}` — `count` is the number of merged
  messages published as a side effect of this call.
  """
  @spec put_host_slice(AttributedFlowMessage.t() | term(), String.t() | nil, keyword()) ::
          :ok | {:published, non_neg_integer()}
  def put_host_slice(msg, agent_id, opts \\ [])

  def put_host_slice(%AttributedFlowMessage{flow: %FlowMessage{} = flow} = msg, agent_id, opts) do
    case canonical_key_from_flow(flow) do
      nil ->
        :ok

      key ->
        emit(@telemetry_host_slice, %{count: 1}, %{agent_id: agent_id})
        GenServer.call(__MODULE__, {:put_host_slice, key, msg, agent_id, opts})
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  def put_host_slice(_other, _agent_id, _opts), do: :ok

  @doc """
  Ingest a sidecar `FlowAttributionEvent`. `partition_id` MUST be the
  cert-derived partition surfaced by the agent-gateway (it is only used for
  telemetry tags — the *published* partition is always the server's own).
  """
  @spec put_attribution(FlowAttributionEvent.t() | term(), String.t(), keyword()) ::
          :ok | {:published, non_neg_integer()}
  def put_attribution(event, partition_id, opts \\ [])

  def put_attribution(%FlowAttributionEvent{} = event, partition_id, opts) do
    agent_id = Keyword.get(opts, :agent_id)

    case canonical_key_from_attribution(event) do
      nil ->
        :ok

      key ->
        emit(@telemetry_attribution, %{count: 1}, %{
          partition_id: partition_id,
          agent_id: agent_id
        })

        GenServer.call(
          __MODULE__,
          {:put_attribution, key, event, partition_id, agent_id, opts}
        )
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  def put_attribution(_other, _partition_id, _opts), do: :ok

  @doc """
  Cache statistics.
  """
  @spec stats() :: map()
  def stats do
    info = :ets.info(@table_name)

    %{
      size: info[:size] || 0,
      memory_bytes: (info[:memory] || 0) * :erlang.system_info(:wordsize),
      table_name: @table_name
    }
  rescue
    ArgumentError ->
      %{size: 0, memory_bytes: 0, table_name: @table_name, error: :table_not_found}
  end

  @doc """
  Clear all cached entries (test helper).
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Server callbacks

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    max_size = Keyword.get(opts, :max_size, @max_size)
    eviction_scan_chunk = Keyword.get(opts, :eviction_scan_chunk, @eviction_scan_chunk)
    self_partition_id = resolve_self_partition_id(opts)
    publisher = Keyword.get(opts, :publisher, {Connection, :publish, []})

    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()

    Logger.info(
      "AttributedFlowJoiner started",
      ttl_ms: ttl_ms,
      max_size: max_size,
      self_partition_id: self_partition_id
    )

    {:ok,
     %{
       ttl_ms: ttl_ms,
       max_size: max_size,
       eviction_scan_chunk: eviction_scan_chunk,
       self_partition_id: self_partition_id,
       publisher: publisher
     }}
  end

  @impl true
  def handle_call({:put_host_slice, key, msg, agent_id, opts}, _from, state) do
    ttl_ms = Keyword.get(opts, :ttl_ms, state.ttl_ms)
    now = System.monotonic_time(:millisecond)
    expires_at = now + ttl_ms

    case :ets.take(@table_name, key) do
      [
        {^key,
         {:attribution, %FlowAttributionEvent{} = pending, partition_id, _agent_id, inserted_at},
         _exp}
      ] ->
        # Attribution arrived first; merge and publish using cert-derived partition.
        published = merge_and_publish(msg, pending, partition_id, agent_id, inserted_at, state)
        {:reply, {:published, published}, state}

      _ ->
        :ets.insert(@table_name, {key, {:host_slice, msg, nil, agent_id, now}, expires_at})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:put_attribution, key, event, partition_id, agent_id, opts}, _from, state) do
    ttl_ms = Keyword.get(opts, :ttl_ms, state.ttl_ms)
    now = System.monotonic_time(:millisecond)
    expires_at = now + ttl_ms

    case :ets.take(@table_name, key) do
      [
        {^key,
         {:host_slice, %AttributedFlowMessage{} = pending_msg, _partition, host_agent_id,
          inserted_at}, _exp}
      ] ->
        published =
          merge_and_publish(pending_msg, event, partition_id, host_agent_id, inserted_at, state)

        {:reply, {:published, published}, state}

      _ ->
        :ets.insert(
          @table_name,
          {key, {:attribution, event, partition_id, agent_id, now}, expires_at}
        )

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    maybe_evict_oversized(state.max_size, state.eviction_scan_chunk)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal helpers

  defp merge_and_publish(
         %AttributedFlowMessage{flow: %FlowMessage{} = flow} = msg,
         %FlowAttributionEvent{} = event,
         _ingest_partition_id,
         agent_id,
         inserted_at,
         state
       ) do
    # **Security boundary:** always publish on the partition this core-elx
    # instance owns. Never use a value sourced from the agent payload.
    partition = state.self_partition_id

    merged = %{
      msg
      | event_type: @attributed_flow_event_type,
        attribution: attribution_from_event(event),
        agent_id: agent_id || msg.agent_id || "",
        partition: partition
    }

    subject = @attributed_flow_subject_prefix <> partition
    payload = AttributedFlowMessage.encode(merged)
    join_latency_ms = max(System.monotonic_time(:millisecond) - inserted_at, 0)

    case publish(state.publisher, subject, payload) do
      :ok ->
        emit(@telemetry_joined, %{count: 1, join_latency_ms: join_latency_ms}, %{
          partition_id: partition,
          agent_id: agent_id,
          proto: flow.proto
        })

        1

      {:error, reason} ->
        Logger.warning(
          "AttributedFlowJoiner publish failed",
          subject: subject,
          reason: inspect(reason)
        )

        emit(@telemetry_publish_failed, %{count: 1}, %{
          partition_id: partition,
          agent_id: agent_id,
          reason: inspect(reason)
        })

        0
    end
  end

  defp attribution_from_event(%FlowAttributionEvent{} = event) do
    %FlowAttribution{
      pid: event.pid,
      comm: event.comm || "",
      redacted_cmdline: cmdline_to_string(event.redacted_cmdline),
      uid: event.uid,
      container_id: event.container_id || ""
    }
  end

  defp cmdline_to_string(nil), do: ""
  defp cmdline_to_string([]), do: ""
  defp cmdline_to_string(list) when is_list(list), do: Enum.join(list, " ")
  defp cmdline_to_string(value) when is_binary(value), do: value
  defp cmdline_to_string(_), do: ""

  defp publish({mod, fun, extra_args}, subject, payload) do
    apply(mod, fun, [subject, payload | extra_args])
  rescue
    e ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    # Pull the kind tag out of the value tuple so the telemetry can split
    # host_slice vs attribution timeouts.
    match_spec = [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [{{:"$1", :"$2"}}]}
    ]

    expired = :ets.select(@table_name, match_spec)

    Enum.each(expired, fn {key, value} ->
      :ets.delete(@table_name, key)

      kind =
        case value do
          {kind, _, _, _, _} -> kind
          _ -> :unknown
        end

      emit(@telemetry_orphan, %{count: 1}, %{kind: kind})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp maybe_evict_oversized(max_size, eviction_scan_chunk) do
    case :ets.info(@table_name, :size) do
      size when is_integer(size) and size > max_size ->
        evict_count = div(size, 10)
        evict_oldest(evict_count, eviction_scan_chunk)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp evict_oldest(count, eviction_scan_chunk) when count > 0 do
    entries = oldest_entries(count, eviction_scan_chunk)

    Enum.each(entries, fn {key, _expires_at} ->
      :ets.delete(@table_name, key)
    end)

    if entries != [] do
      emit(@telemetry_evicted, %{count: length(entries)}, %{})
    end

    :ok
  end

  defp evict_oldest(_count, _chunk), do: :ok

  defp oldest_entries(count, eviction_scan_chunk) do
    match_spec = [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    case :ets.select(@table_name, match_spec, eviction_scan_chunk) do
      :"$end_of_table" ->
        []

      {chunk, continuation} ->
        collect_oldest_entries(continuation, count, Enum.sort_by(chunk, &elem(&1, 1)))
    end
  end

  defp collect_oldest_entries(continuation, count, candidates) do
    case :ets.select(continuation) do
      :"$end_of_table" ->
        Enum.take(candidates, count)

      {chunk, next} ->
        next_candidates =
          candidates
          |> Kernel.++(chunk)
          |> Enum.sort_by(&elem(&1, 1))
          |> Enum.take(count)

        collect_oldest_entries(next, count, next_candidates)
    end
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _ -> :ok
  end

  # ----- Canonical-key construction -------------------------------------------------

  defp canonical_key_from_flow(%FlowMessage{
         proto: proto,
         src_addr: src,
         dst_addr: dst,
         src_port: sport,
         dst_port: dport
       })
       when is_binary(src) and is_binary(dst) and proto != nil do
    canonical_key(proto, src, sport || 0, dst, dport || 0)
  end

  defp canonical_key_from_flow(_), do: nil

  defp canonical_key_from_attribution(%FlowAttributionEvent{
         local_ip: local_ip,
         local_port: local_port,
         remote_ip: remote_ip,
         remote_port: remote_port,
         transport_protocol: transport
       })
       when is_binary(local_ip) and is_binary(remote_ip) do
    with {:ok, local_bin} <- parse_ip(local_ip),
         {:ok, remote_bin} <- parse_ip(remote_ip),
         proto when is_integer(proto) <- transport_to_proto(transport) do
      canonical_key(proto, local_bin, local_port || 0, remote_bin, remote_port || 0)
    else
      _ -> nil
    end
  end

  defp canonical_key_from_attribution(_), do: nil

  defp canonical_key(proto, ip_a, port_a, ip_b, port_b) do
    if {ip_a, port_a} <= {ip_b, port_b} do
      {proto, ip_a, port_a, ip_b, port_b}
    else
      {proto, ip_b, port_b, ip_a, port_a}
    end
  end

  defp parse_ip(str) when is_binary(str) and str != "" do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, {a, b, c, d}} ->
        {:ok, <<a, b, c, d>>}

      {:ok, {a, b, c, d, e, f, g, h}} ->
        {:ok, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_ip(_), do: :error

  # Map well-known transport names to IANA protocol numbers. Matches the
  # values used by the flow-collector when stamping `FlowMessage.proto`.
  defp transport_to_proto(transport) when is_binary(transport) do
    case String.downcase(transport) do
      "tcp" -> 6
      "udp" -> 17
      "icmp" -> 1
      "icmpv6" -> 58
      "sctp" -> 132
      _ -> :error
    end
  end

  defp transport_to_proto(_), do: :error

  defp resolve_self_partition_id(opts) do
    case Keyword.get(opts, :self_partition_id) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        from_env =
          :serviceradar_core
          |> Application.get_env(__MODULE__, [])
          |> Keyword.get(:self_partition_id)

        cond do
          is_binary(from_env) and from_env != "" ->
            from_env

          otx = System.get_env("SERVICERADAR_OTX_PARTITION") ->
            otx

          true ->
            "default"
        end
    end
  end
end
