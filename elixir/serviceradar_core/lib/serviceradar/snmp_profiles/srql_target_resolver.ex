defmodule ServiceRadar.SNMPProfiles.SrqlTargetResolver do
  @moduledoc """
  Resolves SNMP profile targeting using SRQL queries.

  This module evaluates SRQL `target_query` fields on profiles to determine
  which profile should apply to a given device.

  In single-deployment architecture, the DB connection's
  search_path determines which schema is queried.

  ## Resolution Process

  1. Load all targeting profiles (enabled, non-default, with target_query)
  2. Sort by priority (highest first)
  3. For each profile, read which of the still-unmatched devices its SRQL
     filters select, in one query restricted to those device UIDs
  4. Give each device the first profile that selects it

  ## Interface Targeting

  SNMP profiles can also target interfaces:

      in:interfaces type:ethernet device.hostname:router-*

  In this case, we check if the device has any matching interfaces.
  """

  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLProfileResolver

  require Ash.Query
  require Logger

  @doc """
  Resolves the matching SNMP profile for a device using SRQL targeting.

  Returns the first profile whose target_query matches the device,
  or nil if no targeting profiles match.

  ## Parameters

  - `device_uid` - The UID of the device to match
  - `actor` - The actor for Ash operations

  ## Returns

  - `{:ok, profile}` - A matching profile was found
  - `{:ok, nil}` - No targeting profiles matched
  - `{:error, reason}` - An error occurred
  """
  @spec resolve_for_device(String.t() | nil, map()) ::
          {:ok, SNMPProfile.t() | nil} | {:error, term()}
  def resolve_for_device(device_uid, actor), do: resolve_for_device(device_uid, nil, actor)

  @doc """
  Resolves the matching SNMP profile for a device, honoring per-agent targeting.

  When `agent_id` is provided, only targeting profiles that apply to that agent
  are considered candidates: a profile with a non-empty `agent_ids` is excluded
  unless `agent_id` is in its set. A profile with an empty `agent_ids` behaves
  exactly as before (its `target_query` decides). When `agent_id` is `nil`, all
  targeting profiles are considered (legacy behavior).
  """
  @spec resolve_for_device(String.t() | nil, String.t() | nil, map()) ::
          {:ok, SNMPProfile.t() | nil} | {:error, term()}
  def resolve_for_device(device_uid, agent_id, actor) when is_binary(device_uid) do
    [device_uid]
    |> resolve_for_devices(agent_id, actor)
    |> Map.fetch!(device_uid)
  end

  def resolve_for_device(nil, _agent_id, _actor), do: {:ok, nil}

  @doc """
  Resolves the matching SNMP profile for each of `device_uids`.

  Each profile's `target_query` is evaluated once against all the devices it
  can still claim, so the reads depend on the number of targeting profiles and
  not on the number of devices. Every device gets the result
  `resolve_for_device/3` gives it.
  """
  @spec resolve_for_devices([String.t()], String.t() | nil, map()) ::
          %{String.t() => {:ok, SNMPProfile.t() | nil} | {:error, term()}}
  def resolve_for_devices(device_uids, agent_id, actor) when is_list(device_uids) do
    SRQLProfileResolver.resolve_many(device_uids, actor,
      load_profiles: fn actor -> load_targeting_profiles(agent_id, actor) end,
      match_profiles: &matching_devices/3,
      log_prefix: "SNMPSrqlTargetResolver"
    )
  end

  # Load all profiles with SRQL targeting, ordered by priority.
  #
  # When agent_id is provided, use the agent-aware read action so the database
  # (and the agent_ids GIN index) excludes profiles pinned to other agents.
  # When agent_id is nil, fall back to listing every targeting profile (legacy).
  defp load_targeting_profiles(nil, actor) do
    query = Ash.Query.for_read(SNMPProfile, :list_targeting_profiles, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} -> {:ok, profiles}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_targeting_profiles(agent_id, actor) when is_binary(agent_id) do
    query =
      Ash.Query.for_read(SNMPProfile, :targeting_profiles_for_agent, %{agent_id: agent_id},
        actor: actor
      )

    case Ash.read(query, actor: actor) do
      {:ok, profiles} -> {:ok, profiles}
      {:error, reason} -> {:error, reason}
    end
  end

  # Which of the devices a profile's target_query matches.
  #
  # An interface query is not evaluated against interfaces here: any device
  # that exists and is in service is taken to match, as before.
  defp matching_devices(profile, device_uids, actor) do
    target_query = profile.target_query

    cond do
      is_nil(target_query) or target_query == "" ->
        {:ok, MapSet.new()}

      String.starts_with?(target_query, "in:interfaces") ->
        match_devices([], device_uids, actor)

      true ->
        with {:ok, ast} <- SRQLAst.parse(String.trim(target_query)) do
          ast
          |> SRQLDeviceMatcher.extract_filters()
          |> match_devices(device_uids, actor)
        end
    end
  end

  defp match_devices(filters, device_uids, actor) do
    SRQLDeviceMatcher.matching_uids(filters, device_uids, actor,
      log_prefix: "SNMPSrqlTargetResolver"
    )
  end
end
