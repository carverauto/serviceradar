defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting do
  @moduledoc false

  def format_error({:agent_offline, agent_id}), do: "Agent #{agent_id} is offline"

  def format_error({:agent_partition_mismatch, agent_id, partition}),
    do: "Agent #{agent_id} is not in partition #{partition}"

  def format_error({:agent_capability_missing, agent_id, capability}),
    do: "Agent #{agent_id} does not support #{capability}"

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(reason), do: inspect(reason)
  def format_ports([]), do: "—"
  def format_ports(ports) when length(ports) <= 5, do: Enum.join(ports, ", ")
  def format_ports(ports), do: "#{length(ports)} ports"
end
