defmodule ServiceRadar.Edge.Projectors.UnleasedSweepResults do
  @moduledoc """
  Projects `serviceradar.sweep.unleased_results` v1 records: results of sweep groups an agent runs
  from its own config without a sweep lease (target-query groups and other unleased groups),
  emitted under a standing output grant.

  The legacy status path sends the same results as the agent's sweep-results JSON, which
  `ServiceRadar.Ingestion.ResultIngestor.ingest_sweep_payload/2` ingests into the sweep, host
  result and inventory tables. This projector rebuilds that payload from the typed batch and
  ingests through the same function, inside the EdgeRecord ledger transaction and only for a
  primary delivery, so a replay changes nothing and both paths write the same rows. The chunk's
  metric batch travels separately, as a `serviceradar.metrics.batch` record.

  Before ingesting it re-checks the record's standing grant (`OutputGrants.check_current/5`); a
  grant that is not current refuses the record. The agent id is the authenticated record
  principal and the partition is the record's network scope, never values from the body.

  What the typed batch does not carry, and the rebuilt payload therefore omits: a host's
  response time when it has no ICMP summary, and the response time of a tested port that was
  not open. A closed tested port travels as a `port_errors` entry with error code `closed`.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.UnleasedSweepResultsBatchV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Ingestion.ResultIngestor

  require Logger

  @closed_port "closed"

  @scanner_keys ~w(protocol address_family scanner_path packets_sent packets_recv packets_dropped
                   ring_blocks_processed ring_blocks_dropped retries_attempted retries_successful
                   retries_dropped ports_allocated ports_released port_exhaustion_count
                   rate_limit_deferrals rate_limit_waits source_port_waits rate_limit_wait_time_ms
                   source_port_wait_time_ms rx_drop_rate_percent dials_started dials_succeeded
                   dial_timeouts dial_resets dial_resource_errors active_dials max_active_dials
                   queue_depth max_queue_depth)a

  @banner_keys ~w(candidates_total probes_total inflight queue_depth match_batches_total
                  match_batch_bytes_total bytes_received_total skipped_fresh_total
                  skipped_backoff_total matches_total empty_response_total connection_reset_total
                  timeout_total errors_total)a

  @doc """
  Decodes and validates the batch of an unleased sweep results record: no source authorization,
  a 16-byte execution id, and one projected row per host.
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
           check(length(batch.hosts) == record.projected_row_count, :unleased_sweep_row_count) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :unleased_sweep_source_authorization}

  @doc """
  Ingests a primary delivery's results through the legacy sweep-results ingest. A replay or
  late-fenced delivery writes nothing. A grant that is not current, or a network scope with no
  partition, rolls the record back as refused. An ingest that declines the results commits as
  the legacy path does: logged, with whatever the ingest recorded kept.
  """
  @impl true
  def project(repo, %EdgeRecordV1{} = record, %UnleasedSweepResultsBatchV1{} = batch, %{
        primary?: true
      }) do
    context = record.producer_context
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             context.origin_principal_id,
             record.output_contract.contract_id,
             network_scope_id,
             context.authority_epoch
           ),
         %Partition{slug: partition} <- repo.get(Partition, network_scope_id) do
      status = %{
        agent_id: context.origin_principal_id,
        authenticated_partition: partition,
        chunk_index: batch.chunk_index,
        total_chunks: batch.total_chunks,
        is_final: batch.is_final
      }

      case ResultIngestor.ingest_sweep_payload(payload(batch), status) do
        :ok ->
          :ok

        {:error, :no_hosts} ->
          :ok

        {:error, reason} ->
          # The legacy path logs and drops the same outcomes (a missing or unresolved group, a
          # quarantined reporter). Committing keeps what the ingest wrote for them, such as the
          # quarantined availability, and makes a redelivery a replay.
          Logger.warning("Unleased sweep results not ingested: #{inspect(reason)}")
          :ok
      end
    else
      nil -> {:error, :sweep_partition_not_found}
      {:error, _reason} = error -> error
    end
  end

  def project(_repo, _record, _batch, _context), do: :ok

  @doc false
  # The agent's sweep-results JSON shape (`SweepService.GetSweepResults`), rebuilt from the batch.
  @spec payload(UnleasedSweepResultsBatchV1.t()) :: map()
  def payload(%UnleasedSweepResultsBatchV1{} = batch) do
    ports = for check <- batch.tested_checks, do: check.port

    %{
      "execution_id" => Ecto.UUID.load!(batch.execution_id),
      "network" => batch.network_cidr,
      "total_hosts" => batch.expected_total_hosts,
      "available_hosts" => batch.available_hosts,
      "last_sweep" => div(batch.last_sweep_unix_nano, 1_000_000_000),
      "ports" => Enum.map(batch.port_counts, &%{"port" => &1.port, "available" => &1.available}),
      "hosts" => Enum.map(batch.hosts, &host(&1, List.to_tuple(ports)))
    }
    |> put_present("sweep_group_id", uuid(batch.sweep_group_id))
    |> put_present("cancelled", if(batch.is_cancelled, do: true))
    |> put_present("scanner_stats", scanner_stats(batch.scanner_stats))
    |> put_present("banner_grab", banner_grab(batch.banner_grab_summary))
  end

  defp host(host, ports) do
    open =
      Enum.map(host.open_ports, fn port ->
        %{
          "port" => elem(ports, port.tested_check_index),
          "available" => true,
          "response_time" => port.response_time_nano || 0
        }
      end)

    closed =
      for error <- host.port_errors, error.error_code == @closed_port do
        %{
          "port" => elem(ports, error.tested_check_index),
          "available" => false,
          "response_time" => 0
        }
      end

    put_present(
      %{
        "host" => address(host.address),
        "available" => reached?(host.icmp) or open != [] or reached?(host.mtr),
        "port_results" => open ++ closed
      },
      "icmp_status",
      icmp_status(host.icmp)
    )
  end

  defp reached?(nil), do: false
  defp reached?(summary), do: summary.target_reached

  defp icmp_status(nil), do: nil

  defp icmp_status(icmp) do
    %{
      "available" => icmp.target_reached,
      "round_trip" => (icmp.round_trip_micro || 0) * 1_000,
      "packet_loss" => icmp.packet_loss_pct || 0.0
    }
  end

  defp scanner_stats(nil), do: nil

  defp scanner_stats(stats),
    do: Map.new(@scanner_keys, &{Atom.to_string(&1), Map.fetch!(stats, &1)})

  defp banner_grab(nil), do: nil

  defp banner_grab(summary),
    do: Map.new(@banner_keys, &{"sweep_banner_grab_#{&1}", Map.fetch!(summary, &1)})

  defp address(bytes) when byte_size(bytes) in [4, 16] do
    bytes |> address_tuple() |> :inet.ntoa() |> to_string()
  end

  defp address(_bytes), do: nil

  defp address_tuple(<<a, b, c, d>>), do: {a, b, c, d}

  defp address_tuple(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

  defp uuid(<<_::128>> = bytes), do: Ecto.UUID.load!(bytes)
  defp uuid(_bytes), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
