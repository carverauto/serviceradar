defmodule ServiceRadar.AgentConfig.Compilers.DuskCompiler do
  @moduledoc """
  DEPRECATED: Dusk checker has been migrated to the WASM plugin system.

  The dusk-checker is now a standard WASM plugin managed through regular
  PluginAssignment records. This compiler is kept for reference but is no
  longer used by the config generation pipeline.

  To use the dusk-checker:
  1. Upload the dusk-checker WASM plugin package
  2. Create PluginAssignment records with the appropriate params:
     - node_address: WebSocket endpoint of the Dusk node
     - timeout: Check timeout (e.g., "30s")

  ---

  Original documentation (historical reference):

  Compiler for dusk monitoring configurations.

  Transforms DuskProfile Ash resources into plugin assignment configurations
  for the dusk-checker WASM plugin using SRQL-based targeting.

  ## Resolution Order

  When resolving which profile applies to a device:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile (fallback)
  3. No profile = no dusk plugin assignment

  Profiles use `target_query` (SRQL) to define which devices they apply to.
  Example: `target_query: "in:devices tags.role:dusk-node"` matches all devices
  with the tag `role=dusk-node`.

  ## Output Format

  The compiled config is a plugin assignment for the dusk-checker plugin:

      %{
        assignment_id: "dusk-profile-uuid",
        plugin_id: "dusk-checker",
        name: "Dusk Checker",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        capabilities: ["get_config", "log", "submit_result", "http_request",
                       "websocket_connect", "websocket_send", "websocket_recv", "websocket_close"],
        params: %{
          "node_address" => "localhost:8080",
          "timeout" => "30s",
          "use_ssl" => false
        },
        permissions: %{
          "allowed_domains" => ["*"],
          "allowed_ports" => [8080, 443]
        },
        resources: %{
          "requested_memory_mb" => 64,
          "max_open_connections" => 1
        },
        enabled: true,
        interval_sec: 60,
        timeout_sec: 30,
        source: "dusk_profile",
        profile_id: "uuid",
        profile_name: "Production Dusk Node"
      }

  If no profile is found, returns nil (no assignment).
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DuskProfiles.DuskProfile
  alias ServiceRadar.Inventory.Device

  # Default plugin configuration for dusk-checker
  @dusk_plugin_id "dusk-checker"
  @dusk_plugin_name "Dusk Checker"
  @dusk_entrypoint "run_check"
  @dusk_runtime "wasi-preview1"
  @dusk_outputs "serviceradar.plugin_result.v1"
  @dusk_capabilities [
    "get_config",
    "log",
    "submit_result",
    "http_request",
    "websocket_connect",
    "websocket_send",
    "websocket_recv",
    "websocket_close"
  ]

  @impl true
  def config_type, do: :dusk

  @impl true
  def source_resources do
    [DuskProfile]
  end

  @impl true
  def compile(_partition, _agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:dusk_compiler)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device
    profile = resolve_profile(device_uid, actor)

    if profile && profile.enabled do
      config = compile_to_plugin_assignment(profile)
      {:ok, config}
    else
      # Return nil if no profile found or profile is disabled
      {:ok, nil}
    end
  rescue
    e ->
      Logger.error("DuskCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, :params) ->
        {:error, "Config missing 'params' key"}

      not is_map(config.params) ->
        {:error, "Config 'params' must be a map"}

      config.params["node_address"] in [nil, ""] ->
        {:error, "Config params missing 'node_address'"}

      true ->
        :ok
    end
  end

  def validate(nil), do: :ok

  @doc """
  Resolves the dusk profile for a device using SRQL targeting.

  Resolution order:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile

  Returns the matching DuskProfile or nil if no profile matches.
  """
  @spec resolve_profile(String.t() | nil, map()) :: DuskProfile.t() | nil
  def resolve_profile(device_uid, actor) do
    try_srql_targeting(device_uid, actor) ||
      get_default_profile(actor)
  end

  @doc """
  Compiles a DuskProfile to a plugin assignment configuration.

  This transforms the profile into a format compatible with the
  plugin assignment system used by the agent.
  """
  @spec compile_to_plugin_assignment(DuskProfile.t()) :: map()
  def compile_to_plugin_assignment(profile) do
    # Parse timeout for both params and timeout_sec
    timeout_seconds = parse_timeout_seconds(profile.timeout)
    port = extract_port(profile.node_address)

    %{
      assignment_id: "dusk-#{profile.id}",
      plugin_id: @dusk_plugin_id,
      name: @dusk_plugin_name,
      entrypoint: @dusk_entrypoint,
      runtime: @dusk_runtime,
      outputs: @dusk_outputs,
      capabilities: @dusk_capabilities,
      params: %{
        "node_address" => profile.node_address,
        "timeout" => profile.timeout,
        "use_ssl" => String.starts_with?(profile.node_address || "", "wss://")
      },
      permissions: %{
        "allowed_domains" => ["*"],
        "allowed_ports" => [port]
      },
      resources: %{
        "requested_memory_mb" => 64,
        "max_open_connections" => 1
      },
      enabled: profile.enabled,
      interval_sec: 60,
      timeout_sec: timeout_seconds,
      # Metadata for tracking
      source: "dusk_profile",
      profile_id: to_string(profile.id),
      profile_name: profile.name
    }
  end

  # Parse timeout string to seconds
  defp parse_timeout_seconds(nil), do: 30
  defp parse_timeout_seconds(""), do: 30

  defp parse_timeout_seconds(timeout) when is_binary(timeout) do
    cond do
      String.ends_with?(timeout, "s") ->
        timeout |> String.trim_trailing("s") |> String.to_integer()

      String.ends_with?(timeout, "m") ->
        timeout |> String.trim_trailing("m") |> String.to_integer() |> Kernel.*(60)

      String.ends_with?(timeout, "h") ->
        timeout |> String.trim_trailing("h") |> String.to_integer() |> Kernel.*(3600)

      true ->
        30
    end
  rescue
    _ -> 30
  end

  # Extract port from node address
  defp extract_port(nil), do: 8080

  defp extract_port(address) when is_binary(address) do
    # Handle wss://host:port/path or host:port formats
    address
    |> String.replace(~r{^wss?://}, "")
    |> String.split("/")
    |> List.first()
    |> String.split(":")
    |> case do
      [_host, port] ->
        case Integer.parse(port) do
          {p, _} -> p
          :error -> 8080
        end

      _ ->
        8080
    end
  end

  # Try to find a matching profile via SRQL targeting
  defp try_srql_targeting(nil, _actor), do: nil

  defp try_srql_targeting(device_uid, actor) do
    # Get targeting profiles ordered by priority
    query =
      DuskProfile
      |> Ash.Query.for_read(:list_targeting_profiles, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} ->
        # Find the first profile whose target_query matches this device
        Enum.find(profiles, fn profile ->
          matches_device?(profile.target_query, device_uid, actor)
        end)

      {:error, reason} ->
        Logger.warning("DuskCompiler: failed to load targeting profiles - #{inspect(reason)}")
        nil
    end
  end

  # Check if a device matches an SRQL query
  defp matches_device?(nil, _device_uid, _actor), do: false
  defp matches_device?(_target_query, nil, _actor), do: false

  defp matches_device?(target_query, device_uid, actor) do
    # Build a combined query: original query + device UID filter
    # This checks if the device matches the target_query criteria
    combined_query = "#{target_query} uid:\"#{device_uid}\""

    # Parse the SRQL query to get filters
    case ServiceRadarSRQL.Native.parse_ast(combined_query) do
      {:ok, ast_json} ->
        case Jason.decode(ast_json) do
          {:ok, ast} ->
            # Execute a simple device count query with the filters
            check_device_exists(ast, actor)

          {:error, _reason} ->
            false
        end

      {:error, _reason} ->
        false
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
      {:ok, nil} -> false
      {:ok, _device} -> true
      {:error, _reason} -> false
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
    _e ->
      # Unknown fields are skipped gracefully
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
    Ash.Query.filter(query, fragment("tags @> ?", ^%{tag_key => tag_value}))
  end

  # Get the default profile
  defp get_default_profile(actor) do
    query =
      DuskProfile
      |> Ash.Query.for_read(:get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  # Legacy function for backwards compatibility during migration
  @doc false
  def default_config do
    %{
      "enabled" => false,
      "node_address" => "",
      "timeout" => "5m",
      "profile_id" => nil,
      "profile_name" => nil,
      "config_source" => "default"
    }
  end
end
