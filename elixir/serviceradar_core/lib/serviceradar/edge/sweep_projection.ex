defmodule ServiceRadar.Edge.SweepProjection do
  @moduledoc """
  Projects a scheduled ICMP/TCP sweep into the ordinary sweep and inventory tables.

  EventWriter calls this only for a newly claimed primary event, inside its ledger
  transaction. The persisted slot supplies the expected host count; an individual
  microbatch never claims that the whole execution completed. A lock on the slot
  serializes batches of one execution, including the first batch before its domain
  execution exists. The assignment lock keeps a concurrent fence change from
  authorizing a stale domain write.
  """

  import Ecto.Query

  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepProducerAssignment
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  @doc "Project a correlated scheduled batch in the caller's database transaction."
  def project(repo, record, batch) do
    execution_id = Ecto.UUID.cast!(batch.execution_id)

    with :ok <- terminal_window(batch),
         :ok <- current_assignment(repo, record),
         slot =
           repo.one(
             from(s in SweepExecutionSlot, where: s.id == ^execution_id, lock: "FOR UPDATE")
           ),
         :ok <- slot_matches(slot, record, batch),
         %Partition{slug: partition} <- repo.get(Partition, slot.network_scope_id),
         {:ok, header} <- ServiceRadar.Edge.WireDecode.decode_plan_header(slot.plan_header) do
      results = results(batch)

      opts = [
        sweep_group_id: slot.sweep_group_id,
        agent_id: slot.agent_id,
        authenticated_agent_id: slot.agent_id,
        authenticated_partition_id: partition,
        expected_total_hosts: header.total_target_count,
        is_final: false
      ]

      with {:ok, _stats} <- SweepResultsIngestor.ingest_results(results, execution_id, opts) do
        finish_if_complete(repo, execution_id, header, opts)
      end
    else
      nil -> {:error, :sweep_partition_not_found}
      {:error, _} = error -> error
    end
  end

  defp slot_matches(nil, _record, _batch), do: {:error, :sweep_slot_not_found}

  defp slot_matches(slot, record, batch) do
    context = record.producer_context

    if slot.state == :scheduled and
         Ecto.UUID.dump!(slot.sweep_group_id) == batch.sweep_group_id and
         slot.agent_id == context.origin_principal_id and
         Ecto.UUID.dump!(slot.network_scope_id) == record.network_scope_id and
         Ecto.UUID.dump!(slot.producer_assignment_id) == context.producer_assignment_id and
         Ecto.UUID.dump!(slot.lease_id) == context.run_id and
         Ecto.UUID.dump!(slot.plan_id) == batch.execution_plan_id and
         slot.plan_sha256 == batch.execution_plan_sha256 and
         slot.authority_epoch == batch.assignment_epoch do
      :ok
    else
      {:error, :sweep_slot_mismatch}
    end
  end

  defp current_assignment(repo, record) do
    context = record.producer_context
    assignment_id = Ecto.UUID.cast!(context.producer_assignment_id)

    assignment =
      repo.one(
        from(a in SweepProducerAssignment,
          where: a.id == ^assignment_id,
          lock: "FOR SHARE"
        )
      )

    case assignment do
      %{state: :active, authority_epoch: epoch, run_shard: shard}
      when epoch == context.authority_epoch and shard == context.run_shard ->
        :ok

      _ ->
        {:error, :sweep_assignment_fenced}
    end
  end

  defp finish_if_complete(repo, execution_id, %ScheduledPlanHeaderV1{} = header, opts) do
    {count, available} =
      repo.one(
        from(h in SweepHostResult,
          where: h.execution_id == ^execution_id,
          select: {count(h.id), filter(count(h.id), h.status == :available)}
        )
      )

    # A terminal window can be republished with a new event id. Domain host rows
    # upsert by execution/IP, so progress must count those rows, not publications.
    repo.update_all(from(e in SweepGroupExecution, where: e.id == ^execution_id),
      set: [hosts_available: available, hosts_failed: count - available]
    )

    if count == header.total_target_count and
         repo.get!(SweepGroupExecution, execution_id).status != :completed do
      case SweepResultsIngestor.ingest_results(
             [],
             execution_id,
             Keyword.put(opts, :is_final, true)
           ) do
        {:ok, _stats} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  # The first scheduled producer publishes complete ICMP/TCP windows. Reject
  # partial-mode/MTR windows instead of presenting them as completed hosts.
  defp terminal_window(batch) do
    if batch.availability_policy_id == "any-success-v1" and
         batch.configured_mode_bits in 1..7 and
         Enum.all?(batch.hosts, &(&1.result_mode_bits == batch.configured_mode_bits)) do
      :ok
    else
      {:error, :unsupported_sweep_host_window}
    end
  end

  defp results(batch) do
    checks = List.to_tuple(batch.tested_checks)

    ports =
      for check <- batch.tested_checks, check.protocol == :TRANSPORT_PROTOCOL_TCP, do: check.port

    Enum.map(batch.hosts, fn host ->
      open_ports = Enum.map(host.open_ports, &elem(checks, &1.tested_check_index).port)

      %{
        "host_ip" => address(host.address),
        "hostname" => host.hostname,
        "available" => icmp_available?(host.icmp) or open_ports != [],
        "icmp_status" => icmp_status(host.icmp),
        "icmp_response_time_ns" => icmp_response_time(host.icmp),
        "tcp_ports_open" => open_ports,
        "port_results" => Enum.map(ports, &%{"port" => &1, "available" => &1 in open_ports}),
        "sweep_modes" => modes(host),
        "last_sweep_time" =>
          DateTime.to_iso8601(
            DateTime.from_unix!(
              batch.observed_at_unix_nano + host.observed_at_delta_nano,
              :nanosecond
            )
          )
      }
    end)
  end

  defp address(<<a, b, c, d>>), do: to_string(:inet.ntoa({a, b, c, d}))

  defp address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: to_string(:inet.ntoa({a, b, c, d, e, f, g, h}))

  defp icmp_available?(nil), do: false
  defp icmp_available?(icmp), do: icmp.target_reached
  defp icmp_status(nil), do: nil

  defp icmp_status(icmp), do: %{"available" => icmp.target_reached}

  defp icmp_response_time(%{round_trip_micro: value}) when is_integer(value), do: value * 1_000
  defp icmp_response_time(_icmp), do: nil

  defp modes(host) do
    if(host.icmp, do: ["icmp"], else: []) ++ if host.tcp, do: ["tcp"], else: []
  end
end
