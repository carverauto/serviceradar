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

  # Mirrors maxTargetNameLength in go/pkg/agent/snmp/config.go. A name over the
  # bound is rejected by the agent, so it is enforced here where the name is
  # built rather than discovered at the far end.
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceLifecycle
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLQuery

  require Ash.Query
  require Logger

  @max_target_name_length 128

  @impl true
  def config_type, do: :snmp

  @impl true
  def source_resources do
    [SNMPProfile, SNMPOIDTemplate, SNMPTarget, SNMPOIDConfig, Device]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:snmp_compiler)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device.
    #
    # agent_id gates *profile selection*: when a profile pins agent_ids, only
    # the listed agents resolve it; everyone else falls through to disabled
    # config below. When agent_ids is empty, behavior is unchanged (legacy
    # target_query + is_default fallback).
    profile = resolve_profile(device_uid, agent_id, actor)

    if profile && profile.enabled do
      config = compile_profile(profile, actor, agent_id: agent_id, partition: partition)
      publish_duplicate_polling_warning(profile, config)
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

  `agent_id` gates which profiles apply: a profile that pins `agent_ids` is only
  a candidate for the listed agents. An empty `agent_ids` keeps legacy behavior
  (the profile applies to all agents and `target_query`/`is_default` decide).
  """
  @spec resolve_profile(String.t() | nil, String.t() | nil, map()) :: SNMPProfile.t() | nil
  def resolve_profile(device_uid, agent_id, actor) do
    TargetedProfileResolver.resolve(device_uid, actor,
      resolver: fn device_uid, actor ->
        SrqlTargetResolver.resolve_for_device(device_uid, agent_id, actor)
      end,
      default_resolver: fn actor -> get_default_profile(agent_id, actor) end,
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
  @spec compile_profile(SNMPProfile.t(), map(), keyword()) :: map()
  def compile_profile(profile, actor, opts \\ []) do
    # 1. Load explicit targets (from interface selection or profile overrides)
    profile_targets = load_profile_targets(profile, actor, opts)

    # 2. Execute target_query to find matching devices
    target_query = normalize_target_query(profile.target_query, profile.is_default)
    devices = execute_target_query(target_query, actor)

    # 3. Load OIDs from profile's templates
    oids = load_template_oids(profile.oid_template_ids, actor)

    # 4. Build target config for each device (only when templates are present)
    query_targets =
      devices
      |> Enum.map(fn device -> compile_device_target(device, profile, oids, actor, opts) end)
      |> Enum.reject(&is_nil/1)

    compiled_targets =
      profile_targets
      |> merge_targets(query_targets)
      |> sort_targets()
      |> sanitize_target_names()

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
    "is_active" => :is_active,
    "active" => :is_active,
    "is_managed" => :is_managed,
    "managed" => :is_managed,
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
        default_active?: false,
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
        |> Enum.filter(&DeviceLifecycle.active?(&1.uid, actor: actor))
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
    query = Ash.Query.filter(SNMPOIDTemplate, id in ^template_ids)

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
  defp compile_device_target(device, profile, oids, actor, opts) do
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
        compile_device_target_with_host(device, profile, oids, actor, host, opts)
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

  defp compile_device_target_with_host(device, profile, oids, actor, host, opts) do
    credential = resolve_device_credentials(device.uid, profile, actor, opts)

    case credential do
      {:error, reason} ->
        Logger.warning(
          "SNMPCompiler: skipping device #{device.uid} because credential resolution failed - #{inspect(reason)}"
        )

        nil

      credential when is_map(credential) ->
        if valid_credentials?(credential) do
          version = Map.get(credential, :version, profile.version)
          base_target = build_base_target(device, host, profile, oids, version)
          apply_snmp_auth(base_target, version, credential)
        else
          Logger.debug("SNMPCompiler: skipping device #{device.uid} (missing credentials)")
          nil
        end

      _ ->
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
    oids
    |> Enum.map(&compile_oid/1)
    |> Enum.reject(&is_nil/1)
    |> sort_oids()
  end

  defp compile_oid(oid) when is_map(oid) do
    compiled = %{
      "oid" => oid_field(oid, "oid"),
      "name" => oid_field(oid, "name"),
      "data_type" => to_string(oid_field(oid, "data_type", "gauge")),
      "scale" => oid_field(oid, "scale", 1.0),
      "delta" => oid_field(oid, "delta", false)
    }

    case normalize_oid_mode(oid_field(oid, "mode")) do
      "walk" ->
        compiled
        |> Map.put("mode", "walk")
        |> maybe_put_positive_int("max_rows", oid_field(oid, "max_rows"))
        |> maybe_put_positive_int("walk_timeout_seconds", oid_walk_timeout_seconds(oid))

      _ ->
        compiled
    end
  end

  defp compile_oid(_), do: nil

  defp oid_field(oid, key, default \\ nil) do
    Map.get(oid, key, Map.get(oid, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(oid, key, default)
  end

  defp normalize_oid_mode(mode) when mode in [:walk, "walk"], do: "walk"
  defp normalize_oid_mode(_), do: "get"

  defp oid_walk_timeout_seconds(oid) do
    case oid_field(oid, "walk_timeout_seconds") || oid_field(oid, "walk_timeout") do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      seconds when is_float(seconds) and seconds > 0 -> trunc(seconds)
      binary when is_binary(binary) -> parse_timeout_seconds(binary)
      _ -> nil
    end
  end

  defp parse_timeout_seconds(binary) when is_binary(binary) do
    trimmed = binary |> String.trim() |> String.trim_trailing("s")

    case Integer.parse(trimmed) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp maybe_put_positive_int(map, _key, value) when not is_integer(value) or value <= 0, do: map
  defp maybe_put_positive_int(map, key, value), do: Map.put(map, key, value)

  defp load_profile_targets(profile, actor, opts) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile.id)
      |> Ash.Query.load(:oid_configs)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, targets} ->
        targets
        |> Enum.sort_by(&target_sort_key/1)
        |> Enum.map(&compile_profile_target(&1, profile, actor, opts))
        |> Enum.reject(&is_nil/1)
        |> sort_targets()

      {:error, reason} ->
        Logger.warning("SNMPCompiler: failed to load profile targets - #{inspect(reason)}")
        []
    end
  end

  defp compile_profile_target(%SNMPTarget{} = target, profile, actor, opts) do
    oids =
      target.oid_configs
      |> Enum.map(&oid_config_to_map/1)
      |> Enum.reject(&is_nil/1)
      |> ensure_packet_counter_oids()

    if oids == [] do
      nil
    else
      credential =
        case CredentialResolver.resolve_for_host(target.host, actor, opts) do
          {:ok, %{credential: rule_cred, source: :credential_rule}} when is_map(rule_cred) ->
            rule_cred

          _ ->
            CredentialResolver.build_credential(target, actor,
              consumer_id: "snmp_target:#{target.id}",
              target_kind: "snmp_target",
              target_id: target.id
            )
        end

      version =
        if is_map(credential),
          do: Map.get(credential, :version, target.version),
          else: target.version

      base_target = %{
        "id" => target.id,
        "name" => target.name,
        "host" => target.host,
        "port" => target.port,
        "version" => ProtocolFormatter.version(version),
        "poll_interval_seconds" => profile.poll_interval,
        "timeout_seconds" => profile.timeout,
        "retries" => profile.retries,
        "oids" => compile_oids(oids)
      }

      case credential do
        {:error, reason} ->
          Logger.warning(
            "SNMPCompiler: skipping target #{target.id} because credential resolution failed - #{inspect(reason)}"
          )

          nil

        credential when is_map(credential) ->
          if valid_credentials?(credential) do
            apply_snmp_auth(base_target, version, credential)
          else
            Logger.debug("SNMPCompiler: skipping target #{target.id} (missing credentials)")
            nil
          end

        _ ->
          Logger.debug("SNMPCompiler: skipping target #{target.id} (missing credentials)")
          nil
      end
    end
  end

  defp compile_profile_target(_, _, _, _), do: nil

  defp oid_config_to_map(%SNMPOIDConfig{} = oid) do
    %{
      "oid" => oid.oid,
      "name" => oid.name,
      "data_type" => to_string(oid.data_type),
      "scale" => oid.scale || 1.0,
      "delta" => oid.delta || false,
      "mode" => oid.mode,
      "max_rows" => oid.max_rows,
      "walk_timeout_seconds" => oid.walk_timeout_seconds
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
    |> sort_oids()
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

  defp merge_targets(primary, secondary) do
    (primary ++ secondary)
    |> Enum.reduce(%{}, fn target, acc ->
      key =
        Map.get(target, "host") ||
          Map.get(target, "name") ||
          Map.get(target, "id") ||
          Ecto.UUID.generate()

      Map.put_new(acc, key, target)
    end)
    |> Map.values()
  end

  defp sort_targets(targets) when is_list(targets) do
    Enum.sort_by(targets, &target_sort_key/1)
  end

  @doc """
  Rewrites compiled target names into the form the agent will accept.

  The agent admits only `[A-Za-z0-9_-]` in a target name, caps it at 128 bytes,
  and rejects duplicates (`isValidNameChar` and `validateTargetName` in
  `go/pkg/agent/snmp/config.go`). Target names here come from
  `device.name || device.hostname || device.uid`, none of which is constrained
  that way: every FQDN-named device carries dots and a device uid carries
  colons.

  This is public because it encodes a contract defined in another language in
  another directory, and that contract is worth being able to state and test
  directly rather than only through a compile.
  """
  @spec sanitize_target_names([map()]) :: [map()]
  def sanitize_target_names(targets) when is_list(targets) do
    targets
    |> Enum.map_reduce(MapSet.new(), fn target, seen ->
      name = target |> Map.get("name") |> sanitize_target_name(Map.get(target, "id"))

      name =
        if MapSet.member?(seen, name),
          do: disambiguate_target_name(name, Map.get(target, "id")),
          else: name

      {Map.put(target, "name", name), MapSet.put(seen, name)}
    end)
    |> elem(0)
  end

  # Falls back when the scrubbed name carries no alphanumeric character at all,
  # not merely when it is empty. A name of "..." scrubs to "___", which the
  # agent accepts but which identifies nothing to an operator reading target
  # status - and every such device scrubs to the same string.
  defp sanitize_target_name(name, id) do
    scrubbed = scrub_target_name(name)

    if meaningful_target_name?(scrubbed) do
      scrubbed
    else
      id |> scrub_target_name() |> fallback_target_name(scrubbed)
    end
  end

  defp meaningful_target_name?(value), do: String.match?(value, ~r/[A-Za-z0-9]/)

  defp scrub_target_name(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    |> String.slice(0, @max_target_name_length)
  end

  defp scrub_target_name(_value), do: ""

  defp fallback_target_name(from_id, last_resort) do
    cond do
      meaningful_target_name?(from_id) -> from_id
      last_resort != "" -> last_resort
      true -> "target"
    end
  end

  # Sanitizing can map two distinct devices onto one name (`a.b` and `a_b` both
  # become `a_b`), and the agent keys collectors, aggregators, and status by
  # target name - so a collision silently drops one device's polling rather than
  # erroring. The suffix is derived from the device uid so it stays stable
  # across compiles instead of shifting with list position.
  defp disambiguate_target_name(name, id) do
    suffix = id |> to_string() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    base = String.slice(name, 0, @max_target_name_length - 9)

    base <> "_" <> String.slice(suffix, 0, 8)
  end

  defp sort_oids(oids) when is_list(oids) do
    Enum.sort_by(oids, fn oid ->
      {Map.get(oid, "name", ""), Map.get(oid, "oid", "")}
    end)
  end

  defp target_sort_key(target) do
    {
      Map.get(target, "host", ""),
      Map.get(target, "name", ""),
      Map.get(target, "id", "")
    }
  end

  # Resolve credentials: device override → profile fallback
  defp resolve_device_credentials(device_uid, profile, actor, opts) do
    case CredentialResolver.resolve_for_device(device_uid, actor, opts) do
      {:ok, %{credential: credential}} when is_map(credential) ->
        credential

      {:error, reason} ->
        {:error, reason}

      _ ->
        CredentialResolver.build_credential(profile, actor,
          consumer_id: profile && "snmp_profile:#{profile.id}",
          target_kind: "snmp_profile",
          target_id: profile && profile.id
        )
    end
  end

  # Check if credentials are valid for SNMP connection
  defp valid_credentials?(credential) when is_map(credential) do
    case Map.get(credential, :version, :v2c) do
      :v3 ->
        present?(Map.get(credential, :username)) and
          valid_v3_secrets?(credential)

      _ ->
        present?(Map.get(credential, :community))
    end
  end

  defp valid_v3_secrets?(credential) do
    case Map.get(credential, :security_level) do
      :auth_priv ->
        present?(Map.get(credential, :auth_password)) and
          present?(Map.get(credential, :priv_password))

      :auth_no_priv ->
        present?(Map.get(credential, :auth_password))

      _ ->
        true
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

  @doc """
  Returns the concrete target/agent overlap that would make one SNMP profile
  poll the same target from more than one agent, or `nil` when it is safe.

  This is deliberately a warning surface rather than a validation failure: an
  operator may be performing a controlled handoff, but continuous overlap
  creates duplicate metric and anomaly producers.
  """
  @spec duplicate_polling_warning(map(), map()) :: map() | nil
  def duplicate_polling_warning(profile, config) when is_map(profile) and is_map(config) do
    agent_uids =
      profile
      |> Map.get(:agent_ids, Map.get(profile, "agent_ids", []))
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    target_uids =
      config
      |> Map.get("targets", [])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    # A compiler invocation only knows this profile's declared assignments.
    # An empty list means "all agents", but it does not prove more than one
    # agent is enrolled; warning in that case produces a false duplicate alarm
    # for a single-agent deployment. Emit only for a concrete multi-agent
    # overlap, which this function can establish from its inputs.
    if target_uids != [] and length(agent_uids) > 1 do
      %{
        profile_id: Map.get(profile, :id, Map.get(profile, "id")),
        profile_name: Map.get(profile, :name, Map.get(profile, "name")),
        agent_scope: if(agent_uids == [], do: :all_agents, else: :pinned_agents),
        agent_uids: agent_uids,
        target_count: length(target_uids)
      }
    end
  end

  def duplicate_polling_warning(_profile, _config), do: nil

  defp publish_duplicate_polling_warning(profile, config) do
    case duplicate_polling_warning(profile, config) do
      nil ->
        :ok

      warning ->
        :telemetry.execute(
          [:serviceradar, :snmp, :config_hygiene],
          %{
            duplicate_targets: warning.target_count,
            duplicate_agents: length(warning.agent_uids)
          },
          warning
        )

        Logger.warning("SNMP profile assigns the same targets to multiple agents",
          profile_id: warning.profile_id,
          profile_name: warning.profile_name,
          agent_scope: warning.agent_scope,
          agent_uids: warning.agent_uids,
          target_count: warning.target_count
        )

        :ok
    end
  end

  # Get the default profile, gated by agent_ids.
  #
  # The :get_default read intentionally has no agent filter (it is the
  # all-agents fallback). We apply the agent_ids gate here, after the read, so
  # the read action stays usable by other call sites (e.g. web-ng set_default):
  #
  #   - agent_ids == []         => default applies to all agents (legacy)
  #   - agent_id in agent_ids   => default applies to this agent
  #   - otherwise               => nil (caller falls through to disabled_config)
  defp get_default_profile(agent_id, actor) do
    query = Ash.Query.for_read(SNMPProfile, :get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, profile} ->
        if profile_applies_to_agent?(profile, agent_id), do: profile

      {:error, _} ->
        nil
    end
  end

  @doc """
  Returns true when a profile applies to the given agent.

  A profile with an empty `agent_ids` applies to every agent (legacy behavior).
  A profile with a non-empty `agent_ids` applies only to the listed agent UIDs.
  """
  @spec profile_applies_to_agent?(SNMPProfile.t() | map() | nil, String.t() | nil) :: boolean()
  def profile_applies_to_agent?(%{agent_ids: agent_ids}, agent_id) when is_list(agent_ids) do
    agent_ids == [] or (is_binary(agent_id) and agent_id in agent_ids)
  end

  def profile_applies_to_agent?(_profile, _agent_id), do: true
end
