defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting do
  @moduledoc false

  @mapper_run_message_limit 240
  @mapper_run_fallback_message "Unable to queue the discovery job. Verify that an online mapper-capable agent is available in the selected partition, then try again."
  @no_online_mapper_message "No online mapper-capable agent is available for this discovery job. Connect one in the selected partition or assign an online mapper agent, then try again."
  @assigned_mapper_offline_message "The assigned mapper agent is offline. Reconnect it or assign an online mapper agent, then try again."

  def format_error({:agent_offline, agent_id}), do: "Agent #{agent_id} is offline"

  def format_error({:agent_partition_mismatch, agent_id, partition}),
    do: "Agent #{agent_id} is not in partition #{partition}"

  def format_error({:agent_capability_missing, agent_id, capability}),
    do: "Agent #{agent_id} does not support #{capability}"

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(reason), do: inspect(reason)

  def format_mapper_run_error(:agent_offline), do: @no_online_mapper_message

  def format_mapper_run_error({:agent_offline, _agent_id}), do: @assigned_mapper_offline_message

  def format_mapper_run_error(reason) do
    case invalid_changes_message(reason) do
      nil -> @mapper_run_fallback_message
      message -> bounded_mapper_run_message(message)
    end
  end

  def format_ports([]), do: "—"
  def format_ports(ports) when length(ports) <= 5, do: Enum.join(ports, ", ")
  def format_ports(ports), do: "#{length(ports)} ports"

  defp invalid_changes_message(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &invalid_changes_message/1)
  end

  defp invalid_changes_message(%Ash.Error.Unknown{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &invalid_changes_message/1)
  end

  defp invalid_changes_message(%Ash.Error.Changes.InvalidChanges{message: message}) when is_binary(message), do: message

  defp invalid_changes_message(_reason), do: nil

  defp bounded_mapper_run_message(message) do
    case String.trim(message) do
      "" ->
        @mapper_run_fallback_message

      message ->
        if String.length(message) > @mapper_run_message_limit do
          String.slice(message, 0, @mapper_run_message_limit - 1) <> "…"
        else
          message
        end
    end
  end
end
