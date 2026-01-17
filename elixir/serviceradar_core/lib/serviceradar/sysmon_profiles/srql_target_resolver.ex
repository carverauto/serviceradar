defmodule ServiceRadar.SysmonProfiles.SrqlTargetResolver do
  @moduledoc """
  Resolves sysmon profile targeting using SRQL queries.

  This module evaluates SRQL `target_query` fields on profiles to determine
  which profile should apply to a given device.

  In single-tenant-per-deployment architecture, the DB connection's
  search_path determines which schema is queried.

  ## Resolution Process

  1. Load all targeting profiles (enabled, non-default, with target_query)
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

  alias ServiceRadar.Inventory.Device
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
  # Device UID regex for validation - prevents SRQL injection via crafted device UIDs
  @device_uid_regex ~r/^(?:sr:)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @spec resolve_for_device(String.t(), map()) ::
          {:ok, SysmonProfile.t() | nil} | {:error, term()}
  def resolve_for_device(device_uid, actor) when is_binary(device_uid) do
    # Validate device_uid is a proper ServiceRadar UUID to prevent SRQL injection
    if Regex.match?(@device_uid_regex, device_uid) do
      # Load all targeting profiles ordered by priority
      case load_targeting_profiles(actor) do
        {:ok, []} ->
          {:ok, nil}

        {:ok, profiles} ->
          # Try each profile in order until one matches
          find_matching_profile(profiles, device_uid, actor)

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.warning("SrqlTargetResolver: invalid device_uid format: #{inspect(device_uid)}")
      {:error, :invalid_device_uid}
    end
  end

  def resolve_for_device(nil, _actor), do: {:ok, nil}

  # Backwards compatibility - ignore tenant_schema parameter
  @doc false
  def resolve_for_device(_tenant_schema, device_uid, actor) do
    resolve_for_device(device_uid, actor)
  end

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

  # Find the first profile that matches the device
  defp find_matching_profile([], _device_uid, _actor), do: {:ok, nil}

  defp find_matching_profile([profile | rest], device_uid, actor) do
    case matches_device?(profile, device_uid, actor) do
      {:ok, true} ->
        Logger.debug(
          "SrqlTargetResolver: profile #{profile.id} matches device #{device_uid}"
        )

        {:ok, profile}

      {:ok, false} ->
        find_matching_profile(rest, device_uid, actor)

      {:error, reason} ->
        # Log error but continue trying other profiles
        Logger.warning(
          "SrqlTargetResolver: error evaluating profile #{profile.id}: #{inspect(reason)}"
        )

        find_matching_profile(rest, device_uid, actor)
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
    # Parse the SRQL query to get filters
    case ServiceRadarSRQL.Native.parse_ast(query_string) do
      {:ok, ast_json} ->
        case Jason.decode(ast_json) do
          {:ok, ast} ->
            # Execute a simple device count query with the filters
            check_device_exists(ast, actor)

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  # Check if any devices match the parsed SRQL filters
  defp check_device_exists(ast, actor) do
    filters = extract_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> apply_srql_filters(filters)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:ok, false}
      {:ok, _device} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  # Extract filter conditions from parsed SRQL AST
  defp extract_filters(%{"filters" => filters}) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        field: Map.get(filter, "field"),
        op: Map.get(filter, "op", "eq"),
        value: Map.get(filter, "value")
      }
    end)
  end

  defp extract_filters(_), do: []

  # Apply SRQL filters to an Ash query
  defp apply_srql_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_filter(q, filter)
    end)
  end

  defp apply_filter(query, %{field: field, op: op, value: value}) when is_binary(field) do
    # Map common SRQL field names to Device attributes
    mapped_field = map_field(field)

    # Handle special cases like tags
    if String.starts_with?(field, "tags.") do
      # tags.key:value -> filter on tags JSONB
      tag_key = String.replace_prefix(field, "tags.", "")
      apply_tag_filter(query, tag_key, value)
    else
      apply_standard_filter(query, mapped_field, op, value)
    end
  rescue
    e ->
      # Log the error but continue - unknown fields are skipped gracefully
      Logger.debug("SrqlTargetResolver: skipping filter #{field} #{op} #{inspect(value)}: #{Exception.message(e)}")
      query
  end

  defp apply_filter(query, _), do: query

  # Map SRQL field names to Device attribute names
  defp map_field("hostname"), do: :hostname
  defp map_field("uid"), do: :uid
  defp map_field("type"), do: :type_id
  defp map_field("os"), do: :os
  defp map_field("status"), do: :status
  defp map_field(field), do: String.to_existing_atom(field)

  # Apply a standard equality filter
  defp apply_standard_filter(query, field, "eq", value) when is_atom(field) do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  defp apply_standard_filter(query, field, "contains", value) when is_atom(field) do
    Ash.Query.filter_input(query, %{field => %{contains: value}})
  end

  defp apply_standard_filter(query, field, "in", value) when is_atom(field) and is_list(value) do
    Ash.Query.filter_input(query, %{field => %{in: value}})
  end

  defp apply_standard_filter(query, _field, _op, _value), do: query

  # Apply a tag filter using JSONB containment
  defp apply_tag_filter(query, tag_key, tag_value) do
    # Use Ash fragment for JSONB filter
    # tags @> '{"key": "value"}'::jsonb
    Ash.Query.filter(query, fragment("tags @> ?", ^%{tag_key => tag_value}))
  end
end
