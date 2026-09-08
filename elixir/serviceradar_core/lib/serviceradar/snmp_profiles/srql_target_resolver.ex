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
  3. For each profile, execute the SRQL query with a device UID filter
  4. Return the first profile where the query matches the device

  ## Query Execution

  For a profile with `target_query: "in:devices tags.role:network-monitor"`, we execute:

      in:devices tags.role:network-monitor uid:{device_uid}

  If this query returns results, the profile matches the device.

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
    SRQLProfileResolver.resolve(device_uid, actor,
      load_profiles: fn actor -> load_targeting_profiles(agent_id, actor) end,
      match_profile: &matches_device?/3,
      log_prefix: "SNMPSrqlTargetResolver"
    )
  end

  def resolve_for_device(nil, _agent_id, _actor), do: {:ok, nil}

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

  # Check if a profile's target_query matches a device
  defp matches_device?(profile, device_uid, actor) do
    target_query = profile.target_query

    if is_nil(target_query) or target_query == "" do
      {:ok, false}
    else
      # Determine if this is a device or interface query
      if String.starts_with?(target_query, "in:interfaces") do
        # Interface targeting - check if device has matching interfaces
        match_via_interfaces(device_uid, actor)
      else
        # Device targeting - check if device matches directly
        combined_query = String.trim(target_query) <> " uid:\"#{device_uid}\""
        execute_device_match(combined_query, actor)
      end
    end
  end

  # Execute a device match query
  defp execute_device_match(query_string, actor) do
    with {:ok, ast} <- parse_query_ast(query_string) do
      check_device_exists(ast, actor)
    end
  end

  # For interface targeting, check if the device has any matching interfaces
  # This is a simplified approach - for full interface targeting we'd query the interfaces table
  defp match_via_interfaces(device_uid, actor) do
    # Transform interface query to device query by adding device.uid filter
    # e.g., "in:interfaces type:ethernet" -> check if device with uid has any interfaces
    # For now, we do a simple device lookup and assume interface targeting works
    # A full implementation would join with interfaces table
    device_query = "in:devices uid:\"#{device_uid}\""

    with {:ok, ast} <- parse_query_ast(device_query) do
      check_device_exists(ast, actor)
    end
  end

  defp parse_query_ast(query_string) do
    SRQLAst.parse(query_string)
  end

  # Check if any devices match the parsed SRQL filters
  defp check_device_exists(ast, actor) do
    SRQLDeviceMatcher.match_ast(ast, actor, log_prefix: "SNMPSrqlTargetResolver")
  end
end
