defmodule ServiceRadar.AgentConfig.Compilers.NetperfCompiler do
  @moduledoc """
  Compiler for embedded agent network performance (`:netperf`) configurations.

  Transforms `NetperfProfile`, `NetperfResponder`, `NetperfPolicy`, and
  `NetperfPolicyResponder` Ash resources into per-agent compiled configuration
  containing:

  - `"responder"`: Hub Responder listener settings (disabled unless the agent has
    an enabled `NetperfResponder` record).
  - `"targets"`: Deterministic list of outbound `NetperfTargetAssignment` maps
    with Ed25519-signed `NetperfPermitV1` tokens for matched `:hub_and_spoke`
    or `:hub_mesh` policies (never `self -> self`).
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NetperfPermitSigning
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.NetperfPolicy
  alias ServiceRadar.Monitoring.NetperfPolicyResponder
  alias ServiceRadar.Monitoring.NetperfProfile
  alias ServiceRadar.Monitoring.NetperfResponder
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadar.Repo
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  require Ash.Query
  require Logger

  @impl true
  def config_type, do: :netperf

  @impl true
  def source_resources do
    [NetperfProfile, NetperfResponder, NetperfPolicy, NetperfPolicyResponder]
  end

  @doc """
  Returns the default disabled netperf config.
  """
  @spec disabled_config() :: map()
  def disabled_config do
    %{
      "enabled" => false,
      "responder" => %{
        "enabled" => false,
        "listen_port" => 5199,
        "udp_enabled" => false,
        "max_concurrent_sessions" => 0,
        "max_total_bandwidth_bps" => 0,
        "advertise_address" => "",
        "min_authority_epoch" => 0
      },
      "targets" => [],
      "config_epoch" => 0
    }
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    cond do
      not is_binary(agent_id) or String.trim(agent_id) == "" ->
        {:ok, disabled_config()}

      not repo_ready?() ->
        {:error, :repo_unavailable}

      true ->
        do_compile(partition, String.trim(agent_id), opts)
    end
  rescue
    e ->
      Logger.error("NetperfCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  defp do_compile(partition, agent_id, opts) do
    actor = opts[:actor] || SystemActor.system(:netperf_compiler)

    with {:ok, agent} <- load_agent(agent_id, actor),
         {:ok, responders} <- load_responders(actor),
         {:ok, policies} <- load_enabled_policies(actor) do
      case agent do
        nil ->
          {:ok, disabled_config()}

        %Agent{} = found_agent ->
          compile_inputs(
            found_agent,
            responders,
            policies,
            Keyword.put_new(opts, :partition, partition)
          )
      end
    end
  end

  @doc """
  Pure/injectable compilation entrypoint given a loaded `Agent`, list of
  `NetperfResponder` structs (with `:agent` preloaded if `advertise_address`
  falls back to agent IP/host), and enabled `NetperfPolicy` structs (with
  `:profile` and `:responders` preloaded).

  Options:
  - `:partition` - authoritative partition fallback for the agent
  - `:issuer_key` - optional `IssuerKey.t()` override (useful in DB-free tests)
  - `:now` - `DateTime.t()` override (useful in DB-free tests)
  - `:query_page_fn` - optional `fn input_def, acc, fun -> ... end` override for SRQL selectors
  """
  @spec compile_inputs(map(), [map()], [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def compile_inputs(agent, responders, policies, opts \\ [])
      when is_map(agent) and is_list(responders) and is_list(policies) do
    agent_uid = Map.fetch!(agent, :uid)
    partition_id = resolve_agent_partition(agent, Keyword.get(opts, :partition))

    responder_by_uid =
      Map.new(responders, fn responder ->
        {Map.fetch!(responder, :agent_uid), responder}
      end)

    local_responder = Map.get(responder_by_uid, agent_uid)
    responder_config = build_responder_config(local_responder)

    with {:ok, targets} <-
           compile_targets(agent, partition_id, policies, responder_by_uid, opts) do
      config_epoch = max_authority_epoch(local_responder, policies)

      {:ok,
       %{
         "enabled" => responder_config["enabled"] || targets != [],
         "responder" => responder_config,
         "targets" => targets,
         "config_epoch" => config_epoch
       }}
    end
  end

  defp compile_targets(agent, partition_id, policies, responder_by_uid, opts) do
    agent_uid = Map.fetch!(agent, :uid)

    policies
    |> Enum.filter(&policy_enabled?/1)
    |> Enum.sort_by(&to_string(Map.get(&1, :id, "")))
    |> Enum.reduce_while({:ok, [], %{}}, fn policy, {:ok, acc, srql_cache} ->
      case compile_policy_targets(
             policy,
             agent,
             agent_uid,
             partition_id,
             responder_by_uid,
             srql_cache,
             opts
           ) do
        {:ok, policy_targets, next_cache} ->
          {:cont, {:ok, acc ++ policy_targets, next_cache}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, targets, _cache} ->
        sorted =
          Enum.sort_by(targets, fn t ->
            {t["policy_id"], t["responder_agent_id"]}
          end)

        {:ok, sorted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_policy_targets(
         policy,
         agent,
         agent_uid,
         partition_id,
         responder_by_uid,
         srql_cache,
         opts
       ) do
    profile = Map.get(policy, :profile)
    attached_responders = policy |> Map.get(:responders, []) |> Enum.filter(&responder_enabled?/1)

    with true <- is_map(profile),
         {:ok, matched?, next_cache} <-
           agent_matches_policy?(
             policy,
             agent,
             agent_uid,
             partition_id,
             attached_responders,
             srql_cache,
             opts
           ) do
      if matched? do
        targets_result =
          attached_responders
          |> Enum.reject(&(Map.get(&1, :agent_uid) == agent_uid))
          |> Enum.sort_by(&to_string(Map.get(&1, :agent_uid, "")))
          |> Enum.reduce_while({:ok, []}, fn responder, {:ok, targets_acc} ->
            case build_target_assignment(
                   policy,
                   profile,
                   responder,
                   responder_by_uid,
                   agent_uid,
                   partition_id,
                   opts
                 ) do
              {:ok, nil} -> {:cont, {:ok, targets_acc}}
              {:ok, target} -> {:cont, {:ok, [target | targets_acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case targets_result do
          {:ok, built} -> {:ok, Enum.reverse(built), next_cache}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, [], next_cache}
      end
    else
      false -> {:ok, [], srql_cache}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_target_assignment(
         policy,
         profile,
         responder,
         responder_by_uid,
         sender_agent_id,
         partition_id,
         opts
       ) do
    responder_uid = Map.fetch!(responder, :agent_uid)
    full_responder = Map.get(responder_by_uid, responder_uid, responder)

    case resolve_target_address(full_responder) do
      nil ->
        Logger.warning(
          "NetperfCompiler: skipping responder #{responder_uid} for policy #{policy.id} (no dialable address)"
        )

        {:ok, nil}

      address ->
        with {:ok, permit} <-
               NetperfPermitSigning.sign_scheduled(
                 policy,
                 profile,
                 full_responder,
                 sender_agent_id,
                 partition_id,
                 opts
               ) do
          {:ok,
           %{
             "policy_id" => to_string(Map.fetch!(policy, :id)),
             "policy_name" => Map.get(policy, :name, "") || "",
             "profile_id" => to_string(Map.fetch!(profile, :id)),
             "profile_name" => Map.get(profile, :name, "") || "",
             "responder_agent_id" => responder_uid,
             "responder_label" => Map.get(full_responder, :name, responder_uid) || responder_uid,
             "target_address" => address,
             "target_port" => Map.get(full_responder, :listen_port, 5199) || 5199,
             "protocol" => to_string(Map.get(profile, :protocol, :tcp)),
             "direction" => to_string(Map.get(profile, :direction, :upload)),
             "bandwidth_bps" => Map.get(profile, :bandwidth_bps, 50_000_000),
             "duration_sec" => Map.get(profile, :duration_sec, 5),
             "omit_sec" => Map.get(profile, :omit_sec, 1),
             "parallel" => Map.get(profile, :parallel, 1),
             "packet_length" => Map.get(profile, :packet_length, 1200),
             "interval_seconds" => Map.get(profile, :interval_seconds, 900),
             "permit" => NetperfPermitSigning.to_compiled_map(permit)
           }}
        end
    end
  end

  defp agent_matches_policy?(
         %{mode: :hub_mesh},
         _agent,
         agent_uid,
         _partition_id,
         attached_responders,
         srql_cache,
         _opts
       ) do
    matched? = Enum.any?(attached_responders, &(Map.get(&1, :agent_uid) == agent_uid))
    {:ok, matched?, srql_cache}
  end

  defp agent_matches_policy?(
         %{mode: :hub_and_spoke, spoke_selector: selector},
         agent,
         agent_uid,
         partition_id,
         attached_responders,
         srql_cache,
         opts
       ) do
    # Exclude hub responders attached to this policy from acting as spokes on the same policy.
    is_attached_hub? = Enum.any?(attached_responders, &(Map.get(&1, :agent_uid) == agent_uid))

    if is_attached_hub? do
      {:ok, false, srql_cache}
    else
      match_spoke_selector(selector || %{}, agent, partition_id, srql_cache, opts)
    end
  end

  defp agent_matches_policy?(
         _policy,
         _agent,
         _agent_uid,
         _partition_id,
         _responders,
         cache,
         _opts
       ) do
    {:ok, false, cache}
  end

  defp match_spoke_selector(selector, agent, partition_id, srql_cache, opts)
       when is_map(selector) do
    agent_uids = selector_value(selector, "agent_uids")
    selector_partition = selector_value(selector, "partition_id")
    selector_tags = selector_value(selector, "tags")
    srql_query = selector_value(selector, "srql_query")

    with true <- match_agent_uids?(agent_uids, agent.uid),
         true <- match_partition?(selector_partition, partition_id),
         true <- match_tags?(selector_tags, agent),
         {:ok, srql_ok?, next_cache} <- match_srql?(srql_query, agent, srql_cache, opts) do
      {:ok, srql_ok?, next_cache}
    else
      false -> {:ok, false, srql_cache}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_agent_uids?(nil, _uid), do: true
  defp match_agent_uids?([], _uid), do: true
  defp match_agent_uids?(uids, uid) when is_list(uids), do: uid in Enum.map(uids, &to_string/1)
  defp match_agent_uids?(_, _), do: false

  defp match_partition?(nil, _partition_id), do: true
  defp match_partition?("", _partition_id), do: true

  defp match_partition?(expected, actual) when is_binary(expected) do
    trimmed = String.trim(expected)
    trimmed == "" or trimmed == actual
  end

  defp match_partition?(_, _), do: false

  defp match_tags?(nil, _agent), do: true
  defp match_tags?(tags, _agent) when is_map(tags) and map_size(tags) == 0, do: true

  defp match_tags?(tags, agent) when is_map(tags) do
    agent_tags = extract_agent_tags(agent)

    Enum.all?(tags, fn {k, v} ->
      key = to_string(k)
      expected = to_string(v)

      case Map.fetch(agent_tags, key) do
        {:ok, actual} -> to_string(actual) == expected
        :error -> false
      end
    end)
  end

  defp match_tags?(_, _), do: false

  defp extract_agent_tags(agent) do
    device_tags =
      case Map.get(agent, :device) do
        %{tags: tags} when is_map(tags) -> stringify_map_keys(tags)
        _ -> %{}
      end

    metadata_tags =
      case Map.get(agent, :metadata) do
        %{"tags" => tags} when is_map(tags) -> stringify_map_keys(tags)
        %{tags: tags} when is_map(tags) -> stringify_map_keys(tags)
        _ -> %{}
      end

    Map.merge(device_tags, metadata_tags)
  end

  defp match_srql?(nil, _agent, cache, _opts), do: {:ok, true, cache}

  defp match_srql?(query, agent, cache, opts) when is_binary(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:ok, true, cache}
    else
      with {:ok, match_set, next_cache} <- resolve_srql_match_set(trimmed, cache, opts) do
        matched? =
          case match_set do
            {:agents, uids} ->
              MapSet.member?(uids, agent.uid)

            {:devices, device_uids, agent_ids} ->
              (is_binary(agent.device_uid) and MapSet.member?(device_uids, agent.device_uid)) or
                MapSet.member?(agent_ids, agent.uid)
          end

        {:ok, matched?, next_cache}
      end
    end
  end

  defp match_srql?(_, _agent, cache, _opts), do: {:ok, false, cache}

  defp resolve_srql_match_set(query, cache, opts) do
    case Map.fetch(cache, query) do
      {:ok, match_set} ->
        {:ok, match_set, cache}

      :error ->
        normalized = SRQLQuery.ensure_target(query, :agents)
        entity = SRQLAst.entity(normalized) || "agents"
        input_def = %{name: "netperf_spoke_selector", entity: entity, query: normalized}

        initial_acc =
          case entity do
            "devices" -> {:devices, MapSet.new(), MapSet.new()}
            _ -> {:agents, MapSet.new()}
          end

        query_page_fn =
          Keyword.get(opts, :query_page_fn, fn defn, acc, fun ->
            SRQLInputResolver.reduce_pages(defn, acc, fun, Keyword.take(opts, [:runner]))
          end)

        case query_page_fn.(input_def, initial_acc, &accumulate_srql_page/2) do
          {:ok, match_set} -> {:ok, match_set, Map.put(cache, query, match_set)}
          {:error, reason} -> {:error, {:srql_selector_failed, reason}}
        end
    end
  end

  defp accumulate_srql_page(rows, {:agents, uids}) when is_list(rows) do
    next =
      Enum.reduce(rows, uids, fn row, set ->
        case Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") ||
               Map.get(row, :id) do
          uid when is_binary(uid) and uid != "" -> MapSet.put(set, uid)
          _ -> set
        end
      end)

    {:cont, {:agents, next}}
  end

  defp accumulate_srql_page(rows, {:devices, device_uids, agent_ids}) when is_list(rows) do
    {next_devices, next_agents} =
      Enum.reduce(rows, {device_uids, agent_ids}, fn row, {d_set, a_set} ->
        d_uid = Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "device_uid")
        a_id = Map.get(row, "agent_id") || Map.get(row, :agent_id)

        d_set = if is_binary(d_uid) and d_uid != "", do: MapSet.put(d_set, d_uid), else: d_set
        a_set = if is_binary(a_id) and a_id != "", do: MapSet.put(a_set, a_id), else: a_set
        {d_set, a_set}
      end)

    {:cont, {:devices, next_devices, next_agents}}
  end

  defp build_responder_config(%{enabled: true} = responder) do
    %{
      "enabled" => true,
      "listen_port" => Map.get(responder, :listen_port, 5199) || 5199,
      "udp_enabled" => Map.get(responder, :udp_enabled, true) == true,
      "max_concurrent_sessions" => Map.get(responder, :max_concurrent_sessions, 4) || 4,
      "max_total_bandwidth_bps" =>
        Map.get(responder, :max_total_bandwidth_bps, 1_000_000_000) || 1_000_000_000,
      "advertise_address" => resolve_target_address(responder) || "",
      "min_authority_epoch" => Map.get(responder, :authority_epoch, 1) || 1
    }
  end

  defp build_responder_config(_responder), do: disabled_config()["responder"]

  defp resolve_target_address(responder) do
    candidates = [
      Map.get(responder, :advertise_address),
      get_in_agent(responder, :ip),
      get_in_agent(responder, :host)
    ]

    Enum.find_value(candidates, fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end)
  end

  defp get_in_agent(responder, field) do
    case Map.get(responder, :agent) do
      %{} = agent -> Map.get(agent, field)
      _ -> nil
    end
  end

  defp resolve_agent_partition(agent, explicit_partition) do
    candidates = [
      explicit_partition,
      metadata_value(Map.get(agent, :metadata), "partition_id"),
      gateway_partition_slug(Map.get(agent, :gateway)),
      device_partition(Map.get(agent, :device)),
      "default"
    ]

    Enum.find_value(candidates, "default", fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end)
  end

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(_, _), do: nil

  defp gateway_partition_slug(%{partition: %{slug: slug}}) when is_binary(slug), do: slug
  defp gateway_partition_slug(_), do: nil

  defp device_partition(%{partition: partition}) when is_binary(partition), do: partition
  defp device_partition(_), do: nil

  defp max_authority_epoch(local_responder, policies) do
    resp_epoch =
      if local_responder, do: Map.get(local_responder, :authority_epoch, 0) || 0, else: 0

    Enum.reduce(policies, resp_epoch, fn policy, acc ->
      max(acc, Map.get(policy, :authority_epoch, 0) || 0)
    end)
  end

  defp policy_enabled?(%{enabled: true}), do: true
  defp policy_enabled?(_), do: false

  defp responder_enabled?(%{enabled: true}), do: true
  defp responder_enabled?(_), do: false

  defp selector_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: v
          _ -> nil
        end)
    end
  end

  defp stringify_map_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp load_agent(agent_id, actor) do
    Agent
    |> Ash.Query.for_read(:by_uid, %{uid: agent_id})
    |> Ash.Query.load([:device, gateway: :partition])
    |> Ash.read_one(actor: actor)
  end

  defp load_responders(actor) do
    NetperfResponder
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.load([:agent])
    |> Ash.read(actor: actor)
  end

  defp load_enabled_policies(actor) do
    NetperfPolicy
    |> Ash.Query.for_read(:enabled, %{})
    |> Ash.Query.load([:profile, responders: [:agent]])
    |> Ash.read(actor: actor)
  end

  defp repo_ready? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false and
      is_pid(Process.whereis(Repo))
  end
end
