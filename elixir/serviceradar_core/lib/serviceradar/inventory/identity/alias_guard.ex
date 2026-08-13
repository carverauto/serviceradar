defmodule ServiceRadar.Inventory.Identity.AliasGuard do
  @moduledoc """
  Strong-identity guards for IP-alias driven merges.

  A confirmed IP alias may corroborate identity but must never override
  it: two devices bound to different agents are never merged on alias
  evidence, and the conflicting alias is invalidated (marked stale).
  """

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  def maybe_merge_ip_alias_device(device_id, ids, actor) do
    ip = Ids.ids_get_string(ids, :ip)
    partition = Ids.ids_get_partition(ids)

    with true <- Ids.present_id?(ip),
         {:ok, alias_device_id} when is_binary(alias_device_id) and alias_device_id != "" <-
           Resolver.lookup_alias_device_id(ip, partition, actor),
         true <- alias_device_id != device_id,
         false <- Ids.service_device_id?(alias_device_id) do
      if distinct_strong_identity_conflict?(alias_device_id, device_id, actor) do
        # A bare IP must never merge two devices that carry distinct strong
        # identity. Different agents — or different MACs, the network-agnostic
        # tell that a recycling IP (a churned pod address, a reused DHCP lease)
        # has rebound to other hardware — mean these are different hosts.
        # Invalidate the alias so the recycled IP stops feeding merge attempts.
        invalidate_ip_alias(ip, partition, alias_device_id, device_id, actor)
      else
        _ =
          MergeEngine.merge_devices(alias_device_id, device_id,
            actor: actor,
            reason: "ip_alias_conflict",
            details: %{
              source: "identity_reconciler",
              alias_ip: ip
            }
          )
      end
    end

    :ok
  end

  @doc """
  Whether two devices hold distinct STRONG identity — different agents, or
  different MACs. A shared bare IP must never merge across such a conflict.

  Distinct MACs are the network-agnostic signal that a recycling IP (a churned
  pod address, a reused DHCP lease) has rebound to different hardware — no IP
  range list or per-deployment config required.
  """
  @spec distinct_strong_identity_conflict?(String.t(), String.t(), term()) :: boolean()
  def distinct_strong_identity_conflict?(device_a, device_b, actor) do
    distinct_agent_identity_conflict?(device_a, device_b, actor) or
      distinct_mac_conflict?(device_a, device_b, actor)
  end

  @doc """
  Whether two devices hold registered MAC identities that are entirely
  disjoint — the network-agnostic signal that they are different hardware.
  False when either side has no registered MAC (unknown is not distinct).
  """
  @spec distinct_mac_conflict?(String.t(), String.t(), term()) :: boolean()
  def distinct_mac_conflict?(device_a, device_b, actor) do
    macs_a = device_macs(device_a, actor)
    macs_b = device_macs(device_b, actor)

    macs_a != [] and macs_b != [] and
      MapSet.disjoint?(MapSet.new(macs_a), MapSet.new(macs_b)) and
      not Mac.any_hardware_mac_siblings?(macs_a, macs_b)
  end

  defp device_macs(device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.filter(device_id == ^device_id and identifier_type == :mac)
    |> Ash.read(query_opts)
    |> case do
      {:ok, identifiers} -> identifiers |> Enum.map(& &1.identifier_value) |> Enum.uniq()
      _ -> []
    end
  rescue
    e ->
      Logger.warning("Failed to load MAC identities for #{device_id}: #{inspect(e)}")
      []
  end

  @doc """
  Check whether two devices hold distinct agent identities.

  True when both devices are bound to agents (via `agent_id` identifier rows
  or the device's `agent_id` attribute) and those agent sets are disjoint.
  Such devices must never be merged by weak or medium evidence.
  """
  @spec distinct_agent_identity_conflict?(String.t(), String.t(), term()) :: boolean()
  def distinct_agent_identity_conflict?(device_a, device_b, actor) do
    agents_a = device_agent_identities(device_a, actor)
    agents_b = device_agent_identities(device_b, actor)

    agents_a != [] and agents_b != [] and
      MapSet.disjoint?(MapSet.new(agents_a), MapSet.new(agents_b))
  end

  defp device_agent_identities(device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    identifier_agents =
      DeviceIdentifier
      |> Ash.Query.filter(device_id == ^device_id and identifier_type == :agent_id)
      |> Ash.read(query_opts)
      |> case do
        {:ok, identifiers} -> Enum.map(identifiers, & &1.identifier_value)
        _ -> []
      end

    attribute_agent =
      case Device.get_by_uid(device_id, true, actor: actor) do
        {:ok, %Device{agent_id: agent_id}} when is_binary(agent_id) ->
          case String.trim(agent_id) do
            "" -> []
            trimmed -> [trimmed]
          end

        _ ->
          []
      end

    Enum.uniq(identifier_agents ++ attribute_agent)
  rescue
    e ->
      Logger.warning("Failed to load agent identities for #{device_id}: #{inspect(e)}")
      []
  end

  @doc """
  Invalidate (mark stale) IP alias states that conflict with strong identity.

  Used when an alias-driven merge is blocked because the alias points at a
  device bound to a different agent; staling the alias removes it from
  resolution so it stops feeding merge attempts.
  """
  @spec invalidate_ip_alias(String.t(), String.t() | nil, String.t(), String.t(), term()) :: :ok
  def invalidate_ip_alias(ip, partition, alias_device_id, device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    query =
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value == ^ip and device_id == ^alias_device_id and
          state in [:detected, :confirmed, :updated]
      )
      |> Resolver.maybe_filter_alias_partition(partition)

    case Ash.read(query, query_opts) do
      {:ok, alias_states} when alias_states != [] ->
        Enum.each(alias_states, fn alias_state ->
          alias_state
          |> Ash.Changeset.for_update(:mark_stale, %{})
          |> Ash.update(query_opts)
          |> case do
            {:ok, _} -> :ok
            {:error, error} -> Logger.warning("Failed to stale alias: #{inspect(error)}")
          end
        end)

        Logger.warning(
          "Invalidated IP alias #{ip} on #{alias_device_id}: conflicts with agent identity " <>
            "of #{device_id}"
        )

        :telemetry.execute(
          [:serviceradar, :identity_reconciler, :alias, :invalidated],
          %{count: length(alias_states)},
          %{alias_ip: ip, alias_device_id: alias_device_id, device_id: device_id}
        )

      _ ->
        :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("Failed to invalidate conflicting alias #{ip}: #{inspect(e)}")
      :ok
  end
end
