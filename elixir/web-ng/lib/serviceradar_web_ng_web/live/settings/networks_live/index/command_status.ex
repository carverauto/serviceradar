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

      group_id ->
        statuses = update_command_status(socket.assigns.sweep_command_statuses, group_id, event_type, data)

        assign(socket, :sweep_command_statuses, statuses)
    end
  end

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
  def command_status_variant(%{state: :success}), do: "success"
  def command_status_variant(%{state: :error}), do: "error"
  def command_status_variant(_), do: "ghost"

  def mapper_run_status_label(:success), do: "Success"
  def mapper_run_status_label(:error), do: "Error"
  def mapper_run_status_label(_), do: "—"

  def mapper_run_status_variant(:success), do: "success"
  def mapper_run_status_variant(:error), do: "error"
  def mapper_run_status_variant(_), do: "ghost"
end
