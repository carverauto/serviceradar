defmodule ServiceRadar.AgentConfig.Compilers.SweepCompiler do
  @moduledoc """
  Compiler for sweep configurations.

  Transforms SweepGroup and SweepProfile Ash resources into agent-consumable
  sweep configuration format.

  ## Output Format

  The compiled config follows this structure:

      %{
        "groups" => [
          %{
            "id" => "uuid",
            "name" => "Production Network Sweep",
            "schedule" => %{
              "type" => "interval",
              "interval" => "15m"
            },
            "targets" => ["10.0.1.0/24", "10.0.2.0/24"],
            "ports" => [22, 80, 443],
            "modes" => ["icmp", "tcp"],
            "settings" => %{
              "concurrency" => 50,
              "timeout" => "3s"
            }
          }
        ],
        "version" => "abc123..."
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SweepJobs.DeclaredTargets
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab

  require Ash.Query
  require Logger

  @srql_page_limit_default 500

  # Target query results are shared across agents under the :sweep config type,
  # so ConfigServer.invalidate(:sweep), dispatched on every SweepGroup and
  # SweepProfile change, drops them together with the compiled configs.
  @query_cache_partition "__sweep_target_queries__"

  # A compiled config is itself cached for the ConfigCache TTL, so device
  # membership can lag by this TTL plus that one. Kept short: the fan-out after
  # an invalidation recompiles every agent within seconds, which is where
  # sharing pays off.
  @query_cache_ttl_ms_default 60_000

  @impl true
  def config_type, do: :sweep

  @impl true
  def source_resources do
    [SweepGroup, SweepProfile]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:sweep_compiler)

    # Load groups whose fixed subset contains this agent (any device partition)
    # plus partition-wide groups in the agent's own partition. Device partition
    # != agent partition for isolation scans.
    #
    # A failed groups or profiles read returns an error instead of compiling an
    # empty config: ConfigServer caches every {:ok, _} it is handed, so a
    # degraded compile would deliver "sweep nothing" to every agent until the
    # next :sweep invalidation.
    with {:ok, groups} <- load_sweep_groups(partition, agent_id, actor),
         {:ok, profiles} <- load_profiles(group_profile_ids(groups), actor) do
      profile_map = Map.new(profiles, &{&1.id, &1})

      case compile_groups(groups, profile_map, opts) do
        {:error, reason} ->
          Logger.error("SweepCompiler: failed to compile config - #{inspect(reason)}")
          {:error, reason}

        compiled_groups ->
          Logger.info(
            "SweepCompiler: compiled #{length(compiled_groups)} group(s) for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}",
            groups: Enum.map(compiled_groups, &compiled_group_summary/1)
          )

          # Record what this agent is about to receive as each group's declared
          # targets, so query-derived declarations follow inventory changes and
          # not only group edits. A failed read never reaches here. Unchanged
          # sets are skipped, and recording never fails the compile.
          DeclaredTargets.record_compiled(compiled_groups)

          # Compute config hash for change detection
          config_hash = config_hash(compiled_groups)

          {:ok,
           %{
             "groups" => compiled_groups,
             "compiled_at" => DateTime.to_iso8601(DateTime.utc_now()),
             "config_hash" => config_hash
           }}
      end
    end
  rescue
    e ->
      Logger.error("SweepCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "groups") ->
        {:error, "Config missing 'groups' key"}

      not is_list(config["groups"]) ->
        {:error, "'groups' must be a list"}

      true ->
        :ok
    end
  end

  @doc false
  # The compile step after groups and profiles are loaded. `:query_page_fn`
  # replaces `SRQLRunner.query_page/2` for target queries.
  #
  # Returns the compiled groups, or `{:error, reason}` when a target-query read
  # fails. A successful compile stays a list so callers can sort and hash it;
  # a failed read must not come back as groups that quietly sweep nothing.
  @spec compile_groups([SweepGroup.t()], %{optional(term()) => SweepProfile.t()}, keyword()) ::
          [map()] | {:error, term()}
  def compile_groups(groups, profile_map, opts \\ []) do
    query_page_fn = Keyword.get(opts, :query_page_fn, &SRQLRunner.query_page/2)

    # The memo also holds failed results, so a failing query runs once per
    # compile rather than once per group that uses it.
    groups
    |> Enum.reduce_while({:ok, [], %{}}, fn group, {:ok, acc, query_memo} ->
      case compile_group(group, profile_map, query_memo, query_page_fn) do
        {:ok, compiled, query_memo} -> {:cont, {:ok, [compiled | acc], query_memo}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      # Database row order must not change the compiled config or its version.
      {:ok, compiled, _query_memo} -> Enum.sort_by(compiled, & &1["id"])
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Computes a deterministic config hash for compiled sweep groups.
  """
  @spec config_hash([map()]) :: String.t()
  def config_hash(compiled_groups) when is_list(compiled_groups) do
    compute_config_hash(compiled_groups)
  end

  @doc """
  Compiled probe settings a sweep group would send to an agent.

  Matches `compile_group/4`: profile as base, group overrides on top,
  TCP-without-ports dropped, modes the Go sweeper does not implement dropped.
  Used by NCO validation runs so they replay scheduled scan settings instead
  of inventing ICMP.
  """
  @spec compiled_scan_settings(SweepGroup.t(), SweepProfile.t() | nil) :: map()
  def compiled_scan_settings(%SweepGroup{} = group, profile) do
    ports = merge_ports(profile, group)
    modes = merge_modes(profile, group)
    {ports, modes} = enforce_tcp_ports(ports, modes, group)
    modes = drop_unsupported_modes(modes, group)
    settings = compile_settings(profile, group)

    %{
      sweep_group_id: group.id,
      profile_id: group.profile_id,
      modes: modes,
      ports: ports,
      settings: settings
    }
  end

  @doc """
  Declared targets of a group: static CIDRs/IPs plus SRQL-resolved device targets.

  This is the target set `compile/3` would deliver for the group, projected to
  the lean shape the declared-target relation persists (issue #4963): one row
  per group, never one per agent. Device targets carry the device uid the
  SRQL target query resolved, when it resolved one.

  A saved query that cannot be parsed or cast matches no devices, the same
  projection compile delivers. A failed read returns `{:error, reason}` so
  the caller can keep the previous declared rows.

  Accepts the same `:query_page_fn` option as `compile_groups/3`.
  """
  @spec declared_targets(SweepGroup.t(), keyword()) ::
          %{
            static: [String.t()],
            device: [%{target: String.t(), device_uid: String.t() | nil}]
          }
          | {:error, term()}
  def declared_targets(%SweepGroup{} = group, opts \\ []) do
    query_page_fn = Keyword.get(opts, :query_page_fn, &SRQLRunner.query_page/2)
    modes = merge_modes(nil, group)

    case compile_targets(group, modes, %{}, query_page_fn) do
      {:ok, static, device_targets, _query_memo} ->
        device =
          Enum.map(device_targets, fn device_target ->
            %{
              target: device_target["network"],
              device_uid: get_in(device_target, ["metadata", "device_uid"])
            }
          end)

        %{static: static, device: device}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  defp compute_config_hash(compiled_groups) do
    # Sort groups by ID for deterministic hashing
    sorted_groups = Enum.sort_by(compiled_groups, & &1["id"])

    # Compute SHA256 hash of the JSON-encoded config
    sorted_groups
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp compiled_group_summary(group) do
    %{
      id: group["id"],
      name: group["name"],
      static_targets: length(group["targets"] || []),
      device_targets: length(group["device_targets"] || []),
      ports: group["ports"] || [],
      modes: group["modes"] || []
    }
  end

  defp group_profile_ids(groups) do
    groups
    |> Enum.map(& &1.profile_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_sweep_groups(partition, agent_id, actor) do
    query =
      Ash.Query.for_read(SweepGroup, :for_agent_partition, %{
        partition: partition,
        agent_id: agent_id
      })

    Logger.debug(
      "SweepCompiler: loading groups for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}"
    )

    case Ash.read(query, actor: actor) do
      {:ok, groups} ->
        Logger.debug(
          "SweepCompiler: loaded #{length(groups)} groups: #{inspect(Enum.map(groups, & &1.name))}"
        )

        Enum.each(groups, fn g ->
          Logger.debug(
            "SweepCompiler: group #{g.name} - target_query=#{inspect(g.target_query)}, static_targets=#{inspect(g.static_targets)}, agent_ids=#{inspect(g.agent_ids)}"
          )
        end)

        {:ok, groups}

      {:error, reason} ->
        Logger.error("SweepCompiler: failed to load groups - #{inspect(reason)}")
        {:error, {:sweep_groups_read_failed, reason}}
    end
  end

  defp load_profiles(profile_ids, _actor) when profile_ids == [], do: {:ok, []}

  defp load_profiles(profile_ids, actor) do
    query = Ash.Query.filter(SweepProfile, id in ^profile_ids)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} ->
        {:ok, profiles}

      {:error, reason} ->
        Logger.error("SweepCompiler: failed to load profiles - #{inspect(reason)}")
        {:error, {:sweep_profiles_read_failed, reason}}
    end
  end

  defp compile_group(group, profile_map, query_memo, query_page_fn) do
    # Get profile settings as base
    profile = Map.get(profile_map, group.profile_id)

    # Build schedule
    schedule = compile_schedule(group)

    # Merge ports from profile and group overrides
    ports = merge_ports(profile, group)

    # Merge sweep modes from profile and group overrides
    modes = merge_modes(profile, group)

    # Guard against TCP modes without ports
    {ports, modes} = enforce_tcp_ports(ports, modes, group)

    # Drop modes the agent sweeper does not implement (historically "arp").
    modes = drop_unsupported_modes(modes, group)

    # Build targets from static CIDRs/IPs and device targets from SRQL rows.
    with {:ok, targets, device_targets, query_memo} <-
           compile_targets(group, modes, query_memo, query_page_fn) do
      # Build settings from profile with overrides
      settings = compile_settings(profile, group)
      banner_grab = compile_banner_grab(profile, group)

      compiled =
        maybe_put_device_targets(
          %{
            "id" => group.id,
            "sweep_group_id" => group.id,
            "name" => group.name,
            "description" => group.description,
            "schedule" => schedule,
            "targets" => targets,
            "ports" => ports,
            "modes" => modes,
            "banner_grab" => banner_grab,
            "settings" => settings
          },
          device_targets
        )

      {:ok, compiled, query_memo}
    end
  end

  defp maybe_put_device_targets(compiled, []), do: compiled

  defp maybe_put_device_targets(compiled, device_targets),
    do: Map.put(compiled, "device_targets", device_targets)

  defp compile_schedule(group) do
    case group.schedule_type do
      :cron ->
        %{
          "type" => "cron",
          "cron_expression" => group.cron_expression
        }

      _ ->
        %{
          "type" => "interval",
          "interval" => group.interval
        }
    end
  end

  defp compile_targets(group, modes, query_memo, query_page_fn) do
    static_targets = Enum.uniq(group.static_targets || [])

    # Device targets from the SRQL query stay separate from static CIDRs so the
    # agent can preserve inventory context while scanning.
    case group.target_query do
      query when is_binary(query) and query != "" ->
        normalized = normalize_target_query(query)

        case device_targets_for_query(normalized, query, group, modes, query_memo, query_page_fn) do
          {:ok, device_targets, query_memo} ->
            {:ok, static_targets, device_targets, query_memo}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, static_targets, [], query_memo}
    end
  end

  # A group's target query may fail in two ways that must not be confused.
  # An unparseable query, or one that parses but cannot be translated or cast,
  # is deterministic: failing the compile would freeze every group until the
  # query is edited, so it warns and matches nothing. A read that fails
  # (database outage, serving-path error, a later page that does not return)
  # fails the whole compile. ConfigServer does not cache failed compiles, so
  # the agent keeps its running config instead of receiving a group that
  # quietly sweeps a partial or empty device list. Failed reads are not written
  # to the shared query cache, so the next compile retries them.
  defp device_targets_for_query(query, raw_query, group, modes, query_memo, query_page_fn) do
    case classify_target_query(query) do
      {:unparseable, reason} ->
        warn_saved_query(group, raw_query, "cannot be parsed", reason)
        {:ok, [], query_memo}

      :ok ->
        case target_query_rows(query, query_memo, query_page_fn) do
          {{:ok, rows}, query_memo} ->
            case build_device_targets(rows, group, query, modes) do
              {:ok, device_targets} -> {:ok, device_targets, query_memo}
              {:error, reason} -> {:error, reason}
            end

          {{:error, reason}, query_memo} ->
            finish_target_query(reason, query_memo, group, raw_query, query)

          {{:raised, error}, query_memo} ->
            finish_target_query({:raised, error}, query_memo, group, raw_query, query)
        end
    end
  end

  defp finish_target_query({:raised, error}, query_memo, group, raw_query, query) do
    if saved_query_rejection?(error) do
      warn_saved_query(group, raw_query, "cannot be cast", error)
      {:ok, [], query_memo}
    else
      message = exception_message(error)
      log_target_query_raised(group, query, message)
      {:error, {:target_query_failed, {:raised, message}}}
    end
  end

  defp finish_target_query(reason, query_memo, group, raw_query, _query) do
    if saved_query_rejection?(reason) do
      warn_saved_query(group, raw_query, "cannot be cast", reason)
      {:ok, [], query_memo}
    else
      Logger.error(
        "SweepCompiler: SRQL query failed for group #{inspect(group.id)} - #{inspect(reason)}"
      )

      {:error, {:target_query_failed, reason}}
    end
  end

  defp warn_saved_query(group, raw_query, problem, reason) do
    Logger.warning(
      "SweepCompiler: SRQL target query #{problem} for group #{inspect(group.id)} " <>
        "(#{inspect(raw_query)}): #{inspect(reason)}; matching no devices"
    )
  end

  @translator_rejection_atoms ~w(
    invalid_srql_translation
    invalid_srql_params
    invalid_srql_param
    invalid_int_array_param
    invalid_text_array_param
    invalid_timestamptz_param
    invalid_date_param
    invalid_uuid_param
    invalid_inet_param
  )a

  @postgres_cast_codes ~w(
    invalid_text_representation
    invalid_binary_representation
    invalid_datetime_format
    datetime_field_overflow
    numeric_value_out_of_range
  )a

  defp saved_query_rejection?(reason) when is_binary(reason), do: true
  defp saved_query_rejection?(reason) when reason in @translator_rejection_atoms, do: true
  defp saved_query_rejection?({:unexpected_srql_translate_result, _}), do: true
  defp saved_query_rejection?(%Jason.DecodeError{}), do: true
  defp saved_query_rejection?(%Ash.Error.Invalid{}), do: true

  defp saved_query_rejection?(%Postgrex.Error{postgres: %{code: code}})
       when code in @postgres_cast_codes, do: true

  defp saved_query_rejection?(_reason), do: false

  defp exception_message(error) when is_exception(error), do: Exception.message(error)
  defp exception_message(error), do: inspect(error)

  defp classify_target_query(query) do
    case SRQLAst.parse(query) do
      {:ok, _ast} -> :ok
      {:error, reason} -> {:unparseable, reason}
    end
  rescue
    exception ->
      # A missing parser is not a saved query that can never parse. Run the
      # read; if that fails too, the compile fails instead of matching nothing.
      Logger.warning(
        "SweepCompiler: SRQL parser unavailable (#{Exception.message(exception)}); running the target query"
      )

      :ok
  end

  # The normalized query string is both the memo key and the shared cache key:
  # it is exactly what SRQL receives, so equal keys can never share a wrong
  # result.
  defp normalize_target_query(query) do
    SRQLQuery.ensure_target(query, :devices)
  end

  defp target_query_rows(query, query_memo, query_page_fn) do
    case query_memo do
      %{^query => result} ->
        {result, query_memo}

      _ ->
        result = shared_target_query_rows(query, query_page_fn)
        {result, Map.put(query_memo, query, result)}
    end
  end

  defp shared_target_query_rows(query, query_page_fn) do
    scope = {:sweep_query, query}

    case ConfigCache.get(:sweep, @query_cache_partition, nil, scope) do
      {:ok, %{rows: rows}} ->
        {:ok, rows}

      _ ->
        case fetch_target_query_rows(query, query_page_fn) do
          {:ok, rows} = result ->
            cache_target_query_rows(scope, rows)
            result

          failed ->
            failed
        end
    end
  end

  defp cache_target_query_rows(scope, rows) do
    ConfigCache.put(
      :sweep,
      @query_cache_partition,
      nil,
      %{rows: rows},
      scope,
      query_cache_ttl_ms()
    )
  end

  defp query_cache_ttl_ms do
    case Application.get_env(:serviceradar_core, :sweep_query_cache_ttl_ms) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> @query_cache_ttl_ms_default
    end
  end

  defp fetch_target_query_rows(query, query_page_fn) do
    fetch_target_query_pages(query, nil, [], query_page_fn)
  rescue
    error -> {:raised, error}
  end

  defp fetch_target_query_pages(query, cursor, pages, query_page_fn) do
    case query_page_fn.(query, limit: srql_page_limit(), cursor: cursor, direction: "next") do
      {:ok, %{rows: rows, next_cursor: next_cursor}} ->
        pages = [target_rows(rows) | pages]

        if is_binary(next_cursor) do
          fetch_target_query_pages(query, next_cursor, pages, query_page_fn)
        else
          {:ok, concat_pages(pages)}
        end

      # A later page that fails is a failed read. Keep none of the rows: a
      # partial device list differs from what the data says, and it is not
      # cached, so the next compile reads the query again.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp concat_pages(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # Keep only the fields device targets are built from, in SRQL order: the
  # first row seen for an IP wins, and the shared cache stays small.
  defp target_rows(rows) when is_list(rows) do
    for %{"ip" => ip} = row <- rows,
        is_binary(ip),
        ip != "",
        do: %{"ip" => ip, "uid" => row["uid"]}
  end

  defp build_device_targets(rows, group, query, modes) do
    device_targets =
      rows
      |> Enum.reduce(%{}, &put_device_target_from_row(&1, &2, group, modes))
      |> Map.values()
      |> Enum.sort_by(& &1["network"])

    {:ok, device_targets}
  rescue
    error ->
      log_target_query_raised(group, query, Exception.message(error))
      {:error, {:target_query_failed, {:raised, Exception.message(error)}}}
  end

  # A raised target query is a failed read. Log the group and query, then fail
  # the compile: ConfigServer does not cache {:error, _}, so the agent keeps
  # its running config instead of sweeping nothing until the next invalidation.
  defp log_target_query_raised(group, query, message) do
    Logger.error(
      "SweepCompiler: SRQL target query raised for group #{inspect(group.id)} " <>
        "(#{inspect(query)}): #{message}"
    )
  end

  defp srql_page_limit do
    Application.get_env(:serviceradar_core, :sweep_srql_page_limit, @srql_page_limit_default)
  end

  defp put_device_target_from_row(row, targets, group, modes) when is_map(row) do
    case Map.get(row, "ip") do
      value when is_binary(value) ->
        case normalize_device_ip_target(value) do
          nil ->
            targets

          target ->
            Map.put_new(targets, target, device_target_from_row(row, target, group, modes))
        end

      _ ->
        targets
    end
  end

  defp put_device_target_from_row(_row, targets, _group, _modes), do: targets

  # device_uid is the only per-target metadata anything reads (the
  # device_sweep_overlap view); nothing in the agent or core consumes the
  # group id, query, hostname or discovery sources per target.
  defp device_target_from_row(row, target, group, modes) do
    %{
      "network" => target,
      "sweep_modes" => modes,
      "query_label" => group.name,
      "source" => "srql",
      "metadata" => maybe_put_string(%{}, "device_uid", Map.get(row, "uid"))
    }
  end

  defp maybe_put_string(metadata, _key, value) when value in [nil, ""], do: metadata

  defp maybe_put_string(metadata, key, value) when is_binary(value),
    do: Map.put(metadata, key, value)

  defp maybe_put_string(metadata, key, value), do: Map.put(metadata, key, to_string(value))

  defp normalize_device_ip_target(value) when is_binary(value) do
    value = String.trim(value)

    if valid_ip_address?(value), do: value
  end

  defp valid_ip_address?(value) do
    value != "" and match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))
  end

  defp merge_ports(nil, group), do: normalize_ports_override(group.ports, [])

  defp merge_ports(profile, group) do
    # Group ports override profile ports if set (treat empty override as inherit)
    normalize_ports_override(group.ports, profile.ports || [])
  end

  defp normalize_ports_override(nil, inherited), do: inherited
  defp normalize_ports_override([], inherited), do: inherited
  defp normalize_ports_override(ports, _inherited), do: ports

  defp enforce_tcp_ports(ports, modes, group) do
    modes = modes || []

    tcp_modes = Enum.filter(modes, &(&1 in ["tcp", "tcp_connect"]))

    if ports == [] and tcp_modes != [] do
      Logger.warning(
        "SweepCompiler: TCP mode enabled but ports empty for group #{group.name} (#{group.id}); dropping TCP modes"
      )

      filtered_modes = Enum.reject(modes, &(&1 in ["tcp", "tcp_connect"]))
      {ports, filtered_modes}
    else
      {ports, modes}
    end
  end

  # Modes the Go sweeper actually executes. Profile/UI historically offered
  # "arp", but parseSweepModes ignores it.
  @agent_supported_modes ["icmp", "tcp", "tcp_connect", "mtr"]

  defp drop_unsupported_modes(modes, group) do
    modes = modes || []
    {supported, dropped} = Enum.split_with(modes, &(&1 in @agent_supported_modes))

    if dropped != [] do
      Logger.debug(
        "SweepCompiler: dropping unsupported modes #{inspect(dropped)} for group #{group.name} (#{group.id})"
      )
    end

    supported
  end

  # A group with no profile and no explicit modes is ICMP-only. Enabling TCP
  # here would immediately trip enforce_tcp_ports/3 and drop TCP anyway.
  defp merge_modes(nil, group), do: normalize_modes_override(group.sweep_modes, ["icmp"])

  defp merge_modes(profile, group) do
    normalize_modes_override(group.sweep_modes, profile.sweep_modes || ["icmp", "tcp"])
  end

  defp normalize_modes_override(nil, inherited), do: inherited
  defp normalize_modes_override([], inherited), do: inherited
  defp normalize_modes_override(modes, _inherited), do: modes

  defp compile_settings(profile, group) do
    base_settings =
      if profile do
        settings = %{
          "concurrency" => profile.concurrency,
          "timeout" => profile.timeout,
          "icmp_settings" => profile.icmp_settings || %{},
          "tcp_settings" => profile.tcp_settings || %{}
        }

        if profile.scan_timeout do
          Map.put(settings, "scan_timeout", profile.scan_timeout)
        else
          settings
        end
      else
        %{
          "concurrency" => 50,
          "timeout" => "3s",
          "icmp_settings" => %{},
          "tcp_settings" => %{}
        }
      end

    # Apply group overrides, excluding top-level phase blocks.
    overrides = Map.drop(group.overrides || %{}, ["banner_grab", :banner_grab])
    Map.merge(base_settings, overrides)
  end

  defp compile_banner_grab(profile, group) do
    profile
    |> profile_banner_grab()
    |> merge_banner_grab_override(group.overrides || %{})
    |> normalize_banner_grab()
  end

  defp profile_banner_grab(nil), do: BannerGrab.default_input()
  defp profile_banner_grab(%{banner_grab: nil}), do: BannerGrab.default_input()
  defp profile_banner_grab(%{banner_grab: banner_grab}), do: banner_grab

  defp merge_banner_grab_override(banner_grab, %{"banner_grab" => override})
       when is_map(override),
       do: Map.merge(map_from_banner_grab(banner_grab), override)

  defp merge_banner_grab_override(banner_grab, %{banner_grab: override}) when is_map(override),
    do: Map.merge(map_from_banner_grab(banner_grab), override)

  defp merge_banner_grab_override(banner_grab, _overrides), do: banner_grab

  defp normalize_banner_grab(banner_grab) do
    banner_grab = map_from_banner_grab(banner_grab)

    %{
      "enabled" => Map.get(banner_grab, :enabled, Map.get(banner_grab, "enabled", false)),
      "protocols" =>
        normalize_banner_protocols(
          Map.get(banner_grab, :protocols, Map.get(banner_grab, "protocols", []))
        ),
      "ports" =>
        normalize_banner_ports(Map.get(banner_grab, :ports, Map.get(banner_grab, "ports", %{}))),
      "connect_timeout_ms" => banner_int(banner_grab, :connect_timeout_ms, 2_000),
      "read_timeout_ms" => banner_int(banner_grab, :read_timeout_ms, 2_000),
      "max_banner_bytes" => banner_int(banner_grab, :max_banner_bytes, 1_024),
      "max_concurrency_per_host" => banner_int(banner_grab, :max_concurrency_per_host, 4),
      "max_global_concurrency" => banner_int(banner_grab, :max_global_concurrency, 256),
      "max_probe_rate_per_second" => banner_int(banner_grab, :max_probe_rate_per_second, 0),
      "max_candidate_queue" => banner_int(banner_grab, :max_candidate_queue, 8_192),
      "match_batch_size" => banner_int(banner_grab, :match_batch_size, 256),
      "match_batch_max_bytes" => banner_int(banner_grab, :match_batch_max_bytes, 1_048_576),
      "min_reprobe_interval_s" => banner_int(banner_grab, :min_reprobe_interval_s, 86_400),
      "per_host_rate_limit_ms" => banner_int(banner_grab, :per_host_rate_limit_ms, 100)
    }
  end

  defp map_from_banner_grab(%_{} = banner_grab) do
    banner_grab
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
  end

  defp map_from_banner_grab(banner_grab) when is_map(banner_grab), do: banner_grab
  defp map_from_banner_grab(_banner_grab), do: BannerGrab.default_input()

  defp normalize_banner_protocols(protocols) when is_list(protocols) do
    protocols
    |> Enum.map(&to_string/1)
    |> Enum.filter(
      &(&1 in Enum.map(BannerGrab.protocols(), fn protocol -> Atom.to_string(protocol) end))
    )
    |> Enum.uniq()
  end

  defp normalize_banner_protocols(_protocols), do: []

  defp normalize_banner_ports(ports) when is_map(ports) do
    Map.new(ports, fn {protocol, values} ->
      {to_string(protocol), normalize_port_list(values)}
    end)
  end

  defp normalize_banner_ports(_ports), do: %{}

  defp normalize_port_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.filter(&(&1 >= 1 and &1 <= 65_535))
    |> Enum.uniq()
  end

  defp normalize_port_list(_values), do: []

  defp banner_int(banner_grab, key, default) do
    case Map.get(banner_grab, key, Map.get(banner_grab, Atom.to_string(key), default)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end
end
