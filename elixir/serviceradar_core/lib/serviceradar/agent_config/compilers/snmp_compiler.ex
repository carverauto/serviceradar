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

  The default `:legacy` config contains the SNMP payload below plus a deterministic
  `config_hash` computed by `config_hash/1`, including for disabled configs.
  The hash is internal cache/version metadata and is not a proto SNMPConfig field.

  Compilation accepts `:format` (or its alias `:snmp_format`) with values
  `:legacy` and `:shared_oids_v1`; `:format` takes precedence when both are set.
  The shared representation is described by `shared_oids_document/1`.
  When no enabled profile resolves, compilation still returns the legacy-shaped
  disabled config regardless of the requested format.

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
  alias Ash.Error.Invalid
  alias Ash.Page.Keyset
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver
  alias ServiceRadar.AgentConfig.WarningLedger
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.SNMPProfiles.TargetLimit
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.SRQLQuery

  require Ash.Query
  require Logger

  @max_target_name_length 128

  # A target query can match the whole inventory, and a compile runs inside a
  # heap-capped invalidation worker. Devices are therefore read one page at a
  # time with only these columns, and a page is released before the next one is
  # read, so the live rows never exceed one page whatever the inventory size.
  # Everything looked up for a device (its polling host, its credentials) is
  # read for the whole page at once, so a page costs a fixed number of queries.
  @target_device_fields [:uid, :name, :hostname, :ip, :management_device_id]
  @target_device_page_size 250

  @impl true
  def config_type, do: :snmp

  @impl true
  def source_resources do
    [SNMPProfile, SNMPOIDTemplate, SNMPTarget, SNMPOIDConfig, Device]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    if repo_ready?() do
      do_compile(partition, agent_id, opts)
    else
      {:error, :repo_unavailable}
    end
  rescue
    e ->
      Logger.error("SNMPCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  defp do_compile(partition, agent_id, opts) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:snmp_compiler)
    device_uid = opts[:device_uid]
    format = resolve_format_opt(opts)

    with :ok <- validate_format(format) do
      # Resolve the profile for this agent/device.
      #
      # agent_id gates *profile selection*: when a profile pins agent_ids, only
      # the listed agents resolve it; everyone else falls through to disabled
      # config below. When agent_ids is empty, behavior is unchanged (legacy
      # target_query + is_default fallback).
      case fetch_profile(device_uid, agent_id, actor) do
        {:ok, %{enabled: true} = profile} ->
          case compile_profile(profile, actor,
                 agent_id: agent_id,
                 partition: partition,
                 format: format
               ) do
            {:ok, config} ->
              publish_duplicate_polling_warning(profile, config)
              {:ok, config}

            {:error, reason} ->
              # A failed target, template, or profile-target read is not an empty
              # config. ConfigServer caches every {:ok, _}, so returning one here
              # would make agents poll nothing until the next :snmp invalidation.
              Logger.error("SNMPCompiler: failed to compile profile - #{inspect(reason)}")
              {:error, reason}
          end

        {:ok, _no_enabled_profile} ->
          # Return disabled config if no profile found or profile is disabled
          {:ok, disabled_config()}

        # A failed profile read is not "no profile": returning the disabled
        # config here would be cached by ConfigServer as this agent's SNMP config.
        {:error, reason} ->
          {:error, {:profile_resolution_failed, reason}}
      end
    end
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

  Returns the matching SNMPProfile, or nil when no profile matches or the
  profiles could not be read (`compile/3` treats the latter as an error).

  `agent_id` gates which profiles apply: a profile that pins `agent_ids` is only
  a candidate for the listed agents. An empty `agent_ids` keeps legacy behavior
  (the profile applies to all agents and `target_query`/`is_default` decide).
  """
  @spec resolve_profile(String.t() | nil, String.t() | nil, map()) :: SNMPProfile.t() | nil
  def resolve_profile(device_uid, agent_id, actor) do
    if repo_ready?() do
      case fetch_profile(device_uid, agent_id, actor) do
        {:ok, profile} ->
          profile

        {:error, reason} ->
          Logger.warning("SNMPCompiler: profile resolution failed - #{inspect(reason)}")
          nil
      end
    end
  end

  defp fetch_profile(device_uid, agent_id, actor) do
    TargetedProfileResolver.resolve(device_uid, actor,
      resolver: fn device_uid, actor ->
        SrqlTargetResolver.resolve_for_device(device_uid, agent_id, actor)
      end,
      default_resolver: fn actor -> get_default_profile(agent_id, actor) end,
      log_prefix: "SNMPCompiler"
    )
  end

  @doc """
  Finds the reporter and every profile poller consuming a device's SNMP config.

  Query matching uses the compiler's own filters, restricted to this device.
  Unknown ownership and legacy profiles applying to all agents retain a fleet push.
  """
  @spec affected_agents_for_device(String.t()) :: [String.t()] | :all_online
  def affected_agents_for_device(device_uid) do
    if repo_ready?() do
      do_affected_agents_for_device(device_uid)
    else
      :all_online
    end
  end

  defp do_affected_agents_for_device(device_uid) do
    actor = SystemActor.system(:snmp_config_invalidation)

    with {:ok, %Device{} = device} <- Device.get_by_uid(device_uid, false, actor: actor),
         {:ok, polling_hosts} <- resolve_polling_hosts([device], actor) do
      polling_host = Map.fetch!(polling_hosts, device.uid)

      interface_hosts =
        Interface
        |> Ash.Query.filter(device_id == ^device_uid)
        |> Ash.Query.sort([:timestamp, :device_id, :interface_uid])
        |> Page.stream!(actor: actor, allow_stream_with: :offset)
        |> Enum.map(& &1.device_ip)

      hosts = [device.ip, device.hostname, polling_host | interface_hosts]

      explicit_profiles =
        SNMPTarget
        |> Ash.Query.filter(host in ^Enum.reject(hosts, &is_nil/1))
        |> Ash.Query.select(:snmp_profile_id)
        |> Ash.read!(actor: actor)
        |> MapSet.new(& &1.snmp_profile_id)

      reporter =
        if is_binary(device.agent_id) and device.agent_id != "", do: [device.agent_id], else: []

      SNMPProfile
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.select([:agent_ids, :target_query, :is_default])
      |> Ash.Query.sort(:id)
      |> Page.stream!(actor: actor, allow_stream_with: :offset)
      |> Enum.reduce_while(reporter, fn profile, agents ->
        case profile_consumes_device?(profile, device_uid, explicit_profiles, actor) do
          {:ok, false} -> {:cont, agents}
          {:ok, true} when profile.agent_ids == [] -> {:halt, :all_online}
          {:ok, true} -> {:cont, Enum.uniq(profile.agent_ids ++ agents)}
          {:error, _reason} -> {:halt, :all_online}
        end
      end)
      |> case do
        [] -> :all_online
        agents -> agents
      end
    else
      _ -> :all_online
    end
  rescue
    error ->
      Logger.warning("SNMP ownership lookup failed: #{Exception.message(error)}")
      :all_online
  end

  defp profile_consumes_device?(profile, device_uid, explicit_profiles, actor) do
    if MapSet.member?(explicit_profiles, profile.id) do
      {:ok, true}
    else
      profile_query_consumes_device?(profile, device_uid, actor)
    end
  end

  defp profile_query_consumes_device?(profile, device_uid, actor) do
    case normalize_target_query(profile.target_query, profile.is_default) do
      nil ->
        {:ok, false}

      query ->
        with {:ok, ast} <- SRQLAst.parse(query) do
          entity = SRQLAst.entity(query)
          field = if entity == "interfaces", do: "device_id", else: "uid"
          filter = %{"field" => field, "op" => "eq", "value" => device_uid}
          ast = Map.update(ast, "filters", [filter], &(&1 ++ [filter]))

          reduce_parsed_pages(entity, ast, actor, false, fn devices, _found? ->
            {:halt, Enum.any?(devices, &(&1.uid == device_uid))}
          end)
        end
    end
  end

  @doc """
  Compiles a profile to the agent config format using SRQL-based targeting.

  A failed read of profile targets, the target query, or OID templates
  returns `{:error, reason}` so the caller does not cache an empty config.
  A zero-row read still compiles a valid config with an empty target list.

  1. Load explicit profile targets
  2. Execute target_query to find matching devices
  3. Load OIDs from profile's oid_template_ids
  4. For each device, build target config with resolved credentials
  """
  @spec compile_profile(SNMPProfile.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compile_profile(profile, actor, opts \\ []) do
    if repo_ready?() do
      do_compile_profile(profile, actor, opts)
    else
      {:error, :repo_unavailable}
    end
  end

  defp do_compile_profile(profile, actor, opts) do
    format = resolve_format_opt(opts)
    agent_id = Keyword.get(opts, :agent_id)

    with :ok <- validate_format(format) do
      case TargetLimit.check(profile, agent_id, Keyword.get(opts, :partition)) do
        :ok ->
          WarningLedger.forget({:snmp_target_limit, profile.id, agent_id})
          compile_profile_targets(profile, actor, opts, format)

        # A profile over the limit is refused whole: it contributes no targets
        # and the agent's config still compiles. Cutting it down to the limit
        # would poll an arbitrary subset.
        {:refused, refusal} ->
          report_target_limit_refusal(refusal)
          {:ok, profile_config(profile, [], format)}

        {:error, reason} ->
          {:error, {:target_limit_read_failed, reason}}
      end
    end
  end

  defp compile_profile_targets(profile, actor, opts, format) do
    with {:ok, profile_targets} <- load_profile_targets(profile, actor, opts),
         {:ok, oids} <- load_template_oids(profile.oid_template_ids, actor),
         {:ok, query_targets} <-
           compile_query_targets(target_query(profile), profile, oids, actor, opts) do
      compiled_targets =
        profile_targets
        |> merge_targets(query_targets)
        |> sort_targets()
        |> sanitize_target_names()

      {:ok, profile_config(profile, compiled_targets, format)}
    end
  end

  defp profile_config(profile, compiled_targets, format) do
    config =
      format_compiled_config(
        %{
          "enabled" => profile.enabled and compiled_targets != [],
          "profile_id" => profile.id,
          "profile_name" => profile.name,
          "targets" => compiled_targets
        },
        format
      )

    Map.put(config, "config_hash", config_hash(config))
  end

  # The counter fires on every compile of a refused profile. The log line is
  # written when the refusal starts or its numbers change, not on every compile.
  defp report_target_limit_refusal(refusal) do
    :telemetry.execute(
      [:serviceradar, :snmp, :target_limit_exceeded],
      %{count: 1, targets: refusal.count, limit: refusal.limit},
      Map.take(refusal, [:profile_id, :profile_name, :agent_id])
    )

    subject = {:snmp_target_limit, refusal.profile_id, refusal.agent_id}

    if WarningLedger.changed?(subject, {refusal.count, refusal.limit}) do
      Logger.warning("SNMPCompiler: " <> TargetLimit.message(refusal))
    end
  end

  @doc """
  The target query a profile is compiled with: its own, `in:devices` for a
  default profile that sets none, or `nil` when it selects no devices.
  """
  @spec target_query(map()) :: String.t() | nil
  def target_query(profile) do
    normalize_target_query(Map.get(profile, :target_query), Map.get(profile, :is_default) == true)
  end

  @doc """
  Transforms a legacy compiled SNMP config map into the `shared-oids/v1` format.

  Deduplicates per-target `oids` lists into a deterministic top-level `oid_sets`
  table (`[%{"key" => "oids-...", "oids" => [...]}]`, sorted by `key`). Keys
  contain `oids-` followed by the first 16 hex characters of the OID content hash.
  Non-empty target OID lists become `"oid_set" => key`; empty lists are removed
  without a reference. The document includes `"format" => "shared-oids/v1"`
  and recomputes `config_hash` if the input contained it.
  """
  @spec shared_oids_document(map()) :: map()
  def shared_oids_document(config) when is_map(config) do
    targets = Map.get(config, "targets", [])

    {shared_targets, sets_by_key} =
      Enum.map_reduce(targets, %{}, fn target, acc ->
        case Map.get(target, "oids", []) do
          [_ | _] = oids ->
            key = oid_set_key(oids)
            shared_target = target |> Map.delete("oids") |> Map.put("oid_set", key)
            {shared_target, Map.put_new(acc, key, %{"key" => key, "oids" => oids})}

          _ ->
            {Map.delete(target, "oids"), acc}
        end
      end)

    oid_sets =
      sets_by_key
      |> Map.values()
      |> Enum.sort_by(& &1["key"])

    base = %{
      "format" => "shared-oids/v1",
      "enabled" => Map.get(config, "enabled", false),
      "profile_id" => Map.get(config, "profile_id"),
      "profile_name" => Map.get(config, "profile_name"),
      "oid_sets" => oid_sets,
      "targets" => shared_targets
    }

    if Map.has_key?(config, "config_hash") do
      Map.put(base, "config_hash", config_hash(base))
    else
      base
    end
  end

  defp oid_set_key(oids) do
    "oids-" <> (%{"oids" => oids} |> Compiler.content_hash() |> String.slice(0, 16))
  end

  defp resolve_format_opt(opts) when is_list(opts) do
    Keyword.get(opts, :format, Keyword.get(opts, :snmp_format, :legacy))
  end

  defp validate_format(format) when format in [:legacy, :shared_oids_v1], do: :ok
  defp validate_format(format), do: {:error, {:unsupported_snmp_format, format}}

  defp format_compiled_config(config, :legacy), do: config
  defp format_compiled_config(config, :shared_oids_v1), do: shared_oids_document(config)

  @doc """
  Computes a deterministic config hash for a compiled SNMP config.
  """
  @spec config_hash(map()) :: String.t()
  def config_hash(config) when is_map(config) do
    config
    |> Map.delete("config_hash")
    |> Map.delete(:config_hash)
    |> Compiler.content_hash()
  end

  # A device whose read failed is not a device to skip: skipping every device
  # on a credential or alias outage compiles an empty target list that
  # ConfigServer would cache. The error fails the compile instead.
  #
  # A profile without OIDs yields no query target for any device. The first
  # page is still read, so a failed device read fails the compile, and the
  # reduction stops there instead of walking the inventory for nothing.
  defp compile_query_targets(target_query, profile, oids, actor, opts) do
    compiled_oids = compile_oids(oids)

    # The pages of one compile are one resolution pass: a brokered credential
    # is audited once for the pass, not once per device.
    opts
    |> Keyword.take([:agent_id, :partition])
    |> CredentialResolver.with_bulk_audit(fn bulk_audit ->
      opts = Keyword.put(opts, :bulk_audit, bulk_audit)

      reduce_target_pages(target_query, actor, {:ok, []}, fn devices, {:ok, targets} ->
        if oids == [] do
          {:halt, {:ok, targets}}
        else
          case compile_page_targets(devices, profile, compiled_oids, actor, opts) do
            {:ok, page_targets} -> {:cont, {:ok, Enum.reverse(page_targets, targets)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)
    end)
    |> case do
      {:ok, {:ok, targets}} -> {:ok, Enum.reverse(targets)}
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Folds `fun` over the pages of devices an SRQL target_query matches.

  Handles both interface and device queries:
  - `in:interfaces ...` → the in-service devices of the matching interfaces
  - `in:devices ...` → the matched devices

  `fun` receives a non-empty page of devices and the accumulator and returns
  `{:cont, acc}` or `{:halt, acc}`. A device carries only `uid`, `name`,
  `hostname`, `ip` and `management_device_id`. Every matching device is
  visited: pages follow a keyset cursor to the end, and nothing caps how many
  are read. A page is released before the next is read, so a caller that keeps
  only what it needs from each page holds a bounded number of rows however
  many devices match.

  A nil or empty query, an unparseable query, and an uncastable filter
  return `{:ok, acc}` unchanged. A failed read returns
  `{:error, {:target_query_failed, reason}}`, and a call made before
  `ServiceRadar.Repo` has started returns `{:error, :repo_unavailable}`.
  """
  @spec reduce_target_pages(
          String.t() | nil,
          map(),
          acc,
          ([Device.t()], acc -> {:cont, acc} | {:halt, acc})
        ) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce_target_pages(target_query, _actor, acc, _fun) when target_query in [nil, ""],
    do: {:ok, acc}

  def reduce_target_pages(target_query, actor, acc, fun) when is_function(fun, 2) do
    if repo_ready?() do
      target_query = String.trim(target_query)

      case SRQLAst.parse(target_query) do
        {:ok, ast} ->
          reduce_parsed_pages(SRQLAst.entity(target_query), ast, actor, acc, fun)

        {:error, reason} ->
          Logger.warning("SNMPCompiler: failed to parse SRQL query - #{inspect(reason)}")
          {:ok, acc}
      end
    else
      {:error, :repo_unavailable}
    end
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

  # An interface query selects devices through their interfaces. The distinct
  # device ids are read a page at a time in ascending order, the cursor being
  # the last id of the previous page, and each page's devices are then read
  # together. A device is delivered when it exists, is not deleted, and is not
  # marked inactive.
  defp reduce_parsed_pages("interfaces", ast, actor, acc, fun) do
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
      |> Ash.Query.sort(device_id: :asc)
      |> Ash.Query.select([:device_id])
      |> Ash.Query.limit(@target_device_page_size)

    reduce_interface_pages(query, actor, nil, acc, fun)
  end

  defp reduce_parsed_pages(_entity, ast, actor, acc, fun) do
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
      |> Ash.Query.select(@target_device_fields)

    reduce_device_pages(query, actor, nil, acc, fun)
  end

  # Only the reads are guarded: `fun` runs outside any rescue, so a failure in
  # the caller's own work is never reported as a failed target query.
  defp reduce_device_pages(query, actor, cursor, acc, fun) do
    case read_device_page(query, actor, cursor) do
      {:ok, %Keyset{results: devices, more?: more?}} ->
        case reduce_page(devices, acc, fun) do
          {:cont, acc} when more? ->
            reduce_device_pages(query, actor, List.last(devices).__metadata__.keyset, acc, fun)

          {_cont_or_halt, acc} ->
            {:ok, acc}
        end

      {:error, reason} ->
        target_query_read_failed(reason, acc)
    end
  end

  defp read_device_page(query, actor, cursor) do
    page = [limit: @target_device_page_size]
    page = if cursor, do: Keyword.put(page, :after, cursor), else: page

    Ash.read(query, actor: actor, page: page)
  rescue
    exception -> {:error, exception}
  end

  defp reduce_interface_pages(query, actor, cursor, acc, fun) do
    with {:ok, device_ids} <- read_interface_device_ids(query, actor, cursor),
         {:ok, devices} <- read_in_service_devices(device_ids, actor) do
      more? = length(device_ids) == @target_device_page_size

      case reduce_page(devices, acc, fun) do
        {:cont, acc} when more? ->
          reduce_interface_pages(query, actor, List.last(device_ids), acc, fun)

        {_cont_or_halt, acc} ->
          {:ok, acc}
      end
    else
      {:error, reason} -> target_query_read_failed(reason, acc)
    end
  end

  defp read_interface_device_ids(query, actor, cursor) do
    query = if cursor, do: Ash.Query.filter(query, device_id > ^cursor), else: query

    with {:ok, interfaces} <- Ash.read(query, actor: actor) do
      {:ok, Enum.map(interfaces, & &1.device_id)}
    end
  rescue
    exception -> {:error, exception}
  end

  defp read_in_service_devices([], _actor), do: {:ok, []}

  defp read_in_service_devices(device_ids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^device_ids)
    |> Ash.Query.select([:is_active | @target_device_fields])
    |> Ash.read(actor: actor, page: [limit: length(device_ids)])
    |> case do
      {:ok, %Keyset{results: devices}} -> {:ok, Enum.reject(devices, &(&1.is_active == false))}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  # A page with no deliverable device is skipped, not handed to the caller.
  defp reduce_page([], acc, _fun), do: {:cont, acc}
  defp reduce_page(devices, acc, fun), do: fun.(devices, acc)

  defp target_query_read_failed(%Invalid{} = reason, acc) do
    Logger.warning("SNMPCompiler: invalid target query filter - #{inspect(reason)}")
    {:ok, acc}
  end

  defp target_query_read_failed(reason, _acc) do
    Logger.error("SNMPCompiler: failed to read target query devices - #{inspect(reason)}")
    {:error, {:target_query_failed, reason}}
  end

  @doc """
  Load OIDs from the selected OID templates.

  A failed template read returns `{:error, reason}` rather than an empty list.
  """
  @spec load_template_oids([String.t()] | nil, map()) ::
          {:ok, [map()]} | {:error, term()}
  def load_template_oids(nil, _actor), do: {:ok, []}
  def load_template_oids([], _actor), do: {:ok, []}

  def load_template_oids(template_ids, actor) when is_list(template_ids) do
    if repo_ready?() do
      do_load_template_oids(template_ids, actor)
    else
      {:error, :repo_unavailable}
    end
  end

  defp do_load_template_oids(template_ids, actor) do
    # Load templates from database
    query = Ash.Query.filter(SNMPOIDTemplate, id in ^template_ids)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, templates} ->
        # Flatten all OIDs from all templates
        oids =
          templates
          |> Enum.flat_map(fn template -> template.oids || [] end)
          |> Enum.uniq_by(fn oid -> Map.get(oid, "oid") end)

        {:ok, oids}

      {:error, reason} ->
        Logger.error("SNMPCompiler: failed to load OID templates - #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Compiles one page of devices. Polling hosts and credentials are resolved
  # for the whole page first, so the queries a page costs do not depend on how
  # many devices it holds; the targets are then built from those results.
  defp compile_page_targets(devices, profile, compiled_oids, actor, opts) do
    case resolve_polling_hosts(devices, actor) do
      {:ok, hosts} ->
        reachable = Enum.reject(devices, &missing_host?(Map.fetch!(hosts, &1.uid)))

        credentials =
          reachable
          |> Enum.map(& &1.uid)
          |> CredentialResolver.resolve_for_devices(
            actor,
            Keyword.put(opts, :fallback_profile, profile)
          )

        reachable
        |> Enum.reduce_while({:ok, []}, fn device, {:ok, targets} ->
          host = Map.fetch!(hosts, device.uid)
          resolution = Map.fetch!(credentials, device.uid)

          case compile_device_target(device, host, resolution, profile, compiled_oids) do
            {:ok, nil} -> {:cont, {:ok, targets}}
            {:ok, target} -> {:cont, {:ok, [target | targets]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, targets} -> {:ok, Enum.reverse(targets)}
          error -> error
        end

      {:error, reason} ->
        Logger.error("SNMPCompiler: polling host resolution failed - #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The host each device is polled on: its management device's address when it
  # has one, its own private address, or else its best active IP alias. A
  # failed management-device or alias read is not "none": silently falling back
  # would deliver a different polling host than the data selects.
  defp resolve_polling_hosts(devices, actor) do
    {managed, unmanaged} = Enum.split_with(devices, &managed?/1)
    aliased = Enum.reject(unmanaged, &private_ip?(&1.ip))

    with {:ok, management} <- load_management_devices(managed, actor),
         {:ok, aliases} <- load_active_ip_aliases(aliased, actor) do
      {:ok,
       Map.new(devices, fn device ->
         {device.uid, polling_host(device, management, Map.get(aliases, device.uid, []))}
       end)}
    end
  end

  defp managed?(%{management_device_id: mgmt_id}), do: is_binary(mgmt_id) and mgmt_id != ""
  defp managed?(_device), do: false

  defp load_management_devices([], _actor), do: {:ok, %{}}

  defp load_management_devices(managed, actor) do
    mgmt_ids = managed |> Enum.map(& &1.management_device_id) |> Enum.uniq()

    Device
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^mgmt_ids)
    |> Ash.Query.select([:uid, :ip, :hostname])
    |> Ash.read(actor: actor, page: [limit: length(mgmt_ids)])
    |> case do
      {:ok, %Keyset{results: mgmt_devices}} ->
        {:ok, Map.new(mgmt_devices, &{&1.uid, &1})}

      {:error, reason} ->
        Logger.error("SNMPCompiler: failed to load management devices - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_active_ip_aliases([], _actor), do: {:ok, %{}}

  defp load_active_ip_aliases(devices, actor) do
    device_uids = Enum.map(devices, & &1.uid)

    DeviceAliasState
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(
      device_id in ^device_uids and alias_type == :ip and
        state in [:detected, :confirmed, :updated]
    )
    |> Ash.Query.select([:device_id, :alias_value, :state, :sighting_count, :last_seen_at])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, aliases} ->
        {:ok, Enum.group_by(aliases, & &1.device_id)}

      {:error, reason} ->
        Logger.error("SNMPCompiler: failed to load active IP aliases - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp polling_host(%{management_device_id: mgmt_id} = device, management, _aliases)
       when is_binary(mgmt_id) and mgmt_id != "" do
    own_host = device.ip || device.hostname

    case Map.get(management, mgmt_id) do
      nil ->
        Logger.warning(
          "SNMPCompiler: management device #{mgmt_id} not found for #{device.uid}, falling back to device IP"
        )

        own_host

      mgmt_device ->
        mgmt_host = mgmt_device.ip || mgmt_device.hostname

        if missing_host?(mgmt_host) do
          Logger.warning(
            "SNMPCompiler: management device #{mgmt_id} for #{device.uid} has no IP, falling back to device IP"
          )

          own_host
        else
          mgmt_host
        end
    end
  end

  defp polling_host(device, _management, aliases) do
    if private_ip?(device.ip) do
      device.ip
    else
      preferred_alias_host(device.ip, aliases) || device.ip || device.hostname
    end
  end

  defp preferred_alias_host(canonical_ip, aliases) do
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

  # A failed credential read fails the compile so ConfigServer does not cache a
  # target list that dropped every device. A SecretBroker policy refusal is
  # deterministic: skipping that device stays the behavior.
  defp compile_device_target(device, host, resolution, profile, compiled_oids) do
    case resolution do
      {:error, reason} ->
        if CredentialResolver.credential_read_failure?(reason) do
          Logger.error(
            "SNMPCompiler: device #{device.uid} credential read failed - #{inspect(reason)}"
          )

          {:error, {:credential_resolution_failed, reason}}
        else
          log_credential_refusal("device", device.uid, reason)
          {:ok, nil}
        end

      {:ok, %{credential: credential}} when is_map(credential) ->
        if valid_credentials?(credential) do
          version = Map.get(credential, :version, profile.version)
          base_target = build_base_target(device, host, profile, compiled_oids, version)
          {:ok, apply_snmp_auth(base_target, version, credential)}
        else
          Logger.debug("SNMPCompiler: skipping device #{device.uid} (missing credentials)")
          {:ok, nil}
        end

      _no_credential ->
        Logger.debug("SNMPCompiler: skipping device #{device.uid} (missing credentials)")
        {:ok, nil}
    end
  end

  # Every target of a profile carries the same compiled OID list, built once by
  # the caller rather than once per device.
  defp build_base_target(device, host, profile, compiled_oids, version) do
    %{
      "id" => device.uid,
      "name" => device.name || device.hostname || device.uid,
      "host" => host,
      "port" => 161,
      "version" => ProtocolFormatter.version(version),
      "poll_interval_seconds" => profile.poll_interval,
      "timeout_seconds" => profile.timeout,
      "retries" => profile.retries,
      "oids" => compiled_oids
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
        compiled =
          targets
          |> Enum.sort_by(&target_sort_key/1)
          |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
            case compile_profile_target(target, profile, actor, opts) do
              {:ok, nil} -> {:cont, {:ok, acc}}
              {:ok, compiled_target} -> {:cont, {:ok, [compiled_target | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case compiled do
          {:ok, compiled_targets} -> {:ok, sort_targets(Enum.reverse(compiled_targets))}
          error -> error
        end

      {:error, reason} ->
        Logger.error("SNMPCompiler: failed to load profile targets - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp compile_profile_target(%SNMPTarget{} = target, profile, actor, opts) do
    oids =
      target.oid_configs
      |> Enum.map(&oid_config_to_map/1)
      |> Enum.reject(&is_nil/1)
      |> ensure_packet_counter_oids()

    if oids == [] do
      {:ok, nil}
    else
      case profile_target_credential(target, actor, opts) do
        {:error, reason} ->
          if CredentialResolver.credential_read_failure?(reason) do
            Logger.error(
              "SNMPCompiler: target #{target.id} credential read failed - #{inspect(reason)}"
            )

            {:error, {:credential_resolution_failed, reason}}
          else
            log_credential_refusal("target", target.id, reason)
            {:ok, nil}
          end

        credential ->
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

          if is_map(credential) and valid_credentials?(credential) do
            {:ok, apply_snmp_auth(base_target, version, credential)}
          else
            Logger.debug("SNMPCompiler: skipping target #{target.id} (missing credentials)")
            {:ok, nil}
          end
      end
    end
  end

  defp compile_profile_target(_, _, _, _), do: {:ok, nil}

  defp profile_target_credential(target, actor, opts) do
    case CredentialResolver.resolve_for_host(target.host, actor, opts) do
      {:ok, %{credential: rule_cred, source: :credential_rule}} when is_map(rule_cred) ->
        rule_cred

      {:error, reason} = error ->
        if CredentialResolver.credential_read_failure?(reason) do
          error
        else
          target_record_credential(target, actor)
        end

      _ ->
        target_record_credential(target, actor)
    end
  end

  defp target_record_credential(target, actor) do
    CredentialResolver.build_credential(target, actor,
      consumer_id: "snmp_target:#{target.id}",
      target_kind: "snmp_target",
      target_id: target.id
    )
  end

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
  defp log_credential_refusal(kind, id, reason) do
    Logger.warning(
      "SNMPCompiler: skipping #{kind} #{id} because credential resolution refused - #{inspect(reason)}"
    )
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

      :no_auth_no_priv ->
        true

      # Unknown or missing levels never validate: the resolver refuses them
      # upstream, and compiling one as noAuthNoPriv would silently downgrade
      # the poll.
      _ ->
        false
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

  @disabled_config_base %{
    "enabled" => false,
    "profile_id" => nil,
    "profile_name" => nil,
    "targets" => []
  }
  @disabled_config Map.put(
                     @disabled_config_base,
                     "config_hash",
                     Compiler.content_hash(@disabled_config_base)
                   )

  @doc """
  Returns disabled SNMP configuration when no profile is assigned.
  """
  @spec disabled_config() :: map()
  def disabled_config do
    @disabled_config
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
        {:ok, if(profile_applies_to_agent?(profile, agent_id), do: profile)}

      {:error, reason} ->
        {:error, reason}
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

  defp repo_ready? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false and
      is_pid(Process.whereis(Repo))
  end
end
