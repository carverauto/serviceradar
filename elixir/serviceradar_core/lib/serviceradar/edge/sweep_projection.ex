defmodule ServiceRadar.Edge.SweepProjection do
  @moduledoc """
  Projects a scheduled ICMP/TCP sweep into the ordinary sweep and inventory tables.

  EventWriter calls this only for a newly claimed primary event, inside its ledger
  transaction. Authority refusals return `{:error, reason}`; an ingest failure
  raises so the caller rolls back and the delivery is redelivered. The persisted
  slot supplies the expected host count; an individual microbatch never claims
  that the whole execution completed. A lock on the slot
  serializes batches of one execution, including the first batch before its domain
  execution exists. The assignment lock keeps a concurrent fence change from
  authorizing a stale domain write. Signed range digests authorize the persisted
  plan's actual targets and checks, not caller-supplied replacements for them.
  """

  import Ecto.Query

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.SweepMode
  alias Serviceradar.Edge.V1.TransportProtocol
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Policies.NetworkAddressPolicy
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
         {:ok, header} <- authorized_plan(slot, record, batch) do
      results = results(batch)

      opts = [
        sweep_group_id: slot.sweep_group_id,
        agent_id: slot.agent_id,
        authenticated_agent_id: slot.agent_id,
        authenticated_partition_id: partition,
        expected_total_hosts: header.total_target_count,
        is_final: false
      ]

      ingest!(results, execution_id, opts)
      finish_if_complete(repo, execution_id, header, opts)
    else
      nil -> {:error, :sweep_partition_not_found}
      {:error, _} = error -> error
    end
  end

  defp authorized_plan(slot, record, batch) do
    with {:ok, header} <- WireDecode.decode_plan_header(slot.plan_header),
         {:ok, pages} <- decode_pages(slot.plan_pages),
         {:ok, _windows} <- PlanValidate.validate(header, pages),
         :ok <- plan_matches(header, slot, record, batch),
         range when not is_nil(range) <- PlanValidate.find_range(pages, batch.target_range_id),
         :ok <- range_matches(range, batch) do
      {:ok, header}
    else
      nil -> {:error, :sweep_range_not_found}
      {:error, _} = error -> error
    end
  end

  defp decode_pages(bytes) do
    bytes
    |> Enum.reduce_while({:ok, []}, fn bytes, {:ok, pages} ->
      case WireDecode.decode_plan_page(bytes) do
        {:ok, page} -> {:cont, {:ok, [page | pages]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      {:error, _} = error -> error
    end
  end

  defp plan_matches(header, slot, record, batch) do
    checks =
      Enum.map(batch.tested_checks, fn check ->
        {SweepMode.value(check.mode), TransportProtocol.value(check.protocol), check.port}
      end)

    cond do
      header.execution_plan_sha256 != slot.plan_sha256 or
        header.execution_plan_id != batch.execution_plan_id or
        header.network_scope_id != record.network_scope_id or
          header.availability_policy_id != batch.availability_policy_id ->
        {:error, :sweep_plan_mismatch}

      header.check_set_sha256 != slot.check_set_sha256 or
          HashGrammar.check_set_digest(checks) != header.check_set_sha256 ->
        {:error, :sweep_check_set_mismatch}

      true ->
        :ok
    end
  end

  defp range_matches(range, batch) do
    cond do
      range.range_sha256 != batch.target_range_sha256 ->
        {:error, :sweep_range_mismatch}

      not Enum.all?(batch.hosts, fn host ->
        NetworkAddressPolicy.cidr_contains?(address_tuple(host.address), range.cidr)
      end) ->
        {:error, :sweep_target_outside_range}

      true ->
        :ok
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
      ingest!([], execution_id, Keyword.put(opts, :is_final, true))
    end

    :ok
  end

  defp ingest!(results, execution_id, opts) do
    case SweepResultsIngestor.ingest_results(results, execution_id, opts) do
      {:ok, _stats} -> :ok
      {:error, reason} -> raise "sweep result ingest failed: #{inspect(reason)}"
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

  defp address(bytes), do: bytes |> address_tuple() |> :inet.ntoa() |> to_string()

  defp address_tuple(<<a, b, c, d>>), do: {a, b, c, d}

  defp address_tuple(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

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
