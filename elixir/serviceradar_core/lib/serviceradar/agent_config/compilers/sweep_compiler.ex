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
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Repo
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SweepJobs.AliasRecency
  alias ServiceRadar.SweepJobs.DeclaredTargets
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab

  require Ash.Query
  require Logger

  @srql_page_limit_default 500
  @max_alias_targets_per_device_default 8
  @alias_lookup_chunk_size 1_000

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

      opts =
        opts
        |> Keyword.put(:agent_id, agent_id)
        |> Keyword.put_new(:format, Keyword.get(opts, :sweep_format, :legacy))
        |> Keyword.put_new_lazy(:agent_capabilities, fn ->
          load_agent_capabilities(agent_id, actor)
        end)

      case compile_groups(groups, profile_map, opts) do
        {:error, reason} ->
          Logger.error("SweepCompiler: failed to compile config - #{inspect(reason)}")
          {:error, reason}

        {:shared_targets_v1, document, compiled_groups} ->
          log_compiled_groups(compiled_groups, partition, agent_id)

          # Declared targets are recorded from the legacy groups either way:
          # the shared document is a wire encoding of the same targets, and
          # the declared-target relation stays format-independent.
          DeclaredTargets.record_compiled(compiled_groups)

          {:ok,
           document
           |> Map.put("compiled_at", DateTime.to_iso8601(DateTime.utc_now()))
           |> Map.put("config_hash", shared_config_hash(document))}

        compiled_groups ->
          log_compiled_groups(compiled_groups, partition, agent_id)

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
  # replaces `SRQLRunner.query_page/2` for target queries. `:alias_ips_fn`
  # replaces the active `:ip` alias lookup for matched device uids; when only
  # `:query_page_fn` is given, no aliases are loaded. `:agent_capabilities`
  # is the compiling agent's capability list (nil when unknown), which
  # withholds the modes the agent reports it cannot run; `:agent_id` names the
  # agent in the resulting log lines. `:format` selects the emitted shape:
  # `:legacy` (default) returns the compiled groups, `:shared_targets_v1`
  # returns `{:shared_targets_v1, document, compiled_groups}` with the
  # shared-targets document derived from the same groups, and any other value
  # is `{:error, {:unsupported_sweep_format, format}}`.
  #
  # Returns the compiled groups, or `{:error, reason}` when a target-query read
  # fails. A successful compile stays a list so callers can sort and hash it;
  # a failed read must not come back as groups that quietly sweep nothing.
  @spec compile_groups([SweepGroup.t()], %{optional(term()) => SweepProfile.t()}, keyword()) ::
          [map()] | {:shared_targets_v1, map(), [map()]} | {:error, term()}
  def compile_groups(groups, profile_map, opts \\ []) do
    case Keyword.get(opts, :format, :legacy) do
      :legacy ->
        compile_legacy_groups(groups, profile_map, opts)

      :shared_targets_v1 ->
        case compile_legacy_groups(groups, profile_map, opts) do
          {:error, reason} ->
            {:error, reason}

          compiled ->
            {:shared_targets_v1, shared_targets_document(compiled, groups), compiled}
        end

      format ->
        {:error, {:unsupported_sweep_format, format}}
    end
  end

  defp compile_legacy_groups(groups, profile_map, opts) do
    resolvers = target_resolvers(opts)

    agent = %{
      id: Keyword.get(opts, :agent_id),
      capabilities: Keyword.get(opts, :agent_capabilities)
    }

    # The memo also holds failed results, so a failing query runs once per
    # compile rather than once per group that uses it.
    groups
    |> Enum.reduce_while({:ok, [], %{}}, fn group, {:ok, acc, query_memo} ->
      case compile_group(group, profile_map, agent, query_memo, resolvers) do
        {:ok, compiled, query_memo} -> {:cont, {:ok, [compiled | acc], query_memo}}
        {:skip, query_memo} -> {:cont, {:ok, acc, query_memo}}
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
  Computes the shared-targets/v1 config hash for a compiled document.

  Covers the sorted `groups`, `device_table` and `target_sets` only, so
  `compiled_at` and any `config_hash` already in the document do not
  affect it.
  """
  @spec shared_config_hash(map()) :: String.t()
  def shared_config_hash(document) when is_map(document) do
    %{
      "device_table" => Enum.sort_by(document["device_table"] || [], & &1["ref"]),
      "groups" => Enum.sort_by(document["groups"] || [], & &1["id"]),
      "target_sets" => Enum.sort_by(document["target_sets"] || [], & &1["key"])
    }
    |> Jason.encode!()
    |> sha256_16()
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

  Accepts the same `:query_page_fn` and `:alias_ips_fn` options as `compile_groups/3`.
  """
  @spec declared_targets(SweepGroup.t(), keyword()) ::
          %{
            static: [String.t()],
            device: [%{target: String.t(), device_uid: String.t() | nil}]
          }
          | {:error, term()}
  def declared_targets(%SweepGroup{} = group, opts \\ []) do
    resolvers = target_resolvers(opts)
    modes = merge_modes(nil, group)

    case compile_targets(group, modes, %{}, resolvers) do
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

  defp target_resolvers(opts) do
    %{
      query_page_fn: Keyword.get(opts, :query_page_fn, &SRQLRunner.query_page/2),
      alias_ips_fn: resolve_alias_ips_fn(opts)
    }
  end

  defp resolve_alias_ips_fn(opts) do
    case Keyword.fetch(opts, :alias_ips_fn) do
      {:ok, fun} when is_function(fun, 1) ->
        fun

      :error ->
        if Keyword.has_key?(opts, :query_page_fn) do
          fn _uids -> {:ok, %{}} end
        else
          &load_active_device_alias_ips/1
        end
    end
  end

  # Private helpers

  defp compute_config_hash(compiled_groups) do
    # Sort groups by ID for deterministic hashing
    compiled_groups
    |> Enum.sort_by(& &1["id"])
    |> Jason.encode!()
    |> sha256_16()
  end

  defp sha256_16(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp target_set_key(normalized_query), do: "q-" <> sha256_16(normalized_query)

  # The shared-targets/v1 document, derived from the legacy compiled groups
  # so agent rehydration reproduces each group's legacy `device_targets`
  # exactly: the same (ip, device_uid) pairs, in the same legacy order.
  defp shared_targets_document(compiled_groups, groups) do
    source_by_id = Map.new(groups, &{&1.id, &1})

    # One pair list per normalized query (groups sharing a query compile to
    # the same device targets, so the first stands for the set), and each
    # device-target group's normalized query.
    {pairs_by_query, query_by_group} =
      Enum.reduce(compiled_groups, {%{}, %{}}, fn compiled, {sets, by_group} ->
        case compiled["device_targets"] do
          nil ->
            {sets, by_group}

          device_targets ->
            source = Map.fetch!(source_by_id, compiled["id"])
            query = normalize_target_query(source.target_query, source.partition)

            pairs =
              Enum.map(
                device_targets,
                &{&1["network"], get_in(&1, ["metadata", "device_uid"])}
              )

            {Map.put_new(sets, query, pairs), Map.put(by_group, compiled["id"], query)}
        end
      end)

    sorted_sets = Enum.sort_by(pairs_by_query, fn {query, _pairs} -> target_set_key(query) end)
    ref_by_pair = shared_refs(sorted_sets)

    %{
      "format" => "shared-targets/v1",
      "device_table" => shared_device_table(ref_by_pair),
      "target_sets" =>
        Enum.map(sorted_sets, fn {query, pairs} ->
          %{
            "key" => target_set_key(query),
            "target_query" => query,
            "refs" => Enum.map(pairs, &Map.fetch!(ref_by_pair, &1))
          }
        end),
      "groups" => Enum.map(compiled_groups, &shared_group(&1, query_by_group))
    }
  end

  # Every (ip, device_uid) pair gets one ref, in set-key then legacy IP
  # order. Preference: the device_uid while that string is free and this uid
  # has not already been used as a ref; otherwise "ip:" <> ip while that is
  # free; otherwise "ip:" <> ip <> "@" <> (uid or ""). The last form is what keeps
  # two owners of one alias address as two table entries. Each entry still
  # carries the owning device_uid.
  defp shared_refs(sorted_sets) do
    {ref_by_pair, _claimed_uids, _taken_refs} =
      Enum.reduce(sorted_sets, {%{}, MapSet.new(), MapSet.new()}, fn {_query, pairs}, acc ->
        Enum.reduce(pairs, acc, fn {ip, uid} = pair, {ref_by_pair, claimed, taken} ->
          ip_ref = "ip:" <> ip

          cond do
            Map.has_key?(ref_by_pair, pair) ->
              {ref_by_pair, claimed, taken}

            is_binary(uid) and not MapSet.member?(claimed, uid) and
                not MapSet.member?(taken, uid) ->
              {
                Map.put(ref_by_pair, pair, uid),
                MapSet.put(claimed, uid),
                MapSet.put(taken, uid)
              }

            not MapSet.member?(taken, ip_ref) ->
              {Map.put(ref_by_pair, pair, ip_ref), claimed, MapSet.put(taken, ip_ref)}

            true ->
              ref = ip_ref <> "@" <> (uid || "")
              {Map.put(ref_by_pair, pair, ref), claimed, MapSet.put(taken, ref)}
          end
        end)
      end)

    ref_by_pair
  end

  defp shared_device_table(ref_by_pair) do
    ref_by_pair
    |> Enum.map(fn {{ip, uid}, ref} ->
      maybe_put_string(%{"ref" => ref, "ip" => ip}, "device_uid", uid)
    end)
    |> Enum.sort_by(& &1["ref"])
  end

  defp shared_group(compiled, query_by_group) do
    shared = Map.delete(compiled, "device_targets")

    case Map.fetch(query_by_group, compiled["id"]) do
      {:ok, query} ->
        shared
        |> Map.put("target_query", query)
        |> Map.put("device_target_set", target_set_key(query))

      :error ->
        shared
    end
  end

  defp log_compiled_groups(compiled_groups, partition, agent_id) do
    Logger.info(
      "SweepCompiler: compiled #{length(compiled_groups)} group(s) for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}",
      groups: Enum.map(compiled_groups, &compiled_group_summary/1)
    )
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

  # nil means unknown: every mode stays, as for an agent predating the
  # unavailable markers. A failed read must not stop an agent's ICMP sweeps.
  defp load_agent_capabilities(nil, _actor), do: nil

  defp load_agent_capabilities(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{capabilities: capabilities}} ->
        capabilities

      other ->
        Logger.debug(
          "SweepCompiler: no capabilities for agent_id=#{inspect(agent_id)} (#{inspect(other)}); compiling every mode"
        )

        nil
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

  defp compile_group(group, profile_map, agent, query_memo, resolvers) do
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
    with {:ok, modes} <- agent_modes(modes, group, agent),
         {:ok, targets, device_targets, query_memo} <-
           compile_targets(group, modes, query_memo, resolvers) do
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
    else
      :withheld -> {:skip, query_memo}
      {:error, reason} -> {:error, reason}
    end
  end

  # The modes this agent can run. A group left with none is not sent to the
  # agent at all, and the warning is the diagnostic for a group whose only
  # agent cannot run it: such a group otherwise just never reports results.
  defp agent_modes(modes, group, agent) do
    case withhold_unavailable_modes(modes, agent.capabilities) do
      {_modes, []} ->
        {:ok, modes}

      {[], withheld} ->
        Logger.warning(
          "SweepCompiler: group #{inspect(group.name)} (#{group.id}) not sent to agent_id=#{inspect(agent.id)}: " <>
            "the agent reports #{Enum.map_join(withheld, ", ", &unavailable_marker/1)} " <>
            "and the group has no other sweep mode"
        )

        :withheld

      {kept, withheld} ->
        Logger.debug(
          "SweepCompiler: withholding modes #{inspect(withheld)} of group #{group.name} (#{group.id}) " <>
            "from agent_id=#{inspect(agent.id)}"
        )

        {:ok, kept}
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

  defp compile_targets(group, modes, query_memo, resolvers) do
    static_targets = Enum.uniq(group.static_targets || [])

    # Device targets from the SRQL query stay separate from static CIDRs so the
    # agent can preserve inventory context while scanning.
    case group.target_query do
      query when is_binary(query) and query != "" ->
        normalized = normalize_target_query(query, group.partition)

        case device_targets_for_query(normalized, query, group, modes, query_memo, resolvers) do
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
  defp device_targets_for_query(query, raw_query, group, modes, query_memo, resolvers) do
    case classify_target_query(query) do
      {:unparseable, reason} ->
        warn_saved_query(group, raw_query, "cannot be parsed", reason)
        {:ok, [], query_memo}

      :ok ->
        case target_query_rows(query, query_memo, resolvers) do
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
  #
  # An unscoped device query would match every partition. Scope it to the
  # group's device partition. That is not the compiling agent's home
  # partition: a selected agent in another partition is an isolation scan
  # and must still see this group's devices. A query that already names
  # `partition` is left alone. Static targets are not passed through here.
  defp normalize_target_query(query, partition) do
    query
    |> SRQLQuery.ensure_target(:devices)
    |> scope_device_partition(partition)
  end

  defp scope_device_partition(query, partition) when is_binary(partition) do
    partition = String.trim(partition)

    if partition == "" or query_scopes_partition?(query) do
      query
    else
      query <> " partition:" <> srql_filter_value(partition)
    end
  end

  defp scope_device_partition(query, _partition), do: query

  defp query_scopes_partition?(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.any?(&filter_key_is_partition?/1)
  end

  defp filter_key_is_partition?(term) do
    term = String.trim_leading(term, "-")
    String.starts_with?(term, "partition:") or String.starts_with?(term, "partition!=")
  end

  defp srql_filter_value(value) do
    if value =~ ~r/^[A-Za-z0-9_.:-]+$/ do
      value
    else
      escaped =
        value
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")

      "\"#{escaped}\""
    end
  end

  defp target_query_rows(query, query_memo, resolvers) do
    case query_memo do
      %{^query => result} ->
        {result, query_memo}

      _ ->
        result = shared_target_query_rows(query, resolvers)
        {result, Map.put(query_memo, query, result)}
    end
  end

  defp shared_target_query_rows(query, resolvers) do
    scope = {:sweep_query, query}

    case ConfigCache.get(:sweep, @query_cache_partition, nil, scope) do
      {:ok, %{rows: rows}} ->
        {:ok, rows}

      _ ->
        case fetch_target_query_rows(query, resolvers) do
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

  defp max_alias_targets_per_device do
    case Application.get_env(:serviceradar_core, :sweep_max_alias_targets_per_device) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _ -> @max_alias_targets_per_device_default
    end
  end

  defp fetch_target_query_rows(query, resolvers) do
    with {:ok, rows} <- fetch_target_query_pages(query, nil, [], resolvers.query_page_fn) do
      attach_alias_ips(rows, resolvers.alias_ips_fn)
    end
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
    for row <- rows,
        is_map(row),
        has_non_empty_field?(row, "ip") or has_non_empty_field?(row, "uid"),
        do: %{"ip" => row["ip"], "uid" => row["uid"]}
  end

  defp has_non_empty_field?(row, key) do
    case Map.get(row, key) do
      value when is_binary(value) -> value != ""
      _ -> false
    end
  end

  defp attach_alias_ips(rows, alias_ips_fn) when is_list(rows) do
    limit = max_alias_targets_per_device()
    uids = unique_row_uids(rows)
    primary_ips = row_primary_ips(rows)

    with {:ok, alias_map} <- fetch_alias_map(uids, limit, alias_ips_fn) do
      {:ok, Enum.flat_map(rows, &compact_target_row(&1, alias_map, primary_ips, limit))}
    end
  end

  defp fetch_alias_map(uids, limit, _alias_ips_fn) when uids == [] or limit == 0, do: {:ok, %{}}

  defp fetch_alias_map(uids, _limit, alias_ips_fn), do: alias_ips_fn.(uids)

  defp unique_row_uids(rows) do
    for %{"uid" => uid} <- rows,
        is_binary(uid),
        uid != "",
        uniq: true,
        do: uid
  end

  defp row_primary_ips(rows) do
    for row <- rows, {_target, key} <- [device_ip_target(row["ip"])], into: MapSet.new(), do: key
  end

  defp compact_target_row(row, alias_map, primary_ips, limit) do
    alias_ips =
      row["uid"]
      |> then(&Map.get(alias_map, &1, []))
      |> bounded_device_alias_ips(primary_ips, limit)

    has_ip? = has_non_empty_field?(row, "ip")

    cond do
      alias_ips != [] ->
        [%{"ip" => row["ip"], "uid" => row["uid"], "alias_ips" => alias_ips}]

      has_ip? ->
        [%{"ip" => row["ip"], "uid" => row["uid"]}]

      true ->
        []
    end
  end

  defp bounded_device_alias_ips(candidates, primary_ips, limit)
       when is_list(candidates) and limit > 0 do
    candidates
    |> Enum.map(&device_ip_target/1)
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(primary_ips, elem(&1, 1))))
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  defp bounded_device_alias_ips(_candidates, _primary_ips, _limit), do: []

  @active_device_alias_ips_sql """
  SELECT ranked.device_id, ranked.alias_value
  FROM (
    SELECT
      a.device_id,
      a.alias_value,
      ROW_NUMBER() OVER (
        PARTITION BY a.device_id
        ORDER BY
          CASE WHEN a.state IN ('confirmed', 'updated') THEN 0 ELSE 1 END ASC,
          a.last_seen_at DESC NULLS LAST,
          a.sighting_count DESC NULLS LAST,
          a.alias_value ASC
      ) AS rn
    FROM platform.device_alias_states a
    WHERE a.device_id = ANY($1::text[])
      AND a.alias_type = 'ip'
      AND a.state IN ('confirmed', 'updated', 'detected')
      -- An alias not seen within the window is an address the device
      -- has most likely left (ServiceRadar.SweepJobs.AliasRecency).
      AND a.last_seen_at >= (now() AT TIME ZONE 'utc') - make_interval(days => $3)
      AND NOT EXISTS (
        SELECT 1
        FROM platform.ocsf_devices d
        WHERE d.deleted_at IS NULL
          AND COALESCE(d.partition, 'default') = COALESCE(a.partition, 'default')
          AND (CASE WHEN pg_input_is_valid(d.ip, 'inet') THEN d.ip::inet END) =
            (CASE WHEN pg_input_is_valid(a.alias_value, 'inet') THEN a.alias_value::inet END)
      )
  ) ranked
  WHERE ranked.rn <= $2
  ORDER BY ranked.device_id ASC, ranked.rn ASC
  """

  defp load_active_device_alias_ips(uids) when is_list(uids) do
    limit = max_alias_targets_per_device()

    uids
    |> Enum.chunk_every(@alias_lookup_chunk_size)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Repo.query(@active_device_alias_ips_sql, [chunk, limit, AliasRecency.max_age_days()]) do
        {:ok, %{rows: rows}} ->
          chunk_map =
            Enum.group_by(
              rows,
              fn [device_id, _alias_value] -> device_id end,
              fn [_device_id, alias_value] -> alias_value end
            )

          {:cont, {:ok, Map.merge(acc, chunk_map)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_device_targets(rows, group, query, modes) do
    primary_targets =
      Enum.reduce(rows, %{}, &put_device_target_from_row(&1, &2, group, modes))

    device_targets =
      rows
      |> Enum.reduce(primary_targets, &put_alias_targets_from_row(&1, &2, group, modes))
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
    case device_ip_target(Map.get(row, "ip")) do
      nil ->
        targets

      {target, key} ->
        Map.put_new(targets, key, device_target_from_row(row, target, group, modes))
    end
  end

  defp put_device_target_from_row(_row, targets, _group, _modes), do: targets

  defp put_alias_targets_from_row(%{"alias_ips" => alias_ips} = row, targets, group, modes)
       when is_list(alias_ips) do
    Enum.reduce(alias_ips, targets, fn alias_ip, acc ->
      case device_ip_target(alias_ip) do
        nil -> acc
        {target, key} -> Map.put_new(acc, key, device_target_from_row(row, target, group, modes))
      end
    end)
  end

  defp put_alias_targets_from_row(_row, targets, _group, _modes), do: targets

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

  defp device_ip_target(value) when is_binary(value) do
    target = String.trim(value)

    case :inet.parse_strict_address(String.to_charlist(target)) do
      {:ok, address} -> {target, address}
      {:error, _} -> nil
    end
  end

  defp device_ip_target(_value), do: nil

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

  # Modes an agent runs only when it can open the sockets they need: raw ICMP
  # for the ICMP sweep scanner, any ICMP socket for MTR. An agent that cannot
  # reports the mode's `.unavailable` marker, and the mode is withheld from it.
  # An agent reporting neither the mode nor its marker predates the marker and
  # keeps every mode, so upgrading core never stops its sweeps.
  @capability_gated_modes ["icmp", "mtr"]

  defp withhold_unavailable_modes(modes, capabilities) do
    reported = MapSet.new(capabilities || [], &to_string/1)

    Enum.split_with(modes, fn mode ->
      mode not in @capability_gated_modes or
        not MapSet.member?(reported, unavailable_marker(mode))
    end)
  end

  defp unavailable_marker(mode), do: mode <> ".unavailable"

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
