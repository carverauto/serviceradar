defmodule ServiceRadar.Edge.Projectors.UnleasedSweepResults do
  @moduledoc """
  Projects `serviceradar.sweep.unleased_results` v1 records: results of sweep groups an agent runs
  from its own config without a sweep lease (target-query groups and other unleased groups),
  emitted under a standing output grant.

  The legacy status path sends the same results as the agent's results JSON in a `results` status,
  which `ServiceRadar.Ingestion.ResultIngestor.process_and_publish/2` ingests into the sweep, host
  result and inventory tables and then records in the service state registry. This projector
  rebuilds that JSON from the typed batch, byte for byte as the agent encodes it, rebuilds the
  status the gateway would have delivered, and hands it to the same function. It does so inside
  the EdgeRecord ledger transaction and only for a primary delivery, so a replay changes nothing
  and both paths write the same rows. The chunk's metric batch travels separately, as a
  `serviceradar.metrics.batch` record.

  Before ingesting it re-checks the record's standing grant (`OutputGrants.check_current/5`); a
  grant that is not current refuses the record. The agent id is the authenticated record
  principal and the partition is the record's network scope. The gateway id is the publishing
  gateway's `Sr-Edge-Gateway-Id` header, or the agent's gateway when that header is absent.
  Neither is taken from the body. A record with neither is refused.

  Each host's fields beyond its frozen observation travel in `host_results`: the agent's own
  availability verdict, its response and round-trip times in nanoseconds, every port result in
  the agent's order, its seen times and its sweep modes. A batch that is its response's only
  record is encoded in the agent's struct field order, as a single-chunk response is; a batch
  split from a larger response is encoded with sorted keys, as each legacy chunk is.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Ingestion.ResultIngestor

  @service_name "network_sweep"
  @service_type "sweep"

  @scanner_labels ~w(protocol address_family scanner_path)a

  @scanner_counters ~w(packets_sent packets_recv packets_dropped ring_blocks_processed
                       ring_blocks_dropped retries_attempted retries_successful retries_dropped
                       ports_allocated ports_released port_exhaustion_count rate_limit_deferrals
                       rate_limit_waits source_port_waits rate_limit_wait_time_ms
                       source_port_wait_time_ms rx_drop_rate_percent dials_started dials_succeeded
                       dial_timeouts dial_resets dial_resource_errors active_dials max_active_dials
                       queue_depth max_queue_depth)a

  @banner_keys ~w(candidates_total probes_total inflight queue_depth match_batches_total
                  match_batch_bytes_total bytes_received_total skipped_fresh_total
                  skipped_backoff_total matches_total empty_response_total connection_reset_total
                  timeout_total errors_total)a

  @doc """
  Decodes and validates the batch of an unleased sweep results record: no source authorization,
  a 16-byte execution id, one host result per host, and one projected row per host.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %UnleasedSweepResultsBatchV1{} = batch} <-
           WireDecode.decode_unleased_sweep_batch(body),
         :ok <- check(byte_size(batch.execution_id) == 16, :unleased_sweep_execution_id),
         :ok <-
           check(length(batch.host_results) == length(batch.hosts), :unleased_sweep_host_results),
         :ok <-
           check(length(batch.hosts) == record.projected_row_count, :unleased_sweep_row_count) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :unleased_sweep_source_authorization}

  @doc """
  Ingests a primary delivery's results through the legacy results path. A replay or late-fenced
  delivery writes nothing. A grant that is not current, a network scope with no partition, or a
  record with no gateway id rolls the record back as refused. Results the legacy path declines
  commit as they do there: logged, with whatever the ingest recorded kept.
  """
  @impl true
  def project(repo, %EdgeRecordV1{} = record, %UnleasedSweepResultsBatchV1{} = batch, %{
        primary?: true
      } = context) do
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
         {:ok, gateway_id} <- sweep_gateway(repo, agent_id, context.gateway_id) do
      batch
      |> status(agent_id, gateway_id, partition)
      |> ResultIngestor.process_and_publish()
      |> case do
        :ok -> :ok
        {:ok, _result} -> :ok
        # process_and_publish/2 has logged it, as on the legacy path.
        {:error, _reason} -> :ok
      end
    else
      nil -> {:error, :sweep_partition_not_found}
      {:error, _reason} = error -> error
    end
  end

  def project(_repo, _record, _batch, _context), do: :ok

  # The `results` status the gateway builds from the agent's results chunk.
  defp status(batch, agent_id, gateway_id, partition) do
    %{
      service_name: @service_name,
      service_type: @service_type,
      available: true,
      message: legacy_json(batch),
      response_time: 0,
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      authenticated_partition: partition,
      source: "results",
      kv_store_id: "",
      timestamp: System.os_time(:second),
      agent_timestamp: div(batch.batch_completed_at_unix_nano, 1_000_000_000),
      chunk_index: batch.chunk_index,
      total_chunks: batch.total_chunks,
      is_final: batch.is_final
    }
  end

  defp sweep_gateway(_repo, _agent_id, header) when is_binary(header) and header != "",
    do: {:ok, header}

  defp sweep_gateway(repo, agent_id, _header) do
    case repo.get(Agent, agent_id) do
      %Agent{gateway_id: gateway_id} when is_binary(gateway_id) and gateway_id != "" ->
        {:ok, gateway_id}

      _ ->
        {:error, {:refused, :gateway_unknown}}
    end
  end

  @doc """
  The agent's results JSON for the batch: the bytes the legacy results status carries.
  """
  @spec legacy_json(UnleasedSweepResultsBatchV1.t()) :: String.t()
  def legacy_json(%UnleasedSweepResultsBatchV1{} = batch) do
    order = if batch.total_chunks <= 1, do: :struct, else: :sorted

    hosts =
      batch.hosts
      |> Enum.zip(batch.host_results)
      |> Enum.map(fn {host, result} -> host(host, result, order) end)

    [
      {"available_hosts", batch.available_hosts},
      {"execution_id", Ecto.UUID.load!(batch.execution_id)},
      {"hosts", hosts},
      {"last_sweep", div(batch.last_sweep_unix_nano, 1_000_000_000)},
      {"network", batch.network_cidr},
      # A response with no port counts carries `null`, as the agent's nil slice encodes.
      {"ports", port_counts(batch.port_counts, order)},
      {"sweep_group_id", uuid(batch.sweep_group_id)},
      {"total_hosts", batch.expected_total_hosts}
    ]
    |> Kernel.++(omit_nil("banner_grab", banner_grab(batch.banner_grab_summary, order)))
    |> Kernel.++(if(batch.is_cancelled, do: [{"cancelled", true}], else: []))
    |> Kernel.++(omit_nil("scanner_stats", scanner_stats(batch.scanner_stats, order)))
    |> object(:sorted)
    |> Jason.encode!()
  end

  defp host(host, result, order) do
    object(
      [
        {"host", address(host.address)},
        {"available", result.available},
        {"first_seen", result.first_seen},
        {"last_seen", result.last_seen}
      ] ++
        omit_empty("port_results", Enum.map(result.port_results, &port_result(&1, order))) ++
        omit_nil("icmp_status", icmp_status(host.icmp, result, order)) ++
        omit_nil("mtr_status", mtr_status(host.mtr, result, order)) ++
        [{"response_time", result.response_time_nano}] ++
        omit_empty("sweep_modes", result.sweep_modes),
      order
    )
  end

  defp port_result(port, order) do
    object(
      [
        {"port", port.port},
        {"available", port.available},
        {"response_time", port.response_time_nano}
      ] ++ omit_empty_string("service", port.service),
      order
    )
  end

  defp icmp_status(nil, _result, _order), do: nil

  defp icmp_status(icmp, result, order) do
    object(
      [
        {"available", icmp.target_reached},
        {"round_trip", result.icmp_round_trip_nano},
        {"packet_loss", go_float(icmp.packet_loss_pct || 0.0)}
      ],
      order
    )
  end

  defp mtr_status(nil, _result, _order), do: nil

  defp mtr_status(mtr, result, order) do
    object(
      [
        {"reached", mtr.target_reached},
        {"round_trip", result.mtr_round_trip_nano},
        {"packet_loss", go_float(mtr.packet_loss_pct || 0.0)},
        {"total_hops", mtr.total_hops}
      ],
      order
    )
  end

  defp port_counts([], _order), do: nil

  defp port_counts(counts, order) do
    Enum.map(counts, &object([{"port", &1.port}, {"available", &1.available}], order))
  end

  defp scanner_stats(nil, _order), do: nil

  defp scanner_stats(stats, order) do
    labels =
      Enum.flat_map(
        @scanner_labels,
        &omit_empty_string(Atom.to_string(&1), Map.fetch!(stats, &1))
      )

    counters =
      Enum.map(@scanner_counters, fn key ->
        {Atom.to_string(key), stats |> Map.fetch!(key) |> go_number()}
      end)

    object(labels ++ counters, order)
  end

  defp banner_grab(nil, _order), do: nil

  defp banner_grab(summary, order) do
    @banner_keys
    |> Enum.map(&{"sweep_banner_grab_#{&1}", Map.fetch!(summary, &1)})
    |> object(order)
  end

  # Go encodes a JSON object from a struct in field order and from a map with sorted keys.
  defp object(pairs, :struct), do: Jason.OrderedObject.new(pairs)

  defp object(pairs, :sorted),
    do: pairs |> Enum.sort_by(&elem(&1, 0)) |> Jason.OrderedObject.new()

  defp omit_nil(_key, nil), do: []
  defp omit_nil(key, value), do: [{key, value}]

  defp omit_empty(_key, []), do: []
  defp omit_empty(key, value), do: [{key, value}]

  defp omit_empty_string(_key, ""), do: []
  defp omit_empty_string(key, value), do: [{key, value}]

  defp go_number(value) when is_float(value), do: go_float(value)
  defp go_number(value), do: value

  # Go writes an integral float64 without a fraction, which decodes as an integer.
  defp go_float(value) when is_float(value) and value == trunc(value) and abs(value) < 1.0e21,
    do: trunc(value)

  defp go_float(value), do: value

  defp address(bytes) when byte_size(bytes) in [4, 16] do
    bytes |> address_tuple() |> :inet.ntoa() |> to_string()
  end

  defp address(_bytes), do: nil

  defp address_tuple(<<a, b, c, d>>), do: {a, b, c, d}

  defp address_tuple(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

  defp uuid(<<_::128>> = bytes), do: Ecto.UUID.load!(bytes)
  defp uuid(_bytes), do: ""

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
