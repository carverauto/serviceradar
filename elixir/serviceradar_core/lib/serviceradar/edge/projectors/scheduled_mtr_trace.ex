defmodule ServiceRadar.Edge.Projectors.ScheduledMtrTrace do
  @moduledoc """
  Projects `serviceradar.mtr.scheduled_trace` v1 records: full hop-by-hop MTR traces
  emitted by agent-scheduled checks under a standing output grant.

  On a fresh primary delivery, `publish/3` runs before the ledger transaction and does
  the work that leaves the database: the StarRocks Stream Load when that backend is
  enabled, and the `MtrGraph` projection either way. `project/4` then runs inside the
  transaction. It re-checks the standing output grant, writes the CNPG trace and hop
  rows when StarRocks is not the backend, and updates `ServiceStateRegistry`.

  On a replay or late-fenced delivery, `publish/3` is not called and `project/4` is a
  no-op.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceBatchV1
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrHopReplyDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrMplsLabelV1
  alias Serviceradar.Edge.V1.MtrTcpHandshakeDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrTraceEventV1
  alias Serviceradar.Edge.V1.MtrTraceHopV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.EventWriter.Processors.Mtr, as: MtrProcessor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatusPubSub
  alias ServiceRadar.Repo

  @service_name "mtr_traces"
  @service_type "mtr"
  @max_traces 1_000
  @write_bytes_per_row 2_048

  @valid_probe_modes [
    :MTR_TCP_PROBE_MODE_V1_UNSPECIFIED,
    :MTR_TCP_PROBE_MODE_V1_SYN,
    :MTR_TCP_PROBE_MODE_V1_CONNECT
  ]

  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %AgentScheduledMtrTraceBatchV1{} = batch} <-
           WireDecode.decode_scheduled_mtr_batch(body),
         :ok <-
           check(
             batch.traces != [] and length(batch.traces) <= @max_traces,
             :scheduled_mtr_trace_count
           ),
         :ok <-
           check(
             length(batch.traces) == record.projected_row_count,
             :scheduled_mtr_row_count
           ),
         :ok <-
           check(
             record.projected_write_bytes == record.projected_row_count * @write_bytes_per_row,
             :scheduled_mtr_write_bytes
           ),
         :ok <- validate_traces(batch.traces) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :scheduled_mtr_source_authorization}

  @impl true
  def publish(%EdgeRecordV1{} = record, %AgentScheduledMtrTraceBatchV1{} = batch, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case prepare(repo, record, batch, opts) do
      {:ok, payload, status} ->
        MtrProcessor.persist_outside_ledger([%{payload: payload, status: status, broadcast: nil}])

      {:error, {:refused, reason}} ->
        {:refused, {:refused, reason}}

      {:error, reason} when reason in [:output_grant_not_current, :mtr_partition_not_found] ->
        {:refused, reason}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def project(
        repo,
        %EdgeRecordV1{} = record,
        %AgentScheduledMtrTraceBatchV1{} = batch,
        %{primary?: true} = context
      ) do
    with {:ok, payload, status} <- prepare(repo, record, batch, gateway_id: context.gateway_id),
         :ok <-
           MtrProcessor.persist_ledger_rows([%{payload: payload, status: status, broadcast: nil}]),
         :ok <- ServiceStateRegistry.upsert_from_status_strict(status) do
      NotificationQueue.after_commit(fn -> ServiceStatusPubSub.broadcast_update(status) end)
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def project(_repo, _record, _batch, _context), do: :ok

  defp prepare(repo, %EdgeRecordV1{} = record, batch, opts) do
    producer = record.producer_context
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)
    agent_id = producer.origin_principal_id

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(producer.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             network_scope_id,
             producer.authority_epoch
           ),
         %Partition{slug: partition} <- repo.get(Partition, network_scope_id),
         {:ok, gateway_id} <- mtr_gateway(repo, agent_id, Keyword.get(opts, :gateway_id)) do
      payload = to_ingestor_payload(batch)
      {:ok, payload, status(batch, payload, agent_id, gateway_id, partition)}
    else
      nil -> {:error, :mtr_partition_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Converts an `AgentScheduledMtrTraceBatchV1` into the `%{"results" => [...]}` map
  consumed by `MtrMetricsIngestor` and `MtrGraph`.
  """
  @spec to_ingestor_payload(AgentScheduledMtrTraceBatchV1.t()) :: map()
  def to_ingestor_payload(%AgentScheduledMtrTraceBatchV1{traces: traces}) do
    %{"results" => Enum.map(traces, &to_ingestor_result/1)}
  end

  @doc """
  Converts a single `AgentScheduledMtrTraceV1` entry into the result map shape
  expected by `MtrMetricsIngestor`.
  """
  @spec to_ingestor_result(AgentScheduledMtrTraceV1.t()) :: map()
  def to_ingestor_result(%AgentScheduledMtrTraceV1{} = entry) do
    %MtrTraceEventV1{} = tr = entry.trace
    target_ip = address(tr.resolved_address) || tr.target
    diag_by_hop = Map.new(entry.hop_diagnostics, &{&1.hop_number, &1})

    trace_map =
      %{
        "target" => tr.target,
        "target_ip" => target_ip,
        "target_reached" => tr.target_reached,
        "total_hops" => tr.total_hops,
        "probed_hops" => entry.probed_hops,
        "last_responding_hop" => entry.last_responding_hop,
        "protocol" => protocol_name(tr.protocol),
        "ip_version" => tr.ip_version,
        "timestamp" => tr.observed_at_unix_nano,
        "hops" => Enum.map(tr.hops, &hop_map(&1, diag_by_hop))
      }
      |> maybe_put("packet_size", if(tr.packet_size > 0, do: tr.packet_size))
      |> maybe_put("tcp_port", if(entry.tcp_port > 0, do: entry.tcp_port))
      |> maybe_put("tcp_probe_mode", tcp_probe_mode_name(entry.tcp_probe_mode))
      |> maybe_put("tcp_handshake", tcp_handshake_map(entry.tcp_handshake))

    %{
      "trace_uuid" => Ecto.UUID.load!(tr.trace_id),
      "check_id" => entry.check_id,
      "check_name" => entry.check_name,
      "target" => tr.target,
      "device_id" => non_empty(entry.device_id),
      "available" => tr.target_reached,
      "trace" => trace_map,
      "timestamp" => tr.observed_at_unix_nano,
      "error" => non_empty(entry.error_message) || non_empty(tr.error_code)
    }
  end

  defp hop_map(%MtrTraceHopV1{} = hop, diag_by_hop) do
    diag = Map.get(diag_by_hop, hop.hop_number)

    ecmp_addrs =
      hop.ecmp_addresses
      |> Enum.map(&address/1)
      |> Enum.reject(&is_nil/1)

    mpls_labels =
      case hop.mpls_labels do
        [] ->
          nil

        labels ->
          Enum.map(labels, fn %MtrMplsLabelV1{} = lbl ->
            %{
              "label" => lbl.label,
              "exp" => lbl.experimental,
              "s" => lbl.bottom_of_stack,
              "ttl" => lbl.ttl
            }
          end)
      end

    merge_hop_diagnostics(
      %{
        "hop_number" => hop.hop_number,
        "addr" => address(hop.address),
        "hostname" => non_empty(hop.hostname),
        "ecmp_addrs" => ecmp_addrs,
        "asn" => asn_map(hop.asn, hop.asn_org),
        "mpls_labels" => mpls_labels,
        "sent" => hop.sent,
        "received" => hop.received,
        "loss_pct" => hop.loss_pct,
        "last_us" => hop.last_micro,
        "avg_us" => hop.avg_micro,
        "min_us" => hop.min_micro,
        "max_us" => hop.max_micro,
        "stddev_us" => hop.stddev_micro,
        "jitter_us" => hop.jitter_micro,
        "jitter_worst_us" => hop.jitter_worst_micro,
        "jitter_interarrival_us" => hop.jitter_interarrival_micro
      },
      diag
    )
  end

  defp merge_hop_diagnostics(map, nil), do: map

  defp merge_hop_diagnostics(map, %MtrHopReplyDiagnosticsV1{} = diag) do
    map
    |> maybe_put("unreachable_code", if(diag.has_unreachable_code, do: diag.unreachable_code))
    |> maybe_put_positive("reply_time_exceeded", diag.reply_time_exceeded)
    |> maybe_put_positive("reply_unreachable", diag.reply_unreachable)
    |> maybe_put_positive("reply_synack", diag.reply_synack)
    |> maybe_put_positive("reply_rst", diag.reply_rst)
  end

  defp tcp_handshake_map(nil), do: nil

  defp tcp_handshake_map(%MtrTcpHandshakeDiagnosticsV1{} = hs) do
    %{
      "ttl" => hs.ttl,
      "attempts" => hs.attempts,
      "syn_sent" => hs.syn_sent,
      "synack_received" => hs.synack_received,
      "rst_received" => hs.rst_received,
      "unanswered" => hs.unanswered,
      "syn_drop_pct" => hs.syn_drop_pct,
      "syn_retransmits" => hs.syn_retransmits,
      "answered_after_retx" => hs.answered_after_retx,
      "ack_mismatch" => hs.ack_mismatch,
      "synack_duplicates" => hs.synack_duplicates
    }
    |> maybe_put_positive("rtt_min_us", hs.rtt_min_us)
    |> maybe_put_positive("rtt_avg_us", hs.rtt_avg_us)
    |> maybe_put_positive("rtt_max_us", hs.rtt_max_us)
    |> maybe_put("server_response_us", if(hs.has_server_response_us, do: hs.server_response_us))
  end

  defp asn_map(0, org) when org in [nil, ""], do: nil

  defp asn_map(asn, org) do
    %{}
    |> maybe_put("asn", if(is_integer(asn) and asn > 0, do: asn))
    |> maybe_put("org", non_empty(org))
  end

  defp status(
         %AgentScheduledMtrTraceBatchV1{traces: traces},
         payload,
         agent_id,
         gateway_id,
         partition
       ) do
    latest_nano =
      traces
      |> Enum.map(& &1.trace.observed_at_unix_nano)
      |> Enum.max()

    %{
      service_name: @service_name,
      service_type: @service_type,
      available: true,
      message: Jason.encode!(payload),
      response_time: 0,
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      authenticated_partition: partition,
      source: "results",
      kv_store_id: "",
      timestamp: System.os_time(:second),
      agent_timestamp: div(latest_nano, 1_000_000_000),
      chunk_index: 0,
      total_chunks: 1,
      is_final: true
    }
  end

  defp mtr_gateway(_repo, _agent_id, header) when is_binary(header) and header != "",
    do: {:ok, header}

  defp mtr_gateway(repo, agent_id, _header) do
    case repo.get(Agent, agent_id) do
      %Agent{gateway_id: gateway_id} when is_binary(gateway_id) and gateway_id != "" ->
        {:ok, gateway_id}

      _ ->
        {:error, {:refused, :gateway_unknown}}
    end
  end

  defp validate_traces(traces) do
    Enum.reduce_while(traces, :ok, fn entry, :ok ->
      case validate_trace_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_trace_entry(%AgentScheduledMtrTraceV1{trace: %MtrTraceEventV1{} = tr} = entry) do
    with :ok <-
           check(
             byte_size(tr.trace_id) == 16 and byte_size(tr.event_id) == 16,
             :scheduled_mtr_trace_identity
           ),
         :ok <- check(byte_size(entry.sweep_group_id) in [0, 16], :scheduled_mtr_sweep_group_id),
         :ok <- check(byte_size(entry.execution_id) in [0, 16], :scheduled_mtr_execution_id),
         :ok <- check(entry.tcp_port <= 65_535, :scheduled_mtr_tcp_port),
         :ok <- check(entry.tcp_probe_mode in @valid_probe_modes, :scheduled_mtr_tcp_probe_mode),
         :ok <-
           check(
             is_binary(tr.target) and String.trim(tr.target) != "",
             :scheduled_mtr_target
           ),
         :ok <- check(tr.observed_at_unix_nano > 0, :scheduled_mtr_timestamp),
         :ok <- check(tr.ip_version in [4, 6], :scheduled_mtr_ip_version),
         :ok <-
           check(
             byte_size(tr.resolved_address) in [0, 4, 16],
             :scheduled_mtr_resolved_address
           ),
         :ok <-
           check(
             byte_size(tr.sweep_host_address) in [0, 4, 16],
             :scheduled_mtr_sweep_host_address
           ),
         :ok <-
           check(
             not tr.target_reached or (tr.attempted and tr.total_hops > 0),
             :scheduled_mtr_target_reached
           ) do
      validate_hops(tr.hops, tr.total_hops, 0)
    end
  end

  defp validate_trace_entry(_entry), do: {:error, :scheduled_mtr_trace_missing}

  defp validate_hops([], total_hops, max_hop) do
    check(max_hop <= total_hops, :scheduled_mtr_total_hops)
  end

  defp validate_hops([%MtrTraceHopV1{} = hop | rest], total_hops, prev_hop) do
    with :ok <- check(hop.hop_number > prev_hop, :scheduled_mtr_hop_order),
         :ok <- check(byte_size(hop.address) in [0, 4, 16], :scheduled_mtr_hop_address),
         :ok <-
           check(
             Enum.all?(hop.ecmp_addresses, &(byte_size(&1) in [4, 16])),
             :scheduled_mtr_hop_ecmp
           ),
         :ok <- check(hop.received <= hop.sent, :scheduled_mtr_hop_counts),
         :ok <- check(hop.loss_pct >= 0.0 and hop.loss_pct <= 100.0, :scheduled_mtr_hop_loss) do
      validate_hops(rest, total_hops, hop.hop_number)
    end
  end

  defp protocol_name(:TRANSPORT_PROTOCOL_TCP), do: "tcp"
  defp protocol_name(:TRANSPORT_PROTOCOL_UDP), do: "udp"
  defp protocol_name(_), do: "icmp"

  defp tcp_probe_mode_name(:MTR_TCP_PROBE_MODE_V1_SYN), do: "syn"
  defp tcp_probe_mode_name(:MTR_TCP_PROBE_MODE_V1_CONNECT), do: "connect"
  defp tcp_probe_mode_name(_), do: nil

  defp address(<<a, b, c, d>>), do: {a, b, c, d} |> :inet.ntoa() |> to_string()

  defp address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()

  defp address(_), do: nil

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_positive(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp maybe_put_positive(map, _key, _value), do: map

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
