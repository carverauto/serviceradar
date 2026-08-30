defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]

  def update_command_statuses(socket, event_type, data) do
    socket
    |> update_mapper_command_status(event_type, data)
    |> update_sweep_command_status(event_type, data)
  end

  def update_mapper_command_status(socket, event_type, data) do
    case Map.get(data, :mapper_job_id) do
      nil ->
        socket

      job_id ->
        statuses = update_command_status(socket.assigns.mapper_command_statuses, job_id, event_type, data)

        assign(socket, :mapper_command_statuses, statuses)
    end
  end

  def update_sweep_command_status(socket, event_type, data) do
    case Map.get(data, :sweep_group_id) do
      nil ->
        socket

      _group_id ->
        statuses =
          reduce_sweep_member_event(
            socket.assigns.sweep_command_statuses,
            {event_type, data}
          )

        assign(socket, :sweep_command_statuses, statuses)
    end
  end

  def begin_sweep_dispatch(statuses, group_id) when is_map(statuses) and is_binary(group_id) do
    Map.put(statuses, group_id, empty_sweep_status(false))
  end

  def begin_sweep_dispatch(statuses, _group_id), do: statuses

  def seed_sweep_dispatch(statuses, data) when is_map(statuses) and is_map(data) do
    case event_value(data, :sweep_group_id) do
      group_id when is_binary(group_id) and group_id != "" ->
        existing = Map.get(statuses, group_id, empty_sweep_status(false))
        queued_members = sweep_dispatch_members(data)

        members =
          merge_preseed_members(queued_members, Map.get(existing, :members, %{}))

        status =
          true
          |> empty_sweep_status()
          |> Map.put(:members, members)
          |> Map.put(:failures, sweep_dispatch_failures(data))
          |> Map.put(:dispatch_error, event_value(data, :error))
          |> summarize_sweep_status()

        Map.put(statuses, group_id, status)

      _missing_group_id ->
        statuses
    end
  end

  def seed_sweep_dispatch(statuses, _data), do: statuses

  def reduce_sweep_member_event(statuses, {event_type, data}) when is_map(statuses) and is_map(data) do
    group_id = event_value(data, :sweep_group_id)
    command_id = event_value(data, :command_id)

    if valid_status_key?(group_id) and valid_status_key?(command_id) do
      status = Map.get(statuses, group_id, empty_sweep_status(false))
      members = Map.get(status, :members, %{})

      if Map.get(status, :seeded?, false) and not Map.has_key?(members, command_id) do
        statuses
      else
        existing =
          Map.get(members, command_id, %{
            command_id: command_id,
            agent_id: event_value(data, :agent_id),
            state: :sent,
            message: "Sweep command queued"
          })

        case merge_sweep_member_event(existing, event_type, data) do
          :ignore ->
            statuses

          member ->
            updated =
              status
              |> Map.put(:members, Map.put(members, command_id, member))
              |> summarize_sweep_status()

            Map.put(statuses, group_id, updated)
        end
      end
    else
      statuses
    end
  end

  def reduce_sweep_member_event(statuses, _event), do: statuses

  def update_command_status(statuses, key, event_type, data) do
    existing = Map.get(statuses, key, %{})

    updated =
      existing
      |> Map.merge(%{
        message: Map.get(data, :message),
        updated_at: command_event_timestamp(data)
      })
      |> merge_event_status(event_type, data)

    Map.put(statuses, key, updated)
  end

  def merge_event_status(status, :ack, _data), do: Map.put(status, :state, :ack)

  def merge_event_status(status, :progress, data) do
    status
    |> Map.put(:state, :progress)
    |> Map.put(:progress_percent, Map.get(data, :progress_percent))
  end

  def merge_event_status(status, :result, data) do
    state = if Map.get(data, :success), do: :success, else: :error

    status
    |> Map.put(:state, state)
    |> Map.put(:result_payload, Map.get(data, :payload))
  end

  def command_event_timestamp(data) do
    Map.get(data, :completed_at) ||
      Map.get(data, :updated_at) ||
      Map.get(data, :received_at) ||
      DateTime.utc_now()
  end

  def mark_command_sent(statuses, key, message) do
    Map.put(statuses, key, %{
      state: :sent,
      message: message,
      updated_at: DateTime.utc_now()
    })
  end

  def command_status_label(nil), do: "—"
  def command_status_label(%{seeded?: false}), do: "Dispatching"

  def command_status_label(%{dispatch_error: error, summary: %{total: 0}}) when not is_nil(error), do: "Dispatch failed"

  def command_status_label(%{summary: summary}) when is_map(summary) do
    sweep_summary_label(summary)
  end

  def command_status_label(%{state: :sent}), do: "Queued"
  def command_status_label(%{state: :ack}), do: "Acked"

  def command_status_label(%{state: :progress, progress_percent: percent}) when is_integer(percent) do
    "Running #{percent}%"
  end

  def command_status_label(%{state: :progress}), do: "Running"
  def command_status_label(%{state: :success}), do: "Completed"
  def command_status_label(%{state: :error}), do: "Failed"
  def command_status_label(_), do: "—"

  def command_status_variant(nil), do: "ghost"
  def command_status_variant(%{state: :sent}), do: "info"
  def command_status_variant(%{state: :ack}), do: "info"
  def command_status_variant(%{state: :progress}), do: "warning"
  def command_status_variant(%{state: :partial}), do: "warning"
  def command_status_variant(%{state: :success}), do: "success"
  def command_status_variant(%{state: :error}), do: "error"
  def command_status_variant(_), do: "ghost"

  def format_sweep_failure_reason({:agent_offline, _agent_id}), do: "Agent is offline"
  def format_sweep_failure_reason(:agent_offline), do: "Agent is offline"

  def format_sweep_failure_reason({:agent_partition_ambiguous, _agent_id}), do: "Multiple canonical control sessions"

  def format_sweep_failure_reason({:agent_capability_missing, _agent_id, capability}) do
    "Missing #{capability} capability"
  end

  def format_sweep_failure_reason(reason) when is_binary(reason), do: reason

  def format_sweep_failure_reason(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def format_sweep_failure_reason(_reason), do: "Dispatch failed"

  def mapper_run_status_label(:success), do: "Success"
  def mapper_run_status_label(:error), do: "Error"
  def mapper_run_status_label(_), do: "—"

  def mapper_run_status_variant(:success), do: "success"
  def mapper_run_status_variant(:error), do: "error"
  def mapper_run_status_variant(_), do: "ghost"

  defp empty_sweep_status(seeded?) do
    %{
      seeded?: seeded?,
      members: %{},
      failures: %{},
      summary: empty_sweep_summary(),
      state: :sent,
      dispatch_error: nil
    }
  end

  defp empty_sweep_summary do
    %{queued: 0, running: 0, pending: 0, success: 0, failure: 0, total: 0}
  end

  defp sweep_dispatch_members(data) do
    data
    |> event_value(:commands)
    |> List.wrap()
    |> Enum.reduce(%{}, fn command, members ->
      command_id = event_value(command, :command_id)
      agent_id = event_value(command, :agent_id)

      if valid_status_key?(command_id) and valid_status_key?(agent_id) do
        Map.put(members, command_id, %{
          command_id: command_id,
          agent_id: agent_id,
          state: :sent,
          message: "Sweep command queued"
        })
      else
        members
      end
    end)
  end

  defp sweep_dispatch_failures(data) do
    data
    |> event_value(:failures)
    |> List.wrap()
    |> Enum.reduce(%{}, fn failure, failures ->
      agent_id = event_value(failure, :agent_id)

      if valid_status_key?(agent_id) do
        Map.put(failures, agent_id, %{
          agent_id: agent_id,
          reason: event_value(failure, :reason)
        })
      else
        failures
      end
    end)
  end

  defp merge_preseed_members(queued_members, early_members) do
    Map.new(queued_members, fn {command_id, queued} ->
      early = Map.get(early_members, command_id, %{})

      merged =
        queued
        |> Map.merge(early)
        |> Map.put(:command_id, command_id)
        |> Map.put(:agent_id, queued.agent_id)

      {command_id, merged}
    end)
  end

  defp merge_sweep_member_event(existing, event_type, data) do
    target_state = sweep_event_state(event_type, data)
    existing_state = Map.get(existing, :state, :sent)

    cond do
      is_nil(target_state) ->
        :ignore

      terminal_sweep_state?(existing_state) ->
        :ignore

      sweep_state_rank(target_state) < sweep_state_rank(existing_state) ->
        :ignore

      true ->
        existing
        |> maybe_put_event_value(data, :message)
        |> Map.put(:updated_at, command_event_timestamp(data))
        |> Map.put(:state, target_state)
        |> merge_sweep_event_payload(event_type, data)
    end
  end

  defp sweep_event_state(:ack, _data), do: :ack
  defp sweep_event_state(:progress, _data), do: :progress
  defp sweep_event_state(:result, data), do: if(event_value(data, :success) == true, do: :success, else: :error)
  defp sweep_event_state(_event_type, _data), do: nil

  defp merge_sweep_event_payload(member, :progress, data) do
    incoming = event_value(data, :progress_percent)
    existing = Map.get(member, :progress_percent)

    progress_percent =
      if is_integer(incoming) and is_integer(existing), do: max(incoming, existing), else: incoming

    Map.put(member, :progress_percent, progress_percent)
  end

  defp merge_sweep_event_payload(member, :result, data) do
    member
    |> Map.put(:result_payload, event_value(data, :payload))
    |> maybe_put_event_value(data, :failure_reason)
  end

  defp merge_sweep_event_payload(member, _event_type, _data), do: member

  defp summarize_sweep_status(status) do
    member_counts =
      status
      |> Map.get(:members, %{})
      |> Map.values()
      |> Enum.reduce(%{queued: 0, running: 0, success: 0, failure: 0}, fn member, counts ->
        case Map.get(member, :state) do
          state when state in [:sent, :ack] -> Map.update!(counts, :queued, &(&1 + 1))
          :progress -> Map.update!(counts, :running, &(&1 + 1))
          :success -> Map.update!(counts, :success, &(&1 + 1))
          :error -> Map.update!(counts, :failure, &(&1 + 1))
          _other -> counts
        end
      end)

    immediate_failures = status |> Map.get(:failures, %{}) |> map_size()
    pending = member_counts.queued + member_counts.running

    summary = %{
      queued: member_counts.queued,
      running: member_counts.running,
      pending: pending,
      success: member_counts.success,
      failure: member_counts.failure + immediate_failures,
      total: map_size(Map.get(status, :members, %{})) + immediate_failures
    }

    status
    |> Map.put(:summary, summary)
    |> Map.put(:state, sweep_status_state(status, summary))
  end

  defp sweep_status_state(%{dispatch_error: error}, %{total: 0}) when not is_nil(error), do: :error

  defp sweep_status_state(_status, summary), do: sweep_summary_state(summary)

  defp sweep_summary_state(%{pending: pending, failure: failure}) when pending > 0 and failure > 0, do: :partial

  defp sweep_summary_state(%{running: running}) when running > 0, do: :progress
  defp sweep_summary_state(%{pending: pending}) when pending > 0, do: :sent

  defp sweep_summary_state(%{success: success, failure: failure}) when success > 0 and failure > 0, do: :partial

  defp sweep_summary_state(%{success: success}) when success > 0, do: :success
  defp sweep_summary_state(%{failure: failure}) when failure > 0, do: :error
  defp sweep_summary_state(_summary), do: :sent

  defp sweep_summary_label(%{pending: pending, success: success, failure: failure}) when pending > 0 do
    [count_label(pending, "pending"), optional_count_label(success, "completed"), optional_count_label(failure, "failed")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp sweep_summary_label(%{success: success, failure: failure}) do
    "#{count_label(success, "completed")}, #{count_label(failure, "failed")}"
  end

  defp sweep_summary_label(_summary), do: "—"

  defp count_label(count, label), do: "#{count} #{label}"
  defp optional_count_label(0, _label), do: nil
  defp optional_count_label(count, label), do: count_label(count, label)

  defp terminal_sweep_state?(state), do: state in [:success, :error]
  defp sweep_state_rank(:sent), do: 0
  defp sweep_state_rank(:ack), do: 1
  defp sweep_state_rank(:progress), do: 2
  defp sweep_state_rank(state) when state in [:success, :error], do: 3
  defp sweep_state_rank(_state), do: -1

  defp maybe_put_event_value(map, data, key) do
    if Map.has_key?(data, key) or Map.has_key?(data, Atom.to_string(key)) do
      Map.put(map, key, event_value(data, key))
    else
      map
    end
  end

  defp event_value(data, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp event_value(_data, _key), do: nil

  defp valid_status_key?(value), do: is_binary(value) and value != ""
end
