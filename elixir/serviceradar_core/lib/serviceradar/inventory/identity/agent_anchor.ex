defmodule ServiceRadar.Inventory.Identity.AgentAnchor do
  @moduledoc """
  Behavioral anchor for the agent -> device link (DIRE).

  An agent's link to its host device must be anchored on the agent's OWN
  stable identity, never on an IP or hostname (ServiceRadar runs in
  unknown/overlapping networks where IPs and pod hostnames collide and
  churn). The authoritative, network-agnostic anchor is the *reciprocal*
  `agent_id`:

    * `ocsf_devices.agent_id == agent.uid` — the device's denormalized
      "agent reporting this device" ownership, and
    * a `device_identifiers` row `{type: :agent_id, value: agent.uid}` on
      a live device.

  Both are declared by/derived from the agent's stable uid, which survives
  k8s pod renames and IP churn. This module exposes two pure-ish queries
  used by the merge-time guard (prevent-at-source) and the periodic repair
  worker (remediate existing cruft):

    * `anchored_device_uids/2` — the live devices this agent reciprocally
      owns (its true hosts), and
    * `conflicts_with_anchor?/3` — whether moving the agent onto
      `candidate_device_uid` would contradict that anchor, i.e. the
      candidate is reciprocally owned by a DIFFERENT agent while this agent
      has its own distinct anchor device.

  The conflict test delegates the strong-identity comparison to
  `AliasGuard.distinct_agent_identity_conflict?/3` (the #3577 behavioral
  guard) so there is a single source of truth for "two devices carry
  disjoint agent identity" rather than a parallel re-implementation.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard

  require Ash.Query
  require Logger

  @doc """
  Live device uids this agent reciprocally owns (its behavioral host
  anchor), drawn from both the device `agent_id` attribute and `agent_id`
  identifier rows. Tombstoned devices are excluded — a stale anchor is not
  an anchor.

  Returns a (possibly empty) list of unique uids. An empty list means the
  agent has no strong anchor and callers MUST treat any move as ambiguous
  (leave + log), never as a confident repoint.
  """
  @spec anchored_device_uids(String.t(), term()) :: [String.t()]
  def anchored_device_uids(agent_uid, actor) when is_binary(agent_uid) and agent_uid != "" do
    from_identifiers =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^agent_uid)
      |> read_uids(actor, & &1.device_id)

    from_attribute =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false})
      |> Ash.Query.filter(agent_id == ^agent_uid)
      |> read_uids(actor, & &1.uid)

    (from_identifiers ++ from_attribute)
    |> Enum.uniq()
    |> Enum.filter(&live_device?(&1, actor))
  rescue
    e ->
      Logger.warning("AgentAnchor: failed to load anchor for #{agent_uid}: #{inspect(e)}")
      []
  end

  def anchored_device_uids(_agent_uid, _actor), do: []

  @doc """
  Whether moving `agent_uid` onto `candidate_device_uid` would contradict
  the agent's stable anchor.

  True only when BOTH hold (do-no-harm: ambiguity is never a conflict):

    1. the agent already has a live anchor device that is NOT the
       candidate (it reciprocally owns a different host), AND
    2. that anchor device and the candidate carry distinct strong agent
       identity (the candidate is reciprocally owned by a different agent),
       per `AliasGuard.distinct_agent_identity_conflict?/3`.

  When the agent has no anchor, or the candidate IS the anchor, or the two
  devices do not carry disjoint agent identity, this returns `false` and
  the move is allowed — the guard only refuses a move that demonstrably
  steals the agent away from its own reciprocally-owned host onto another
  agent's host.
  """
  @spec conflicts_with_anchor?(String.t(), String.t(), term()) :: boolean()
  def conflicts_with_anchor?(agent_uid, candidate_device_uid, actor)
      when is_binary(agent_uid) and is_binary(candidate_device_uid) do
    anchors = anchored_device_uids(agent_uid, actor)

    other_anchors = Enum.reject(anchors, &(&1 == candidate_device_uid))

    other_anchors != [] and
      Enum.any?(other_anchors, fn anchor_uid ->
        AliasGuard.distinct_agent_identity_conflict?(anchor_uid, candidate_device_uid, actor)
      end)
  rescue
    e ->
      Logger.warning(
        "AgentAnchor: conflict check failed for #{agent_uid} -> " <>
          "#{candidate_device_uid}: #{inspect(e)}"
      )

      false
  end

  def conflicts_with_anchor?(_agent_uid, _candidate, _actor), do: false

  @doc """
  The single, unambiguous live anchor device uid for an agent, or `nil`.

  Returns a uid only when the agent has exactly one live reciprocally-owned
  device (an unambiguous behavioral host). Zero anchors or multiple distinct
  anchors both return `nil` so callers default to "leave + log".
  """
  @spec sole_anchor_device_uid(String.t(), term()) :: String.t() | nil
  def sole_anchor_device_uid(agent_uid, actor) do
    case anchored_device_uids(agent_uid, actor) do
      [uid] -> uid
      _ -> nil
    end
  end

  defp read_uids(query, actor, mapper) do
    query_opts = if actor, do: [actor: actor], else: []

    case Ash.read(query, query_opts) do
      {:ok, result} ->
        result
        |> unwrap_rows()
        |> Enum.map(mapper)
        |> Enum.reject(&(is_nil(&1) or &1 == ""))

      _ ->
        []
    end
  end

  # Device's primary read paginates by default; unwrap any page wrapper.
  defp unwrap_rows(%Ash.Page.Keyset{results: results}), do: results
  defp unwrap_rows(%Ash.Page.Offset{results: results}), do: results
  defp unwrap_rows(list) when is_list(list), do: list

  defp live_device?(device_uid, actor) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{}} -> true
      _ -> false
    end
  end
end
