defmodule ServiceRadar.Edge.Projectors.FlowAttribution do
  @moduledoc """
  Projects `serviceradar.netprobe.flow_attribution` v1 records onto the flow attribution
  observations JetStream subject (`flows.attribution.observations`).

  The legacy status path sends an agent's `FlowAttributionEventBatch` inside a
  `flow-attribution` status to `ServiceRadar.StatusHandler`, which publishes the batch's
  observations via `ServiceRadar.FlowAttribution.publish_observations/4` and emits
  `[:serviceradar, :event_writer, :attributed_flow, :batch_received]`. This projector
  decodes the same `FlowAttributionEventBatch` from an authenticated `EdgeRecordV1`,
  resolves the partition row from `record.network_scope_id` (refusing the record when no
  partition row exists, never substituting `"default"` or raw scope bytes), takes
  `agent_id` from `record.producer_context.origin_principal_id`, and publishes the
  observations with `event_id: record.event_id` before the EdgeRecord ledger transaction.

  Each observation split carries a deterministic `Nats-Msg-Id` derived from
  `record.event_id` and the split index (`<canonical_uuid>:<split_index>`), so a retry
  before ledger commit deduplicates within the JetStream window without dropping later
  splits. `[:serviceradar, :event_writer, :attributed_flow, :batch_received]` is emitted
  in `committed/3` only after the primary EdgeRecord ledger transaction commits.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Actors.SystemActor
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.FlowAttribution, as: FlowAttributionService
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.StatusHandler

  @max_events_per_batch 4_096
  @write_bytes_per_row 983_029

  @doc """
  Decodes and validates the `FlowAttributionEventBatch` of a flow attribution edge record:
  no source authorization, `EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1`, 1..4,096 events,
  `projected_row_count == length(events)`, `projected_write_bytes == projected_row_count * 983_029`,
  and a valid batch window (`batch_start_unix_nano <= batch_end_unix_nano` when both are non-zero).
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %FlowAttributionEventBatch{} = batch} <-
           WireDecode.decode_flow_attribution_batch(body),
         :ok <- check(batch.events != [], :flow_attribution_batch_empty),
         :ok <-
           check(
             length(batch.events) <= @max_events_per_batch,
             :flow_attribution_batch_too_many_events
           ),
         :ok <-
           check(
             length(batch.events) == record.projected_row_count,
             :flow_attribution_row_count
           ),
         :ok <-
           check(
             record.projected_write_bytes == record.projected_row_count * @write_bytes_per_row,
             :flow_attribution_write_bytes
           ),
         :ok <- check(valid_batch_window?(batch), :flow_attribution_batch_window) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :flow_attribution_source_authorization}

  @doc """
  Publishes the batch's observations for a fresh primary delivery before the ledger transaction.
  Re-checks the standing output grant (`OutputGrants.check_current/5`) and resolves the
  partition slug from `record.network_scope_id` via `Partition.get_by_id/2`. A grant that is
  not current or a missing partition refuses the record; a publish failure returns `{:error, reason}`
  so the EventWriter batch fails and JetStream redelivers.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %FlowAttributionEventBatch{} = batch, opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             network_scope_id,
             context.authority_epoch
           ),
         {:ok, %Partition{slug: partition_slug}} <- fetch_partition(network_scope_id) do
      case publish_observations(
             batch.events || [],
             partition_slug,
             agent_id,
             record.event_id,
             opts
           ) do
        :ok -> :ok
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
        other -> {:error, {:unexpected_flow_attribution_publish_result, other}}
      end
    else
      {:error, reason}
      when reason in [:output_grant_not_current, :flow_attribution_partition_not_found] ->
        {:refused, reason}
    end
  end

  @doc """
  Verifies inside the EdgeRecord ledger transaction that a primary delivery's standing grant
  and partition row remain valid.
  """
  @impl true
  def project(repo, %EdgeRecordV1{} = record, %FlowAttributionEventBatch{}, %{primary?: true}) do
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
         %Partition{} <- repo.get(Partition, network_scope_id) do
      :ok
    else
      nil -> {:error, :flow_attribution_partition_not_found}
      {:error, _reason} = error -> error
    end
  end

  def project(_repo, _record, _batch, _context), do: :ok

  @doc """
  Emits `[:serviceradar, :event_writer, :attributed_flow, :batch_received]` after the
  primary EdgeRecord ledger transaction commits.
  """
  @impl true
  def committed(%EdgeRecordV1{} = record, %FlowAttributionEventBatch{} = batch, %{primary?: true}) do
    network_scope_id = Ecto.UUID.load!(record.network_scope_id)
    agent_id = record.producer_context.origin_principal_id

    case fetch_partition(network_scope_id) do
      {:ok, %Partition{slug: partition_slug}} ->
        StatusHandler.emit_flow_attribution_committed(%{
          event_count: length(batch.events || []),
          dropped_since_last: batch.dropped_since_last || 0,
          partition_id: partition_slug,
          agent_id: agent_id
        })

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def committed(_record, _batch, _context), do: :ok

  defp publish_observations(events, partition_slug, agent_id, event_id, opts) do
    publish_opts = build_publish_opts(event_id, opts)

    case flow_attribution_publisher(opts) do
      {FlowAttributionService, :publish_observations, []} ->
        FlowAttributionService.publish_observations(
          events,
          partition_slug,
          agent_id,
          publish_opts
        )

      {FlowAttributionService, :publish_observations, [extra_opts]} when is_list(extra_opts) ->
        FlowAttributionService.publish_observations(
          events,
          partition_slug,
          agent_id,
          Keyword.merge(extra_opts, publish_opts)
        )

      {FlowAttributionService, :publish_observations, extra_opts} when is_list(extra_opts) ->
        FlowAttributionService.publish_observations(
          events,
          partition_slug,
          agent_id,
          Keyword.merge(extra_opts, publish_opts)
        )

      {mod, fun, [extra_opts]} when is_list(extra_opts) ->
        if Keyword.keyword?(extra_opts) do
          apply(mod, fun, [
            events,
            partition_slug,
            agent_id,
            Keyword.merge(extra_opts, publish_opts)
          ])
        else
          apply(mod, fun, [events, partition_slug, agent_id, extra_opts])
        end

      {mod, fun, []} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 4) do
          apply(mod, fun, [events, partition_slug, agent_id, publish_opts])
        else
          apply(mod, fun, [events, partition_slug, agent_id])
        end

      {mod, fun, extra_args} ->
        apply(mod, fun, [events, partition_slug, agent_id | extra_args])

      fun when is_function(fun, 4) ->
        fun.(events, partition_slug, agent_id, publish_opts)

      fun when is_function(fun, 3) ->
        fun.(events, partition_slug, agent_id)
    end
  end

  defp build_publish_opts(event_id, opts) do
    case Keyword.fetch(opts, :request) do
      {:ok, request} ->
        [
          event_id: event_id,
          publish: fn subject, body, msg_id ->
            msg_opts =
              if is_binary(msg_id) and msg_id != "",
                do: [msg_id: msg_id, request: request],
                else: [request: request]

            JetStreamPublish.publish(subject, body, msg_opts)
          end
        ]

      :error ->
        [event_id: event_id]
    end
  end

  defp flow_attribution_publisher(opts) do
    case Keyword.fetch(opts, :flow_attribution_publisher) do
      {:ok, publisher} when not is_nil(publisher) ->
        publisher

      _ ->
        :serviceradar_core
        |> Application.get_env(StatusHandler, [])
        |> Keyword.get(
          :flow_attribution_publisher,
          {FlowAttributionService, :publish_observations, []}
        )
    end
  end

  defp fetch_partition(network_scope_id) do
    case Partition.get_by_id(network_scope_id, actor: actor()) do
      {:ok, %Partition{} = partition} ->
        {:ok, partition}

      {:ok, nil} ->
        {:error, :flow_attribution_partition_not_found}

      {:error, error} ->
        if partition_not_found?(error) do
          {:error, :flow_attribution_partition_not_found}
        else
          raise error
        end
    end
  end

  defp partition_not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp partition_not_found?(%Ash.Error.Invalid{}), do: true

  defp partition_not_found?(%{errors: errors}) when is_list(errors) do
    errors != [] and Enum.all?(errors, &partition_not_found?/1)
  end

  defp partition_not_found?(_error), do: false

  defp valid_batch_window?(%FlowAttributionEventBatch{
         batch_start_unix_nano: start_ns,
         batch_end_unix_nano: end_ns
       }) do
    start_ns = start_ns || 0
    end_ns = end_ns || 0

    start_ns >= 0 and end_ns >= 0 and (start_ns == 0 or end_ns == 0 or start_ns <= end_ns)
  end

  defp actor, do: SystemActor.system(:flow_attribution_projector)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
