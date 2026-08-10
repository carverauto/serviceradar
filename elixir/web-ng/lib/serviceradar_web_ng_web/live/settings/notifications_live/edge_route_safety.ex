defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafety do
  @moduledoc """
  The edge-only escalation warning (design D3, mitigation 2).

  `ServiceRadar.Edge.AgentCommandBus` is at-most-once with no store-and-forward:
  a command to a disconnected agent is marked `offline` and nothing re-drains it
  on reconnect. Core is also the component that *detects* that a site went dark.
  So an escalation policy whose only reachable channels egress from a site agent
  cannot deliver the single most important page there is - *this site is down* -
  precisely when it is owed.

  This module computes that condition from configuration alone so the UI can say
  it before an incident proves it. It is deliberately pure: it takes the policy's
  steps with their channel sets plus a channel index, and returns a warning or
  `nil`. Nothing here queries, and nothing here blocks a save - an operator may
  knowingly ship an edge-only ladder, and the requirement is that they are told,
  on the policy row and on every route bound to it, not only inside the editor.

  ## Reachability includes exactly one failover hop

  `fallback_channel_id` is transport failover: one hop, taken when retries are
  exhausted or the agent is offline. A `:control_plane` fallback is one of the
  two documented remediations, so it must clear the warning - which means the
  reachable set is the step channels **plus one hop** through their fallbacks.
  Following the chain further would be wrong: the engine takes one hop, so a
  second-level `:control_plane` channel is not actually reachable.

  `fail_closed` opts a channel out of failover entirely. A `fail_closed`
  `:edge_agent` channel therefore has no reachable fallback at all, and the
  warning says so explicitly rather than leaving an operator to infer that the
  fallback they configured is inert.
  """

  @remediation "Add a control-plane channel to a step, or set fallback_channel_id on an edge channel to a control-plane channel."

  @type warning :: %{
          kind: :edge_only,
          message: String.t(),
          remediation: String.t(),
          partitions: [String.t()],
          fail_closed?: boolean()
        }

  @doc """
  Warns when every channel an escalation policy can reach egresses from a site
  agent.

  `channel_sets` is a list of the channel-id lists of the policy's steps (one
  entry per step, in step order); `channels` is a map of channel id to the
  channel record. A channel id with no entry in the index is ignored rather than
  treated as control-plane: an unknown channel is not evidence of a safe route.
  """
  @spec evaluate(term(), term()) :: warning() | nil
  def evaluate(channel_sets, channels) when is_list(channel_sets) and is_map(channels) do
    reachable = reachable_channels(channel_sets, channels)

    cond do
      reachable == [] -> nil
      Enum.all?(reachable, &edge?/1) -> warning(reachable)
      true -> nil
    end
  end

  def evaluate(_channel_sets, _channels), do: nil

  @doc "Whether `evaluate/2` would warn, for a list badge."
  @spec warns?(term(), term()) :: boolean()
  def warns?(channel_sets, channels), do: evaluate(channel_sets, channels) != nil

  @doc """
  The channels a policy can reach: every step's channels plus one failover hop.

  Exposed so the editor can show the reachable set it is warning about instead of
  asserting a conclusion the operator cannot check.
  """
  @spec reachable_channels(term(), term()) :: [map()]
  def reachable_channels(channel_sets, channels) when is_list(channel_sets) and is_map(channels) do
    direct =
      channel_sets
      |> List.flatten()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.flat_map(&lookup(channels, &1))

    fallbacks = Enum.flat_map(direct, &fallback(&1, channels))

    Enum.uniq_by(direct ++ fallbacks, & &1.id)
  end

  def reachable_channels(_channel_sets, _channels), do: []

  defp lookup(channels, id) do
    case Map.get(channels, id) do
      nil -> []
      channel -> [channel]
    end
  end

  # A fail_closed channel never fails over, so its fallback is not reachable.
  defp fallback(%{fail_closed: true}, _channels), do: []

  defp fallback(%{fallback_channel_id: id}, channels) when not is_nil(id) do
    lookup(channels, to_string(id))
  end

  defp fallback(_channel, _channels), do: []

  defp edge?(%{execution_route: :edge_agent}), do: true
  defp edge?(%{execution_route: "edge_agent"}), do: true
  defp edge?(_channel), do: false

  defp warning(reachable) do
    partitions = partitions(reachable)
    fail_closed? = Enum.any?(reachable, & &1.fail_closed)

    %{
      kind: :edge_only,
      message: message(partitions, fail_closed?),
      remediation: @remediation,
      partitions: partitions,
      fail_closed?: fail_closed?
    }
  end

  defp partitions(reachable) do
    reachable
    |> Enum.map(&partition_label/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp partition_label(%{partition_id: partition}) when is_binary(partition) and partition != "" do
    partition
  end

  defp partition_label(%{agent_uid: agent}) when is_binary(agent) and agent != "", do: agent
  defp partition_label(_channel), do: nil

  defp message(partitions, fail_closed?) do
    scope =
      case partitions do
        [] -> "a site"
        list -> Enum.join(list, ", ")
      end

    base =
      "Every channel this policy can reach egresses from a site agent (#{scope}). " <>
        "Agent commands are at-most-once with no store-and-forward, and core is what " <>
        "detects that a site went dark, so this policy cannot deliver a site-down page " <>
        "for #{scope}."

    if fail_closed? do
      base <>
        " Failover is disabled by fail_closed on at least one of those channels, so the " <>
        "page is lost outright while the agent is offline."
    else
      base
    end
  end

  @doc "The remediation sentence, so the list badge and the editor cannot drift."
  @spec remediation() :: String.t()
  def remediation, do: @remediation
end
