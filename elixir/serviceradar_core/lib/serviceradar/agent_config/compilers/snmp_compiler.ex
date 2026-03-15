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
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter
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
    TargetedProfileResolver.resolve(device_uid, actor,
      resolver: &SrqlTargetResolver.resolve_for_device/2,
      default_resolver: &get_default_profile/1,
      log_prefix: "SNMPCompiler"
    )
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
    target_query = normalize_target_query(profile.target_query, profile.is_default)
    devices = execute_target_query(target_query, actor)

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

    case SRQLAst.parse(target_query) do
      {:ok, ast} ->
        entity = SRQLAst.entity(target_query)
        execute_parsed_query(entity, ast, actor)

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to parse SRQL query - #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.error("SNMPCompiler: error executing target query - #{inspect(e)}")
      []
  end

  defp normalize_target_query(target_query, is_default) do
    cond do
      target_query in [nil, ""] and is_default ->
        "in:devices"

      target_query in [nil, ""] ->
        nil

      true ->
        normalize_target_query(target_query)
    end
  end

  defp normalize_target_query(query) when is_binary(query) do
    SRQLQuery.ensure_target(query, :devices)
  end

  defp normalize_target_query(_), do: nil

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

  # Execute query based on entity type
  defp execute_parsed_query("interfaces", ast, actor) do
    # Query interfaces, then extract unique devices
    filters = SRQLDeviceMatcher.extract_filters(ast)

    query =
      Interface
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> SRQLDeviceMatcher.apply_filters(filters,
        field_mappings: @interface_field_map,
        allow_existing_atom_fields?: false,
        tag_fields?: false,
        log_prefix: "SNMPCompiler"
      )
      |> Ash.Query.distinct(:device_id)
      |> Ash.Query.load(:device)

    case Page.unwrap(Ash.read(query, actor: actor)) do
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
    filters = SRQLDeviceMatcher.extract_filters(ast)

    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> SRQLDeviceMatcher.apply_filters(filters,
        field_mappings: @device_field_map,
        allow_existing_atom_fields?: false,
        tag_fields?: true,
        log_prefix: "SNMPCompiler"
      )

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, devices} ->
        devices

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to query devices - #{inspect(reason)}")
        []
    end
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

    case Page.unwrap(Ash.read(query, actor: actor)) do
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
      # If device has a management device, use its IP for polling
      host = resolve_polling_host(device, actor)

      if missing_host?(host) do
        Logger.debug("SNMPCompiler: skipping device #{device.uid} (no IP or hostname)")
        nil
      else
        compile_device_target_with_host(device, profile, oids, actor, host)
      end
    end
  end

  defp resolve_polling_host(%{management_device_id: mgmt_id} = device, actor)
       when is_binary(mgmt_id) and mgmt_id != "" do
    query =
      Device
      |> Ash.Query.filter(uid == ^mgmt_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.limit(1)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, [mgmt_device | _]} ->
        mgmt_ip = mgmt_device.ip || mgmt_device.hostname

        if missing_host?(mgmt_ip) do
          Logger.warning(
            "SNMPCompiler: management device #{mgmt_id} for #{device.uid} has no IP, falling back to device IP"
          )

          device.ip || device.hostname
        else
          Logger.debug(
            "SNMPCompiler: using management device #{mgmt_id} IP #{mgmt_ip} for #{device.uid}"
          )

          mgmt_ip
        end

      _ ->
        Logger.warning(
          "SNMPCompiler: management device #{mgmt_id} not found for #{device.uid}, falling back to device IP"
        )

        device.ip || device.hostname
    end
  end

  defp resolve_polling_host(device, actor) do
    canonical_host = device.ip || device.hostname

    if private_ip?(device.ip) do
      device.ip
    else
      case preferred_alias_polling_host(device, actor) do
        nil -> canonical_host
        alias_host -> alias_host
      end
    end
  end

  defp preferred_alias_polling_host(%{uid: device_uid, ip: canonical_ip}, actor)
       when is_binary(device_uid) and device_uid != "" do
    aliases = load_active_ip_aliases(device_uid, actor)

    private_alias =
      aliases
      |> Enum.reject(&(&1.alias_value == canonical_ip))
      |> Enum.filter(&private_ip?(&1.alias_value))
      |> pick_best_alias_value()

    cond do
      present?(private_alias) ->
        private_alias

      missing_host?(canonical_ip) ->
        aliases
        |> Enum.reject(&missing_host?(&1.alias_value))
        |> pick_best_alias_value()

      true ->
        nil
    end
  end

  defp preferred_alias_polling_host(_device, _actor), do: nil

  defp load_active_ip_aliases(device_uid, actor) do
    case DeviceAliasState.list_active_for_device(device_uid, actor: actor) do
      {:ok, aliases} ->
        Enum.filter(aliases, &(&1.alias_type == :ip))

      {:error, reason} ->
        Logger.warning(
          "SNMPCompiler: failed to load active IP aliases for #{device_uid} - #{inspect(reason)}"
        )

        []
    end
  end

  defp pick_best_alias_value([]), do: nil

  defp pick_best_alias_value(aliases) do
    aliases
    |> Enum.max_by(&alias_preference_key/1, fn -> nil end)
    |> case do
      nil -> nil
      alias_state -> alias_state.alias_value
    end
  end

  defp alias_preference_key(alias_state) do
    {
      alias_state_state_rank(alias_state.state),
      alias_state.sighting_count || 0,
      datetime_rank(alias_state.last_seen_at),
      alias_state.alias_value || ""
    }
  end

  defp alias_state_state_rank(:updated), do: 3
  defp alias_state_state_rank(:confirmed), do: 3
  defp alias_state_state_rank(:detected), do: 2
  defp alias_state_state_rank(_), do: 0

  defp datetime_rank(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp datetime_rank(_), do: 0

  defp private_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> private_ip_tuple?(tuple)
      {:error, _} -> false
    end
  end

  defp private_ip?(_), do: false

  defp private_ip_tuple?({10, _, _, _}), do: true
  defp private_ip_tuple?({127, _, _, _}), do: true
  defp private_ip_tuple?({169, 254, _, _}), do: true
  defp private_ip_tuple?({192, 168, _, _}), do: true
  defp private_ip_tuple?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip_tuple?({0, _, _, _}), do: true
  defp private_ip_tuple?({_, _, _, _}), do: false
  defp private_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip_tuple?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip_tuple?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip_tuple?(_), do: false

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
      "version" => ProtocolFormatter.version(version),
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

    case Page.unwrap(Ash.read(query, actor: actor)) do
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
      |> ensure_packet_counter_oids()

    if oids == [] do
      nil
    else
      base_target = %{
        "id" => target.id,
        "name" => target.name,
        "host" => target.host,
        "port" => target.port,
        "version" => ProtocolFormatter.version(target.version),
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

  # Backfill packet counter OIDs at compile time so existing interface selections that
  # only persisted octet counters begin emitting packet metrics without manual edits.
  defp ensure_packet_counter_oids(oids) when is_list(oids) do
    additions =
      oids
      |> Enum.map(&derive_packet_oid/1)
      |> Enum.reject(&is_nil/1)

    (oids ++ additions)
    |> Enum.reduce(%{}, fn oid, acc ->
      key = "#{Map.get(oid, "name")}::#{Map.get(oid, "oid")}"
      Map.put_new(acc, key, oid)
    end)
    |> Map.values()
  end

  defp derive_packet_oid(%{"name" => name, "oid" => oid})
       when is_binary(name) and is_binary(oid) do
    with {base_oid, if_index} <- split_oid_index(oid),
         packet_name when is_binary(packet_name) <- packet_metric_name(name),
         packet_base when is_binary(packet_base) <- packet_metric_base_oid(base_oid) do
      %{
        "oid" => "#{packet_base}.#{if_index}",
        "name" => packet_name,
        "data_type" => "counter",
        "scale" => 1.0,
        "delta" => true
      }
    else
      _ -> nil
    end
  end

  defp derive_packet_oid(_), do: nil

  defp split_oid_index(oid) when is_binary(oid) do
    oid = String.trim(oid)

    case Regex.run(~r/^(.*)\.(\d+)$/, oid) do
      [_, base, idx] ->
        case Integer.parse(idx) do
          {if_index, ""} -> {base, if_index}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp packet_metric_name(name) do
    cond do
      String.starts_with?(name, "ifInOctets") ->
        String.replace_prefix(name, "ifInOctets", "ifInUcastPkts")

      String.starts_with?(name, "ifOutOctets") ->
        String.replace_prefix(name, "ifOutOctets", "ifOutUcastPkts")

      String.starts_with?(name, "ifHCInOctets") ->
        String.replace_prefix(name, "ifHCInOctets", "ifHCInUcastPkts")

      String.starts_with?(name, "ifHCOutOctets") ->
        String.replace_prefix(name, "ifHCOutOctets", "ifHCOutUcastPkts")

      true ->
        nil
    end
  end

  defp packet_metric_base_oid(base_oid) do
    cond do
      String.ends_with?(base_oid, ".1.3.6.1.2.1.2.2.1.10") ->
        ".1.3.6.1.2.1.2.2.1.11"

      String.ends_with?(base_oid, ".1.3.6.1.2.1.2.2.1.16") ->
        ".1.3.6.1.2.1.2.2.1.17"

      String.ends_with?(base_oid, ".1.3.6.1.2.1.31.1.1.1.6") ->
        ".1.3.6.1.2.1.31.1.1.1.7"

      String.ends_with?(base_oid, ".1.3.6.1.2.1.31.1.1.1.10") ->
        ".1.3.6.1.2.1.31.1.1.1.11"

      true ->
        nil
    end
  end

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
      "security_level" => ProtocolFormatter.security_level(Map.get(credential, :security_level)),
      "auth_protocol" =>
        ProtocolFormatter.auth_protocol(Map.get(credential, :auth_protocol), style: :hyphenated),
      "auth_password" => Map.get(credential, :auth_password),
      "priv_protocol" =>
        ProtocolFormatter.priv_protocol(Map.get(credential, :priv_protocol), style: :hyphenated),
      "priv_password" => Map.get(credential, :priv_password)
    }
  end

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
