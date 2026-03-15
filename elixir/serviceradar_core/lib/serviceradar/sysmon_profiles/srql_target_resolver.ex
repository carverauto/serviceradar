defmodule ServiceRadar.SysmonProfiles.SrqlTargetResolver do
  @moduledoc """
  Resolves sysmon profile targeting using SRQL queries.

  This module evaluates SRQL `target_query` fields on profiles to determine
  which profile should apply to a given device.

  In single-deployment architecture, the DB connection's
  search_path determines which schema is queried.

  ## Resolution Process

  1. Load all targeting profiles (enabled, with target_query)
  2. Sort by priority (highest first)
  3. For each profile, execute the SRQL query with a device UID filter
  4. Return the first profile where the query matches the device

  ## Query Execution

  For a profile with `target_query: "in:devices tags.role:database"`, we execute:

      in:devices tags.role:database uid:{device_uid}

  If this query returns results, the profile matches the device.
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLProfileResolver
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  @doc """
  Resolves the matching sysmon profile for a device using SRQL targeting.

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
  @spec resolve_for_device(String.t(), map()) ::
          {:ok, SysmonProfile.t() | nil} | {:error, term()}
  def resolve_for_device(device_uid, actor) when is_binary(device_uid) do
    SRQLProfileResolver.resolve(device_uid, actor,
      load_profiles: &load_targeting_profiles/1,
      match_profile: &matches_device?/3,
      log_prefix: "SrqlTargetResolver"
    )
  end

  def resolve_for_device(nil, _actor), do: {:ok, nil}

  # Load all profiles with SRQL targeting, ordered by priority
  defp load_targeting_profiles(actor) do
    query =
      SysmonProfile
      |> Ash.Query.for_read(:list_targeting_profiles, %{}, actor: actor)

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
      # Build the combined query: original query + device UID filter
      combined_query = "#{target_query} uid:\"#{device_uid}\""

      case execute_srql_match(combined_query, actor) do
        {:ok, matched} -> {:ok, matched}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Execute an SRQL query and check if it returns results
  defp execute_srql_match(query_string, actor) do
    case SRQLAst.parse(query_string) do
      {:ok, ast} ->
        check_device_exists(ast, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Check if any devices match the parsed SRQL filters
  defp check_device_exists(ast, actor) do
    SRQLDeviceMatcher.match_ast(ast, actor, log_prefix: "SrqlTargetResolver")
  end
end
