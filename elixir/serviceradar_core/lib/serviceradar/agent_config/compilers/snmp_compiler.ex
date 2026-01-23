defmodule ServiceRadar.AgentConfig.Compilers.SNMPCompiler do
  @moduledoc """
  Compiler for SNMP configurations.

  Transforms SNMPProfile Ash resources into agent-consumable SNMP
  configuration format using SRQL-based targeting.

  ## New Architecture (v2)

  SNMP profiles now use SRQL queries to dynamically target devices from inventory:
  1. Execute target_query (SRQL) to find matching interfaces/devices
  2. Load OIDs from profile's oid_template_ids
  3. For each device, resolve credentials (device override → profile fallback)
  4. Build target config for each device

  ## Resolution Order

  When resolving which profile applies to a device:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile (fallback)

  ## Output Format

  The compiled config follows the proto SNMPConfig structure:

      %{
        "enabled" => true,
        "profile_id" => "uuid",
        "profile_name" => "Core Network Monitoring",
        "targets" => [
          %{
            "id" => "device-uid",
            "name" => "Core Router 1",
            "host" => "192.168.1.1",
            "port" => 161,
            "version" => "v2c",
            "community" => "public",
            "poll_interval_seconds" => 60,
            "timeout_seconds" => 5,
            "retries" => 3,
            "oids" => [
              %{
                "oid" => ".1.3.6.1.2.1.2.2.1.10",
                "name" => "ifInOctets",
                "data_type" => "counter",
                "scale" => 1.0,
                "delta" => true
              }
            ]
          }
        ]
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.Vault
  alias UUID

  @impl true
  def config_type, do: :snmp

  @impl true
  def source_resources do
    [SNMPProfile, SNMPOIDTemplate, SNMPTarget, SNMPOIDConfig, Device]
  end

  @impl true
  def compile(_partition, _agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:snmp_compiler)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device
    profile = resolve_profile(device_uid, actor)

    if profile && profile.enabled do
      config = compile_profile(profile, actor)
      {:ok, config}
    else
      # Return disabled config if no profile found or profile is disabled
      {:ok, disabled_config()}
    end
  rescue
    e ->
      Logger.error("SNMPCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "enabled") ->
        {:error, "Config missing 'enabled' key"}

      config["enabled"] and not Map.has_key?(config, "targets") ->
        {:error, "Config missing 'targets' key"}

      true ->
        :ok
    end
  end

  @doc """
  Resolves the SNMP profile for a device using SRQL targeting.

  Resolution order:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile

  Returns the matching SNMPProfile or nil if no profile matches.
  """
  @spec resolve_profile(String.t() | nil, map()) :: SNMPProfile.t() | nil
  def resolve_profile(device_uid, actor) do
    try_srql_targeting(device_uid, actor) ||
      get_default_profile(actor)
  end

  # Try to find a matching profile via SRQL targeting
  defp try_srql_targeting(nil, _actor), do: nil

  defp try_srql_targeting(device_uid, actor) do
    case SrqlTargetResolver.resolve_for_device(device_uid, actor) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        Logger.warning("SNMPCompiler: SRQL targeting failed - #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Compiles a profile to the agent config format using SRQL-based targeting.

  New flow:
  1. Execute target_query to find matching devices
  2. Load OIDs from profile's oid_template_ids
  3. For each device, build target config with resolved credentials
  """
  @spec compile_profile(SNMPProfile.t(), map()) :: map()
  def compile_profile(profile, actor) do
    # 1. Load explicit targets (from interface selection or profile overrides)
    profile_targets = load_profile_targets(profile, actor)

    # 2. Execute target_query to find matching devices
    devices = execute_target_query(profile.target_query, actor)

    # 3. Load OIDs from profile's templates
    oids = load_template_oids(profile.oid_template_ids, actor)

    # 4. Build target config for each device (only when templates are present)
    query_targets =
      devices
      |> Enum.map(fn device -> compile_device_target(device, profile, oids, actor) end)
      |> Enum.reject(&is_nil/1)

    compiled_targets =
      profile_targets
      |> merge_targets(query_targets)

    %{
      "enabled" => profile.enabled and compiled_targets != [],
      "profile_id" => profile.id,
      "profile_name" => profile.name,
      "targets" => compiled_targets
    }
  end

  @doc """
  Execute the SRQL target_query to find matching devices.

  Handles both interface and device queries:
  - `in:interfaces ...` → Extract unique devices from matching interfaces
  - `in:devices ...` → Use matched devices directly
  """
  @spec execute_target_query(String.t() | nil, map()) :: [Device.t()]
  def execute_target_query(nil, _actor), do: []
  def execute_target_query("", _actor), do: []

  def execute_target_query(target_query, actor) do
    target_query = String.trim(target_query)

    case ServiceRadarSRQL.Native.parse_ast(target_query) do
      {:ok, ast_json} ->
        case Jason.decode(ast_json) do
          {:ok, ast} ->
            entity = extract_entity(target_query)
            execute_parsed_query(entity, ast, actor)

          {:error, reason} ->
            Logger.warning("SNMPCompiler: failed to decode SRQL AST - #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to parse SRQL query - #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.error("SNMPCompiler: error executing target query - #{inspect(e)}")
      []
  end

  # Extract the entity type from SRQL query
  defp extract_entity(query) when is_binary(query) do
    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] -> String.downcase(entity)
      _ -> "devices"
    end
  end

  # Execute query based on entity type
  defp execute_parsed_query("interfaces", ast, actor) do
    # Query interfaces, then extract unique devices
    filters = extract_filters(ast)

    query =
      Interface
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> apply_interface_filters(filters)
      |> Ash.Query.distinct(:device_id)
      |> Ash.Query.load(:device)

    case Ash.read(query, actor: actor) do
      {:ok, interfaces} ->
        # Extract unique devices
        interfaces
        |> Enum.map(& &1.device)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.uid)

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to query interfaces - #{inspect(reason)}")
        []
    end
  end

  defp execute_parsed_query(_entity, ast, actor) do
    # Query devices directly
    filters = extract_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> apply_device_filters(filters)

    case Ash.read(query, actor: actor) do
      {:ok, devices} -> devices
      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to query devices - #{inspect(reason)}")
        []
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

  # Apply filters to interface query
  defp apply_interface_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_interface_filter(q, filter)
    end)
  end

  defp apply_interface_filter(query, %{field: field, op: op, value: value})
       when is_binary(field) do
    mapped = map_interface_field(field)

    if mapped do
      apply_filter_op(query, mapped, op, value)
    else
      query
    end
  rescue
    _ -> query
  end

  defp apply_interface_filter(query, _), do: query

  # Map SRQL interface fields to Ash attributes
  @interface_field_map %{
    "if_name" => :if_name,
    "name" => :if_name,
    "if_descr" => :if_descr,
    "description" => :if_descr,
    "if_alias" => :if_alias,
    "alias" => :if_alias,
    "device_id" => :device_id,
    "device_ip" => :device_ip,
    "ip" => :device_ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "if_oper_status" => :if_oper_status,
    "oper_status" => :if_oper_status,
    "if_admin_status" => :if_admin_status,
    "admin_status" => :if_admin_status,
    "if_speed" => :if_speed,
    "speed" => :if_speed,
    "if_phys_address" => :if_phys_address,
    "mac" => :if_phys_address,
    "type" => :if_type
  }

  defp map_interface_field(field), do: Map.get(@interface_field_map, field)

  # Apply filters to device query
  defp apply_device_filters(query, filters) do
    Enum.reduce(filters, query, fn filter, q ->
      apply_device_filter(q, filter)
    end)
  end

  defp apply_device_filter(query, %{field: field, op: op, value: value})
       when is_binary(field) do
    # Handle tag filters specially
    if String.starts_with?(field, "tags.") do
      tag_key = String.replace_prefix(field, "tags.", "")
      Ash.Query.filter(query, fragment("tags @> ?", ^%{tag_key => value}))
    else
      mapped = map_device_field(field)

      if mapped do
        apply_filter_op(query, mapped, op, value)
      else
        query
      end
    end
  rescue
    _ -> query
  end

  defp apply_device_filter(query, _), do: query

  # Map SRQL device fields to Ash attributes
  @device_field_map %{
    "uid" => :uid,
    "device_id" => :uid,
    "hostname" => :hostname,
    "name" => :name,
    "ip" => :ip,
    "gateway_id" => :gateway_id,
    "agent_id" => :agent_id,
    "vendor_name" => :vendor_name,
    "model" => :model,
    "type" => :type,
    "type_id" => :type_id,
    "os" => :os,
    "status" => :status
  }

  defp map_device_field(field), do: Map.get(@device_field_map, field)

  # Apply filter operation
  defp apply_filter_op(query, field, op, value) when op in ["eq", "equals"] do
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  defp apply_filter_op(query, field, op, value) when op in ["contains", "like"] do
    # Strip % wildcards if present from SRQL like syntax
    value = value |> String.trim_leading("%") |> String.trim_trailing("%")
    Ash.Query.filter_input(query, %{field => %{contains: value}})
  end

  defp apply_filter_op(query, field, "in", value) when is_list(value) do
    Ash.Query.filter_input(query, %{field => %{in: value}})
  end

  defp apply_filter_op(query, field, _op, value) do
    # Default to equality
    Ash.Query.filter_input(query, %{field => %{eq: value}})
  end

  @doc """
  Load OIDs from the selected OID templates.
  """
  @spec load_template_oids([String.t()] | nil, map()) :: [map()]
  def load_template_oids(nil, _actor), do: []
  def load_template_oids([], _actor), do: []

  def load_template_oids(template_ids, actor) when is_list(template_ids) do
    # Load templates from database
    query =
      SNMPOIDTemplate
      |> Ash.Query.filter(id in ^template_ids)

    case Ash.read(query, actor: actor) do
      {:ok, templates} ->
        # Flatten all OIDs from all templates
        templates
        |> Enum.flat_map(fn template -> template.oids || [] end)
        |> Enum.uniq_by(fn oid -> Map.get(oid, "oid") end)

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to load OID templates - #{inspect(reason)}")
        []
    end
  end

  # Compile a device into a target config
  defp compile_device_target(device, profile, oids, actor) do
    if oids == [] do
      Logger.debug("SNMPCompiler: skipping device #{device.uid} (no OIDs)")
      nil
    else
    # Get host address - prefer IP, fall back to hostname
    host = device.ip || device.hostname

    if missing_host?(host) do
      Logger.debug("SNMPCompiler: skipping device #{device.uid} (no IP or hostname)")
      nil
    else
      compile_device_target_with_host(device, profile, oids, actor, host)
    end
    end
  end

  defp compile_device_target_with_host(device, profile, oids, actor, host) do
    credential = resolve_device_credentials(device.uid, profile, actor)

    if valid_credentials?(credential) do
      version = Map.get(credential, :version, profile.version)
      base_target = build_base_target(device, host, profile, oids, version)
      apply_snmp_auth(base_target, version, credential)
    else
      Logger.debug("SNMPCompiler: skipping device #{device.uid} (missing credentials)")
      nil
    end
  end

  defp build_base_target(device, host, profile, oids, version) do
    %{
      "id" => device.uid,
      "name" => device.name || device.hostname || device.uid,
      "host" => host,
      "port" => 161,
      "version" => format_version(version),
      "poll_interval_seconds" => profile.poll_interval,
      "timeout_seconds" => profile.timeout,
      "retries" => profile.retries,
      "oids" => compile_oids(oids)
    }
  end

  defp apply_snmp_auth(base_target, version, credential) do
    case version do
      :v1 -> Map.put(base_target, "community", Map.get(credential, :community))
      :v2c -> Map.put(base_target, "community", Map.get(credential, :community))
      :v3 -> Map.put(base_target, "v3_auth", compile_v3_auth(credential))
    end
  end

  defp missing_host?(host), do: is_nil(host) or host == ""

  # Compile OIDs to the expected format
  defp compile_oids(oids) do
    Enum.map(oids, fn oid ->
      %{
        "oid" => Map.get(oid, "oid"),
        "name" => Map.get(oid, "name"),
        "data_type" => to_string(Map.get(oid, "data_type", "gauge")),
        "scale" => Map.get(oid, "scale", 1.0),
        "delta" => Map.get(oid, "delta", false)
      }
    end)
  end

  defp load_profile_targets(profile, actor) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile.id)
      |> Ash.Query.load(:oid_configs)

    case Ash.read(query, actor: actor) do
      {:ok, targets} ->
        targets
        |> Enum.map(&compile_profile_target(&1, profile))
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to load profile targets - #{inspect(reason)}")
        []
    end
  end

  defp compile_profile_target(%SNMPTarget{} = target, profile) do
    oids =
      target.oid_configs
      |> Enum.map(&oid_config_to_map/1)
      |> Enum.reject(&is_nil/1)

    if oids == [] do
      nil
    else
      base_target = %{
        "id" => target.id,
        "name" => target.name,
        "host" => target.host,
        "port" => target.port,
        "version" => format_version(target.version),
        "poll_interval_seconds" => profile.poll_interval,
        "timeout_seconds" => profile.timeout,
        "retries" => profile.retries,
        "oids" => compile_oids(oids)
      }

      apply_snmp_auth(base_target, target.version, target_credential(target))
    end
  end

  defp compile_profile_target(_, _), do: nil

  defp oid_config_to_map(%SNMPOIDConfig{} = oid) do
    %{
      "oid" => oid.oid,
      "name" => oid.name,
      "data_type" => to_string(oid.data_type),
      "scale" => oid.scale || 1.0,
      "delta" => oid.delta || false
    }
  end

  defp oid_config_to_map(_), do: nil

  defp target_credential(%SNMPTarget{} = target) do
    %{
      version: target.version || :v2c,
      community: decrypt_credential(Map.get(target, :community_encrypted)),
      username: target.username,
      security_level: target.security_level,
      auth_protocol: target.auth_protocol,
      auth_password: decrypt_credential(Map.get(target, :auth_password_encrypted)),
      priv_protocol: target.priv_protocol,
      priv_password: decrypt_credential(Map.get(target, :priv_password_encrypted))
    }
  end

  defp target_credential(_), do: %{}

  defp merge_targets(primary, secondary) do
    (primary ++ secondary)
    |> Enum.reduce(%{}, fn target, acc ->
      key =
        Map.get(target, "host") ||
          Map.get(target, "name") ||
          Map.get(target, "id") ||
          UUID.uuid4()

      Map.put_new(acc, key, target)
    end)
    |> Map.values()
  end

  # Resolve credentials: device override → profile fallback
  defp resolve_device_credentials(device_uid, profile, actor) do
    case CredentialResolver.resolve_for_device(device_uid, actor) do
      {:ok, %{credential: credential, source: :device_override}} when is_map(credential) ->
        credential

      {:ok, %{credential: credential, source: :profile}} when is_map(credential) ->
        credential

      _ ->
        # Use profile credentials as fallback
        build_profile_credential(profile)
    end
  end

  # Build credential map from profile
  defp build_profile_credential(profile) do
    %{
      version: profile.version || :v2c,
      community: decrypt_credential(profile.community_encrypted),
      username: profile.username,
      security_level: profile.security_level,
      auth_protocol: profile.auth_protocol,
      auth_password: decrypt_credential(profile.auth_password_encrypted),
      priv_protocol: profile.priv_protocol,
      priv_password: decrypt_credential(profile.priv_password_encrypted)
    }
  end

  # Decrypt an encrypted credential, returning nil if not set
  defp decrypt_credential(nil), do: nil

  defp decrypt_credential(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  # Check if credentials are valid for SNMP connection
  defp valid_credentials?(nil), do: false

  defp valid_credentials?(credential) when is_map(credential) do
    case Map.get(credential, :version, :v2c) do
      :v3 ->
        present?(Map.get(credential, :username)) or
          present?(Map.get(credential, :auth_password)) or
          present?(Map.get(credential, :priv_password))

      _ ->
        present?(Map.get(credential, :community))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  # Compile SNMPv3 authentication parameters
  defp compile_v3_auth(credential) do
    %{
      "username" => Map.get(credential, :username),
      "security_level" => format_security_level(Map.get(credential, :security_level)),
      "auth_protocol" => format_auth_protocol(Map.get(credential, :auth_protocol)),
      "auth_password" => Map.get(credential, :auth_password),
      "priv_protocol" => format_priv_protocol(Map.get(credential, :priv_protocol)),
      "priv_password" => Map.get(credential, :priv_password)
    }
  end

  # Format version atom to string
  defp format_version(:v1), do: "v1"
  defp format_version(:v2c), do: "v2c"
  defp format_version(:v3), do: "v3"
  defp format_version(_), do: "v2c"

  # Format security level atom to string
  defp format_security_level(:no_auth_no_priv), do: "noAuthNoPriv"
  defp format_security_level(:auth_no_priv), do: "authNoPriv"
  defp format_security_level(:auth_priv), do: "authPriv"
  defp format_security_level(_), do: "noAuthNoPriv"

  # Format auth protocol atom to string
  defp format_auth_protocol(:md5), do: "MD5"
  defp format_auth_protocol(:sha), do: "SHA"
  defp format_auth_protocol(:sha224), do: "SHA-224"
  defp format_auth_protocol(:sha256), do: "SHA-256"
  defp format_auth_protocol(:sha384), do: "SHA-384"
  defp format_auth_protocol(:sha512), do: "SHA-512"
  defp format_auth_protocol(_), do: nil

  # Format priv protocol atom to string
  defp format_priv_protocol(:des), do: "DES"
  defp format_priv_protocol(:aes), do: "AES"
  defp format_priv_protocol(:aes192), do: "AES-192"
  defp format_priv_protocol(:aes256), do: "AES-256"
  defp format_priv_protocol(:aes192c), do: "AES-192-C"
  defp format_priv_protocol(:aes256c), do: "AES-256-C"
  defp format_priv_protocol(_), do: nil

  @doc """
  Returns disabled SNMP configuration when no profile is assigned.
  """
  @spec disabled_config() :: map()
  def disabled_config do
    %{
      "enabled" => false,
      "profile_id" => nil,
      "profile_name" => nil,
      "targets" => []
    }
  end

  # Get the default profile
  defp get_default_profile(actor) do
    query =
      SNMPProfile
      |> Ash.Query.for_read(:get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end
end
