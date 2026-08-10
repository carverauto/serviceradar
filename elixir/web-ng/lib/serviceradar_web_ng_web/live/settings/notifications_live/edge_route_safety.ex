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

  ## The per-channel advisory

  `evaluate/2` answers a question about a *policy*. `channel_advisory/2` answers
  the same question one channel at a time, so the two cannot drift: whether this
  channel has a control-plane escape hatch when its site is unreachable. It is
  what the channel editor renders next to `fallback_channel_id` and
  `fail_closed` at the moment an operator sets them, and what the channel list
  renders on the saved row afterwards. Setting `fail_closed` on a site-agent
  channel is a decision to lose pages, and a decision that consequential has to
  be legible while it is being made, not discovered from a delivery log.
  """

  @remediation "Add a control-plane channel to a step, or set fallback_channel_id on an edge channel to a control-plane channel."
  @channel_remediation "Set a control-plane failover channel, or move this channel to the control-plane route."

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
    |> Enum.map(&site_label/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

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

  # --- per-channel advisory ---------------------------------------------------

  @type advisory :: %{
          level: :error | :warning | :ok,
          badge: String.t(),
          headline: String.t(),
          message: String.t(),
          remediation: String.t() | nil
        }

  @doc """
  Whether one `:edge_agent` channel has a control-plane escape hatch.

  Returns `nil` for a `:control_plane` channel, because the condition only
  exists when egress depends on a site agent core cannot reach.

  Accepts either a loaded channel (atom keys) or the editor's string-keyed
  params, so the saved row and the unsaved form report the same thing. A form
  has no `partition_id` yet - it is bound server side from the agent's mTLS
  session - so `agent_uid` stands in as the site label until it does.

  Levels are ordered by what an operator loses:

  * `:error` - the page is lost outright when the site is unreachable, either
    because `fail_closed` disabled failover or because the configured failover
    egresses from the same site.
  * `:warning` - failover exists but cannot be shown to help: no fallback is
    set, the fallback is not readable, or the fallback is another site's agent.
  * `:ok` - the fallback egresses from the control plane, which is the
    documented remediation.
  """
  @spec channel_advisory(term(), term()) :: advisory() | nil
  def channel_advisory(channel, channels) when is_map(channel) and is_map(channels) do
    normalized = normalize(channel)

    if edge?(normalized) do
      advise(normalized, fallback_channel(normalized, channels))
    end
  end

  def channel_advisory(_channel, _channels), do: nil

  defp fallback_channel(%{fallback_channel_id: nil}, _channels), do: :none

  defp fallback_channel(%{fallback_channel_id: id}, channels) do
    case Map.get(channels, id) do
      nil -> :unknown
      channel -> normalize(channel)
    end
  end

  defp advise(%{fail_closed: true} = channel, _fallback) do
    %{
      level: :error,
      badge: "Fail closed: page is lost",
      headline: "Fail closed on a site-agent channel loses the page",
      message:
        "Agent commands are at-most-once with no store-and-forward, so while #{site(channel)} is " <>
          "unreachable this channel cannot deliver and fail_closed forbids failing over. The page " <>
          "is dropped, including the site-down page core raises about this very site.",
      remediation: @channel_remediation
    }
  end

  defp advise(channel, :none) do
    %{
      level: :warning,
      badge: "No failover",
      headline: "No failover channel for a site-agent channel",
      message:
        "This channel egresses from #{site(channel)}. With no fallback_channel_id there is " <>
          "nowhere to fail over to when that agent is offline, and core is the component that " <>
          "detects it went dark.",
      remediation: @channel_remediation
    }
  end

  defp advise(channel, :unknown) do
    %{
      level: :warning,
      badge: "Failover unverified",
      headline: "The failover channel cannot be read",
      message:
        "This channel egresses from #{site(channel)} and names a failover channel that is not " <>
          "readable here, so whether it restores a control-plane path cannot be verified.",
      remediation: @channel_remediation
    }
  end

  defp advise(channel, fallback) do
    cond do
      not edge?(fallback) ->
        %{
          level: :ok,
          badge: "Control-plane failover",
          headline: "Failover reaches the control plane",
          message:
            "When #{site(channel)} is unreachable this channel fails over one hop to a " <>
              "control-plane channel, which egresses from the platform.",
          remediation: nil
        }

      same_site?(channel, fallback) ->
        %{
          level: :error,
          badge: "Failover in the same site",
          headline: "The failover egresses from the same site",
          message:
            "Both this channel and its failover egress from #{site(channel)}. Whatever makes " <>
              "this channel undeliverable makes the failover undeliverable at the same instant, " <>
              "so the one hop buys nothing.",
          remediation: @channel_remediation
        }

      true ->
        %{
          level: :warning,
          badge: "Failover is another site",
          headline: "The failover is another site agent",
          message:
            "This channel egresses from #{site(channel)} and fails over to an agent at " <>
              "#{site(fallback)}. That survives a single-site outage but not a control-plane " <>
              "reachability problem affecting both.",
          remediation: @channel_remediation
        }
    end
  end

  defp same_site?(channel, fallback) do
    label = site_label(channel)
    label != nil and label == site_label(fallback)
  end

  defp site(channel) do
    case site_label(channel) do
      nil -> "this site"
      label -> label
    end
  end

  defp site_label(%{partition_id: partition}) when is_binary(partition) and partition != "" do
    partition
  end

  defp site_label(%{agent_uid: agent}) when is_binary(agent) and agent != "", do: agent
  defp site_label(_channel), do: nil

  # Accepts a loaded channel or the editor's string-keyed params without ever
  # calling String.to_atom/1 on a key the caller controls.
  defp normalize(map) do
    %{
      id: string_or_nil(fetch(map, :id)),
      execution_route: fetch(map, :execution_route),
      fail_closed: truthy?(fetch(map, :fail_closed)),
      fallback_channel_id: string_or_nil(fetch(map, :fallback_channel_id)),
      partition_id: string_or_nil(fetch(map, :partition_id)),
      agent_uid: string_or_nil(fetch(map, :agent_uid))
    }
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value), do: to_string(value)

  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]

  @doc "The per-channel remediation sentence, shared by the editor and the list."
  @spec channel_remediation() :: String.t()
  def channel_remediation, do: @channel_remediation
end
