defmodule ServiceRadar.DeclarativeChecks.AssignmentCompiler do
  @moduledoc """
  Compiles enabled Edge-only and Hybrid `DeclarativeCheck` records into
  deterministic agent plugin assignment specs targeting
  `io.serviceradar.declarative-check-runner` (`3.3`, Decision 4).

  Supports `singleton`, `srql_devices`, and `service_targets` bindings, extracts
  per-agent Edge subgraphs for Hybrid or multi-vantage checks, computes minimal
  sorted host/port/scheme/network allowlists, and embeds secret-free
  `CredentialBrokerGrant` wire descriptors from `DeclarativeCheckCredentialBinding`
  without ever placing plaintext secret material in assignment params.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.Scope
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.DeclarativeChecks.CredentialResolver
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding
  alias ServiceRadar.DeclarativeChecks.NodeEvaluators
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.StorageToken

  require Ash.Query
  require Logger

  @plugin_id "io.serviceradar.declarative-check-runner"
  @plugin_name "Declarative Check Runner"
  @entrypoint "run_check"
  @runtime "wasi-preview1"
  @outputs "serviceradar.plugin_result.v1"
  @assignment_schema "serviceradar.declarative_check_assignment.v1"
  @default_chunk_size 100
  @default_interval_sec 60
  @default_timeout_sec 30
  @system_actor SystemActor.system(:declarative_check_assignment_compiler)

  @edge_probe_kinds ~w(http_request http_journey tcp_connect tls_handshake dns_lookup)
  @edge_local_transform_kinds ~w(extract_field threshold_assert)

  @capabilities [
    "get_config",
    "log",
    "submit_result",
    "emit_telemetry",
    "http_request",
    "tcp_connect",
    "tcp_read",
    "tcp_write",
    "tcp_close"
  ]

  @default_resources %{
    requested_memory_mb: 64,
    requested_cpu_ms: 4000,
    max_open_connections: 8
  }

  @doc "Canonical first-party plugin identifier for the Edge declarative check runner."
  @spec plugin_id() :: String.t()
  def plugin_id, do: @plugin_id

  @doc "Canonical JSON config schema version delivered to the Edge runner."
  @spec assignment_schema() :: String.t()
  def assignment_schema, do: @assignment_schema

  @doc """
  Compiles all enabled Edge-bearing `DeclarativeCheck` assignments scoped to
  `agent_id` into `AgentConfigGenerator`-compatible plugin assignment maps.
  """
  @spec compile_for_agent(String.t(), String.t() | nil, keyword()) :: [map()]
  def compile_for_agent(agent_id, _partition_id \\ "default", opts \\ [])
      when is_binary(agent_id) and is_list(opts) do
    trimmed_agent = String.trim(agent_id)

    if trimmed_agent == "" do
      []
    else
      actor = Keyword.get(opts, :actor, @system_actor)
      package = resolve_runner_package(opts, actor)

      if is_nil(package) and Keyword.get(opts, :require_approved_package?, true) do
        []
      else
        checks = load_enabled_checks(opts, actor)

        checks
        |> Enum.flat_map(fn check ->
          compile_opts =
            opts
            |> Keyword.put(:for_agent_id, trimmed_agent)
            |> Keyword.put(:default_agent_id, trimmed_agent)

          {:ok, specs} = compile_check(check, compile_opts)
          Enum.filter(specs, &(&1.agent_id == trimmed_agent))
        end)
        |> Enum.map(&to_agent_plugin_assignment(&1, package))
        |> Enum.sort_by(& &1.assignment_id)
      end
    end
  rescue
    error ->
      Logger.warning(
        "Failed compiling declarative check assignments for agent #{agent_id}: #{Exception.message(error)}"
      )

      []
  end

  @doc """
  Compiles a single `DeclarativeCheck` into deterministic per-agent, per-chunk
  assignment specs. Returns `{:ok, []}` for disabled/draft or `:core_only` checks.
  """
  @spec compile_check(map() | struct(), keyword()) :: {:ok, [map()]}
  def compile_check(check, opts \\ []) when is_map(check) and is_list(opts) do
    if active_check?(check, opts) do
      nodes = normalize_nodes(fetch_val(check, :nodes, []))
      edges = normalize_edges(fetch_val(check, :edges, []))
      topology = SchemaValidator.classify_topology(nodes)

      if topology == :core_only do
        {:ok, []}
      else
        do_compile_edge_check(check, topology, nodes, edges, opts)
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Deterministically computes the UUIDv5-shaped `assignment_id` for a
  `(check_id, agent_id, chunk_index)` tuple.
  """
  @spec deterministic_assignment_id(String.t(), String.t(), non_neg_integer()) :: String.t()
  def deterministic_assignment_id(check_id, agent_id, chunk_index \\ 0)
      when is_binary(check_id) and is_binary(agent_id) and is_integer(chunk_index) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(
        :sha256,
        "declarative_check_assignment:v1:#{check_id}:#{agent_id}:#{chunk_index}"
      )

    c_v5 = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x5000)
    d_var = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a, b, c_v5, d_var, e])
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns true when `check` is a pure `:edge_only` check whose Edge probe nodes
  all execute on a single agent vantage point.
  """
  @spec single_agent_edge_only?(map() | struct()) :: boolean()
  def single_agent_edge_only?(check) when is_map(check) do
    nodes = normalize_nodes(fetch_val(check, :nodes, []))

    if SchemaValidator.classify_topology(nodes) == :edge_only do
      explicit_agents =
        nodes
        |> Enum.filter(&(&1["kind"] in @edge_probe_kinds))
        |> Enum.map(&get_in(&1, ["config", "agent_id"]))
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.map(&String.trim/1)
        |> Enum.uniq()

      length(explicit_agents) <= 1
    else
      false
    end
  end

  ## Internal Compilation Pipeline

  defp do_compile_edge_check(check, topology, nodes, edges, opts) do
    check_id = to_string(fetch_val(check, :id, "00000000-0000-4000-8000-000000000000"))
    slug = to_string(fetch_val(check, :slug, "declarative-check"))
    name = to_string(fetch_val(check, :name, slug))
    schedule = stringify_map(fetch_val(check, :schedule, %{}))
    interval_sec = int_or_default(Map.get(schedule, "interval_seconds"), @default_interval_sec)
    timeout_sec = int_or_default(Map.get(schedule, "timeout_seconds"), @default_timeout_sec)

    inputs_decl = check |> fetch_val(:inputs, []) |> List.wrap() |> Enum.map(&stringify_map/1)
    overrides = stringify_map(fetch_val(check, :parameter_overrides, %{}))
    effective_inputs = NodeEvaluators.resolve_effective_inputs(inputs_decl, overrides)
    rendered_inputs = build_rendered_inputs(inputs_decl, effective_inputs)

    cred_bindings_by_slot = load_credential_bindings_by_slot(check, opts)
    raw_targets = resolve_targets(check, opts)
    single_complete? = topology == :edge_only and single_agent_edge_only?(check)
    chunk_size = max(1, Keyword.get(opts, :chunk_size, @default_chunk_size))

    agent_plans = build_agent_subgraphs(nodes, edges, raw_targets, single_complete?, opts)

    specs =
      agent_plans
      |> Enum.sort_by(fn {agent_id, _plan} -> agent_id end)
      |> Enum.flat_map(fn {agent_id, plan} ->
        plan.targets
        |> Enum.sort_by(& &1["target_key"])
        |> Enum.chunk_every(chunk_size)
        |> Enum.with_index()
        |> Enum.flat_map(fn {target_chunk, chunk_idx} ->
          build_chunk_spec(%{
            check: check,
            check_id: check_id,
            slug: slug,
            name: name,
            topology: topology,
            single_complete?: single_complete?,
            interval_sec: interval_sec,
            timeout_sec: timeout_sec,
            effective_inputs: effective_inputs,
            rendered_inputs: rendered_inputs,
            cred_bindings_by_slot: cred_bindings_by_slot,
            agent_id: agent_id,
            sub_nodes: plan.nodes,
            sub_edges: plan.edges,
            output_node_ids: plan.output_node_ids,
            targets: target_chunk,
            chunk_idx: chunk_idx,
            opts: opts
          })
        end)
      end)

    {:ok, specs}
  end

  defp build_chunk_spec(ctx) do
    referenced_slots = collect_referenced_slots(ctx.sub_nodes)

    {prepared_targets, allow_acc} =
      Enum.reduce(ctx.targets, {[], empty_allow_acc()}, fn target, {t_acc, a_acc} ->
        case prepare_target_and_allowlist(
               ctx.check,
               target,
               ctx.sub_nodes,
               ctx.effective_inputs,
               referenced_slots,
               ctx.cred_bindings_by_slot,
               ctx.agent_id,
               ctx.opts
             ) do
          {:ok, prepared_target, target_allow} ->
            {[prepared_target | t_acc], merge_allow_acc(a_acc, target_allow)}

          {:error, reason} ->
            Logger.warning(
              "Dropping target #{inspect(target["target_key"])} on check #{ctx.slug}: #{inspect(reason)}"
            )

            {t_acc, a_acc}
        end
      end)

    prepared_targets = Enum.reverse(prepared_targets)

    if prepared_targets == [] do
      []
    else
      allowlist = finalize_allowlist(allow_acc)
      assignment_id = deterministic_assignment_id(ctx.check_id, ctx.agent_id, ctx.chunk_idx)

      params = %{
        "schema" => @assignment_schema,
        "check_id" => ctx.check_id,
        "slug" => ctx.slug,
        "name" => ctx.name,
        "topology" => Atom.to_string(ctx.topology),
        "single_agent_complete" => ctx.single_complete?,
        "timeout_ms" => ctx.timeout_sec * 1_000,
        "allowlist" => %{
          "schemes" => allowlist.schemes,
          "hosts" => allowlist.domains,
          "networks" => allowlist.networks,
          "ports" => allowlist.ports
        },
        "inputs" => ctx.rendered_inputs,
        "nodes" => Enum.map(ctx.sub_nodes, &compile_node_wire/1),
        "edges" => Enum.map(ctx.sub_edges, &compile_edge_wire/1),
        "output_node_ids" => ctx.output_node_ids,
        "targets" => prepared_targets
      }

      permissions = %{
        allowed_domains: allowlist.domains,
        allowed_networks: allowlist.networks,
        allowed_ports: allowlist.ports
      }

      [
        %{
          assignment_id: assignment_id,
          agent_id: ctx.agent_id,
          check_id: ctx.check_id,
          slug: ctx.slug,
          name: ctx.name,
          chunk_index: ctx.chunk_idx,
          topology: ctx.topology,
          single_agent_complete: ctx.single_complete?,
          interval_sec: ctx.interval_sec,
          timeout_sec: ctx.timeout_sec,
          params: params,
          permissions: permissions,
          allowlist: allowlist
        }
      ]
    end
  end

  defp build_agent_subgraphs(nodes, edges, raw_targets, true = _single_complete?, opts) do
    default_agent = Keyword.get(opts, :default_agent_id, "default-agent")

    explicit_agent =
      nodes
      |> Enum.filter(&(&1["kind"] in @edge_probe_kinds))
      |> Enum.find_value(fn n -> non_empty_str(get_in(n, ["config", "agent_id"])) end)

    output_ids =
      nodes
      |> Enum.filter(&(&1["kind"] == "alert_output"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    grouped_targets =
      Enum.group_by(raw_targets, fn tgt ->
        explicit_agent || non_empty_str(tgt["agent_id"]) || default_agent
      end)

    Map.new(grouped_targets, fn {agent_id, tgts} ->
      {agent_id, %{nodes: nodes, edges: edges, output_node_ids: output_ids, targets: tgts}}
    end)
  end

  defp build_agent_subgraphs(nodes, edges, raw_targets, false = _single_complete?, opts) do
    default_agent = Keyword.get(opts, :default_agent_id, "default-agent")
    nodes_by_id = Map.new(nodes, &{&1["id"], &1})
    incoming_by_dst = Enum.group_by(edges, & &1["target"])
    outgoing_by_src = Enum.group_by(edges, & &1["source"])
    edge_probes = Enum.filter(nodes, &(&1["kind"] in @edge_probe_kinds))

    raw_targets
    |> Enum.reduce(%{}, fn tgt, acc ->
      target_agent = non_empty_str(tgt["agent_id"]) || default_agent

      probes_by_agent =
        Enum.group_by(edge_probes, fn probe ->
          non_empty_str(get_in(probe, ["config", "agent_id"])) || target_agent
        end)

      Enum.reduce(probes_by_agent, acc, fn {agent_id, agent_probes}, inner_acc ->
        probe_ids = MapSet.new(Enum.map(agent_probes, & &1["id"]))

        expanded_ids =
          expand_pure_edge_transforms(probe_ids, nodes_by_id, incoming_by_dst, outgoing_by_src)

        sub_nodes = Enum.filter(nodes, &MapSet.member?(expanded_ids, &1["id"]))

        sub_edges =
          Enum.filter(edges, fn e ->
            MapSet.member?(expanded_ids, e["source"]) and
              MapSet.member?(expanded_ids, e["target"])
          end)

        boundary_ids =
          expanded_ids
          |> Enum.filter(fn nid ->
            outs = Map.get(outgoing_by_src, nid, [])
            outs == [] or Enum.any?(outs, &(not MapSet.member?(expanded_ids, &1["target"])))
          end)
          |> Enum.sort()

        existing =
          Map.get(inner_acc, agent_id, %{
            node_map: %{},
            edge_set: MapSet.new(),
            output_set: MapSet.new(),
            targets_by_key: %{}
          })

        merged_node_map =
          Enum.reduce(sub_nodes, existing.node_map, &Map.put(&2, &1["id"], &1))

        merged_edge_set =
          Enum.reduce(sub_edges, existing.edge_set, &MapSet.put(&2, &1))

        merged_output_set =
          Enum.reduce(boundary_ids, existing.output_set, &MapSet.put(&2, &1))

        merged_targets = Map.put(existing.targets_by_key, tgt["target_key"], tgt)

        Map.put(inner_acc, agent_id, %{
          node_map: merged_node_map,
          edge_set: merged_edge_set,
          output_set: merged_output_set,
          targets_by_key: merged_targets
        })
      end)
    end)
    |> Map.new(fn {agent_id, entry} ->
      ordered_sub_nodes = Enum.filter(nodes, &Map.has_key?(entry.node_map, &1["id"]))

      ordered_sub_edges = Enum.filter(edges, &MapSet.member?(entry.edge_set, &1))

      {agent_id,
       %{
         nodes: ordered_sub_nodes,
         edges: ordered_sub_edges,
         output_node_ids: entry.output_set |> MapSet.to_list() |> Enum.sort(),
         targets: Map.values(entry.targets_by_key)
       }}
    end)
  end

  defp expand_pure_edge_transforms(owned_ids, nodes_by_id, incoming_by_dst, outgoing_by_src) do
    candidates =
      owned_ids
      |> Enum.flat_map(fn nid ->
        outgoing_by_src
        |> Map.get(nid, [])
        |> Enum.map(& &1["target"])
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(owned_ids, &1))
      |> Enum.filter(fn dst_id ->
        dst_node = Map.get(nodes_by_id, dst_id)
        in_edges = Map.get(incoming_by_dst, dst_id, [])

        not is_nil(dst_node) and dst_node["kind"] in @edge_local_transform_kinds and
          in_edges != [] and Enum.all?(in_edges, &MapSet.member?(owned_ids, &1["source"]))
      end)

    if candidates == [] do
      owned_ids
    else
      owned_ids
      |> MapSet.union(MapSet.new(candidates))
      |> expand_pure_edge_transforms(nodes_by_id, incoming_by_dst, outgoing_by_src)
    end
  end

  ## Target Resolution

  defp resolve_targets(check, opts) do
    binding = stringify_map(fetch_val(check, :target_binding, %{"mode" => "singleton"}))
    mode = Map.get(binding, "mode", "singleton")

    case mode do
      "srql_devices" -> resolve_srql_device_targets(binding, opts)
      "service_targets" -> resolve_service_targets(binding, opts)
      _ -> [build_singleton_target(binding)]
    end
  end

  defp build_singleton_target(binding) do
    %{
      "target_key" => "singleton",
      "target_kind" => "singleton",
      "url" => Map.get(binding, "url"),
      "host" => Map.get(binding, "host"),
      "port" => Map.get(binding, "port"),
      "attributes" => stringify_map(Map.get(binding, "metadata", %{}))
    }
  end

  defp resolve_srql_device_targets(binding, opts) do
    devices =
      case Keyword.get(opts, :devices_loader) do
        loader when is_function(loader, 1) ->
          loader.(binding)

        _ ->
          load_devices_from_scope(Map.get(binding, "scope_query", "in:devices"), opts)
      end

    Enum.flat_map(devices, fn dev ->
      uid = non_empty_str(fetch_val(dev, :uid))

      if is_nil(uid) do
        []
      else
        ip = non_empty_str(fetch_val(dev, :ip))
        hostname = non_empty_str(fetch_val(dev, :hostname))
        agent_id = non_empty_str(fetch_val(dev, :agent_id))
        metadata = stringify_map(fetch_val(dev, :metadata, %{}))

        [
          %{
            "target_key" => "device:#{uid}",
            "target_kind" => "device",
            "device_uid" => uid,
            "uid" => uid,
            "agent_id" => agent_id,
            "host" => hostname || ip,
            "hostname" => hostname,
            "ip" => ip,
            "port" => Map.get(binding, "port"),
            "url" => Map.get(binding, "url"),
            "attributes" => metadata
          }
        ]
      end
    end)
  end

  defp resolve_service_targets(binding, opts) do
    raw_items =
      case Keyword.get(opts, :service_targets_loader) do
        loader when is_function(loader, 1) ->
          loader.(binding)

        _ ->
          binding
          |> Map.get("target_ids", [])
          |> List.wrap()
          |> Enum.map(fn id ->
            %{
              "id" => to_string(id),
              "url" => Map.get(binding, "url"),
              "host" => Map.get(binding, "host"),
              "port" => Map.get(binding, "port")
            }
          end)
      end

    Enum.flat_map(raw_items, fn item ->
      id =
        non_empty_str(fetch_val(item, :service_target_id)) ||
          non_empty_str(fetch_val(item, :id))

      if is_nil(id) do
        []
      else
        [
          %{
            "target_key" => "service:#{id}",
            "target_kind" => "service_target",
            "service_target_id" => id,
            "id" => id,
            "agent_id" => non_empty_str(fetch_val(item, :agent_id)),
            "device_uid" => non_empty_str(fetch_val(item, :device_uid)),
            "url" => fetch_val(item, :url) || Map.get(binding, "url"),
            "host" => fetch_val(item, :host) || Map.get(binding, "host"),
            "port" => fetch_val(item, :port) || Map.get(binding, "port"),
            "attributes" => stringify_map(fetch_val(item, :metadata, %{}))
          }
        ]
      end
    end)
  end

  defp load_devices_from_scope(scope_query, opts) do
    actor = Keyword.get(opts, :actor, @system_actor)

    case Scope.normalize(scope_query) do
      {:ok, normalized} ->
        uids =
          normalized
          |> Scope.stream_uids(page_limit: 500)
          |> Enum.to_list()
          |> List.flatten()
          |> Enum.uniq()

        if uids == [] do
          []
        else
          Device
          |> Ash.Query.for_read(:read, %{}, actor: actor)
          |> Ash.Query.filter(uid in ^uids and is_nil(deleted_at))
          |> Ash.read!(actor: actor)
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  ## Allowlists & Secret-Free CredentialBrokerGrant Injection

  defp prepare_target_and_allowlist(
         check,
         target,
         sub_nodes,
         effective_inputs,
         referenced_slots,
         cred_bindings_by_slot,
         agent_id,
         opts
       ) do
    with {:ok, target_allow, slot_endpoints} <-
           extract_target_endpoints(sub_nodes, effective_inputs, target),
         {:ok, compiled_creds} <-
           issue_target_slot_grants(
             check,
             target,
             referenced_slots,
             cred_bindings_by_slot,
             slot_endpoints,
             target_allow,
             agent_id,
             opts
           ) do
      wire_target =
        %{
          "target_key" => target["target_key"],
          "target_kind" => target["target_kind"],
          "device_uid" => target["device_uid"],
          "service_target_id" => target["service_target_id"],
          "url" => target["url"],
          "host" => target["host"],
          "hostname" => target["hostname"],
          "ip" => target["ip"],
          "port" => target["port"],
          "attributes" => target["attributes"] || %{},
          "credential_bindings" => compiled_creds
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
        |> Map.new()

      {:ok, wire_target, target_allow}
    end
  end

  defp extract_target_endpoints(sub_nodes, effective_inputs, target) do
    Enum.reduce_while(sub_nodes, {:ok, empty_allow_acc(), %{}}, fn node, {:ok, acc, slot_acc} ->
      kind = node["kind"]

      if kind in @edge_probe_kinds do
        case NodeEvaluators.interpolate(node["config"] || %{}, effective_inputs, target) do
          {:ok, resolved_cfg} ->
            case accumulate_probe_endpoints(kind, resolved_cfg, target, acc, slot_acc) do
              {:ok, next_acc, next_slot_acc} -> {:cont, {:ok, next_acc, next_slot_acc}}
              {:error, _} = err -> {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      else
        {:cont, {:ok, acc, slot_acc}}
      end
    end)
  end

  defp accumulate_probe_endpoints("http_request", cfg, _target, acc, slot_acc) do
    slot = non_empty_str(cfg["credential_slot"])

    with {:ok, ep} <- parse_http_endpoint(cfg["url"]) do
      next_acc = add_endpoint_to_allow(acc, ep)
      next_slots = maybe_record_slot_endpoint(slot_acc, slot, ep)
      {:ok, next_acc, next_slots}
    end
  end

  defp accumulate_probe_endpoints("http_journey", cfg, _target, acc, slot_acc) do
    node_slot = non_empty_str(cfg["credential_slot"])
    steps = cfg |> Map.get("steps", []) |> List.wrap()

    Enum.reduce_while(steps, {:ok, acc, slot_acc}, fn step, {:ok, cur_acc, cur_slots} ->
      step_slot = non_empty_str(step["credential_slot"]) || node_slot

      case parse_http_endpoint_allowing_step_vars(step["url"]) do
        {:ok, ep} ->
          {:cont,
           {:ok, add_endpoint_to_allow(cur_acc, ep),
            maybe_record_slot_endpoint(cur_slots, step_slot, ep)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp accumulate_probe_endpoints("tcp_connect", cfg, target, acc, slot_acc) do
    host = non_empty_str(cfg["host"]) || non_empty_str(target["host"])
    port = parse_port(cfg["port"] || target["port"])

    with {:ok, ep} <- validate_host_port(host, port, nil) do
      {:ok, add_endpoint_to_allow(acc, ep), slot_acc}
    end
  end

  defp accumulate_probe_endpoints("tls_handshake", cfg, target, acc, slot_acc) do
    host = non_empty_str(cfg["host"]) || non_empty_str(target["host"])
    port = parse_port(cfg["port"] || target["port"] || 443)

    with {:ok, ep} <- validate_host_port(host, port, "https") do
      {:ok, add_endpoint_to_allow(acc, ep), slot_acc}
    end
  end

  defp accumulate_probe_endpoints("dns_lookup", cfg, target, acc, slot_acc) do
    ns =
      non_empty_str(cfg["nameserver"]) || non_empty_str(target["host"]) ||
        non_empty_str(cfg["host"])

    {host, port} = split_nameserver(ns, parse_port(target["port"]) || 53)

    with {:ok, ep} <- validate_host_port(host, port, nil) do
      {:ok, add_endpoint_to_allow(acc, ep), slot_acc}
    end
  end

  defp issue_target_slot_grants(
         _check,
         _target,
         [],
         _cred_bindings_by_slot,
         _slot_endpoints,
         _target_allow,
         _agent_id,
         _opts
       ) do
    {:ok, %{}}
  end

  defp issue_target_slot_grants(
         check,
         target,
         referenced_slots,
         cred_bindings_by_slot,
         slot_endpoints,
         target_allow,
         agent_id,
         opts
       ) do
    Enum.reduce_while(referenced_slots, {:ok, %{}}, fn slot, {:ok, acc} ->
      case Map.get(cred_bindings_by_slot, slot) do
        nil ->
          {:halt, {:error, {:missing_credential_binding, slot}}}

        binding ->
          target_spec =
            build_slot_target_spec(slot, target, slot_endpoints, target_allow, agent_id)

          case CredentialResolver.issue_slot_grant(check, binding, target_spec, opts) do
            {:ok, grant} ->
              payload = CredentialBrokerGrant.to_payload(grant)

              secret_ref =
                Map.get(payload, "credential_secret_ref") ||
                  (fetch_val(grant, :secret_id) &&
                     SecretRefs.network_credential_ref(to_string(fetch_val(grant, :secret_id))))

              inject_hint = build_slot_inject_hint(check, slot, grant)

              compiled = %{
                "slot" => slot,
                "secret_ref" => secret_ref,
                "inject" => inject_hint,
                "credential_broker" => payload
              }

              {:cont, {:ok, Map.put(acc, slot, compiled)}}

            {:error, reason} ->
              {:halt, {:error, {:credential_grant_failed, slot, reason}}}
          end
      end
    end)
  end

  defp build_slot_target_spec(slot, target, slot_endpoints, target_allow, agent_id) do
    case Map.get(slot_endpoints, slot) do
      %{url: url} when is_binary(url) and url != "" ->
        %{
          url: url,
          target_kind: target["target_kind"] || "endpoint",
          target_key: target["target_key"] || "singleton",
          agent_id: agent_id,
          resolution_location: :agent
        }

      _ ->
        fin = finalize_allowlist(target_allow)
        first_host = List.first(fin.domains) || List.first(target_allow.raw_ips) || target["host"]
        first_port = List.first(fin.ports) || target["port"] || 443
        first_scheme = List.first(fin.schemes) || "https"

        %{
          url: if(first_host, do: "#{first_scheme}://#{first_host}:#{first_port}"),
          host: first_host,
          port: first_port,
          target_kind: target["target_kind"] || "endpoint",
          target_key: target["target_key"] || "singleton",
          agent_id: agent_id,
          resolution_location: :agent
        }
    end
  end

  defp build_slot_inject_hint(check, slot, grant) do
    slot_decl =
      check
      |> fetch_val(:credential_slots, [])
      |> List.wrap()
      |> Enum.map(&stringify_map/1)
      |> Enum.find(&(Map.get(&1, "slot") == slot)) || %{}

    grant_inject = stringify_map(fetch_val(grant, :inject, %{}))
    kind = Map.get(slot_decl, "kind") || Map.get(grant_inject, "type") || "bearer_token"

    case kind do
      k when k in ["basic_auth", "http_basic_auth", "username_password"] ->
        %{"mode" => "basic_auth"}

      "http_query" ->
        %{"mode" => "http_query", "name" => Map.get(grant_inject, "name", "api_key")}

      _ ->
        %{
          "mode" => Map.get(grant_inject, "type", "http_header"),
          "name" => Map.get(grant_inject, "name", "Authorization"),
          "scheme" => Map.get(grant_inject, "scheme", "Bearer")
        }
    end
  end

  ## Wire & Package Helpers

  defp to_agent_plugin_assignment(spec, package) do
    pkg_id = (package && package.id) || "00000000-0000-4000-8000-00000000dc01"
    wasm_key = package && package.wasm_object_key
    download_req = if wasm_key, do: StorageToken.download_request(pkg_id, wasm_key)

    %{
      assignment_id: spec.assignment_id,
      plugin_id: @plugin_id,
      package_id: to_string(pkg_id),
      version: (package && package.version) || "0.1.0",
      name: "#{@plugin_name} (#{spec.slug})",
      entrypoint: (package && package.entrypoint) || @entrypoint,
      runtime: (package && package.runtime) || @runtime,
      outputs: (package && package.outputs) || @outputs,
      capabilities: @capabilities,
      params: spec.params,
      host_params: nil,
      permissions: spec.permissions,
      resources: @default_resources,
      enabled: true,
      interval_sec: spec.interval_sec,
      timeout_sec: spec.timeout_sec,
      wasm_object_key: wasm_key,
      content_hash: package && package.content_hash,
      source_type: "first_party",
      download_url: download_req && download_req.url,
      download_token: download_req && download_req.token,
      run_overrides: []
    }
  end

  defp compile_node_wire(node) do
    kind = node["kind"]
    cfg = compile_node_config(kind, node["config"] || %{})

    %{
      "id" => node["id"],
      "type" => kind,
      "kind" => kind,
      "label" => node["label"] || node["id"],
      "config" => cfg
    }
  end

  defp compile_node_config("extract_field", cfg) do
    source_type = Map.get(cfg, "source_type", "field")
    expr = Map.get(cfg, "expression")
    out_key = Map.get(cfg, "output_key")

    base =
      case source_type do
        "jsonpath" -> Map.put_new(cfg, "json_path", expr || cfg["path"])
        "header" -> Map.put_new(cfg, "header", expr || cfg["header"])
        "regex" -> Map.put_new(cfg, "regex", expr || cfg["pattern"])
        _ -> Map.put_new(cfg, "field", expr || cfg["field"])
      end

    if is_binary(out_key) and out_key != "", do: Map.put_new(base, "as", out_key), else: base
  end

  defp compile_node_config(_kind, cfg), do: cfg

  defp compile_edge_wire(edge) do
    %{
      "id" => edge["id"],
      "from" => edge["source"],
      "to" => edge["target"],
      "source" => edge["source"],
      "target" => edge["target"],
      "source_handle" => edge["source_handle"],
      "target_handle" => edge["target_handle"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_rendered_inputs(inputs_decl, effective_inputs) do
    inputs_decl
    |> Enum.map(fn decl ->
      key = Map.get(decl, "key") || Map.get(decl, "name")

      %{
        "key" => key,
        "name" => key,
        "type" => Map.get(decl, "type", "string"),
        "value" => Map.get(effective_inputs, key, Map.get(decl, "default"))
      }
    end)
    |> Enum.reject(&is_nil(&1["key"]))
  end

  defp collect_referenced_slots(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
      cfg = node["config"] || %{}
      top = non_empty_str(cfg["credential_slot"])

      step_slots =
        cfg
        |> Map.get("steps", [])
        |> List.wrap()
        |> Enum.map(&non_empty_str(stringify_map(&1)["credential_slot"]))

      Enum.reject([top | step_slots], &is_nil/1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp load_credential_bindings_by_slot(check, opts) do
    bindings =
      cond do
        Keyword.has_key?(opts, :credential_bindings) ->
          Keyword.get(opts, :credential_bindings)

        is_list(fetch_val(check, :credential_bindings)) ->
          fetch_val(check, :credential_bindings)

        not is_nil(fetch_val(check, :id)) ->
          actor = Keyword.get(opts, :actor, @system_actor)

          case DeclarativeCheckCredentialBinding.list_by_check(fetch_val(check, :id),
                 actor: actor
               ) do
            {:ok, rows} -> rows
            _ -> []
          end

        true ->
          []
      end

    bindings
    |> List.wrap()
    |> Map.new(fn b ->
      slot = to_string(fetch_val(b, :slot))
      {slot, b}
    end)
  rescue
    _ -> %{}
  end

  defp load_enabled_checks(opts, actor) do
    case Keyword.get(opts, :checks) do
      checks when is_list(checks) ->
        checks

      _ ->
        case DeclarativeCheck.list_enabled(actor: actor) do
          {:ok, rows} -> Ash.load!(rows, [:credential_bindings], actor: actor)
          _ -> []
        end
    end
  rescue
    _ -> []
  end

  defp resolve_runner_package(opts, actor) do
    case Keyword.get(opts, :runner_package) do
      %PluginPackage{} = pkg ->
        pkg

      pkg when is_map(pkg) ->
        struct(PluginPackage, pkg)

      nil ->
        PluginPackage
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(plugin_id == ^@plugin_id and status == :approved)
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one(actor: actor)
        |> case do
          {:ok, %PluginPackage{} = pkg} -> pkg
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  ## Allowlist Parsing & Normalization

  defp empty_allow_acc do
    %{
      schemes: MapSet.new(),
      domains: MapSet.new(),
      networks: MapSet.new(),
      raw_ips: MapSet.new(),
      ports: MapSet.new()
    }
  end

  defp merge_allow_acc(a, b) do
    %{
      schemes: MapSet.union(a.schemes, b.schemes),
      domains: MapSet.union(a.domains, b.domains),
      networks: MapSet.union(a.networks, b.networks),
      raw_ips: MapSet.union(a.raw_ips, b.raw_ips),
      ports: MapSet.union(a.ports, b.ports)
    }
  end

  defp add_endpoint_to_allow(acc, ep) do
    acc =
      if is_binary(ep.scheme) and ep.scheme != "",
        do: %{acc | schemes: MapSet.put(acc.schemes, ep.scheme)},
        else: acc

    acc =
      case ep.host_kind do
        {:ip, cidr, raw_ip} ->
          %{
            acc
            | networks: MapSet.put(acc.networks, cidr),
              raw_ips: MapSet.put(acc.raw_ips, raw_ip)
          }

        {:domain, domain} ->
          %{acc | domains: MapSet.put(acc.domains, domain)}
      end

    %{acc | ports: MapSet.put(acc.ports, ep.port)}
  end

  defp finalize_allowlist(acc) do
    %{
      schemes: acc.schemes |> MapSet.to_list() |> Enum.sort(),
      domains: acc.domains |> MapSet.to_list() |> Enum.sort(),
      networks: acc.networks |> MapSet.to_list() |> Enum.sort(),
      ports: acc.ports |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp maybe_record_slot_endpoint(slot_acc, nil, _ep), do: slot_acc

  defp maybe_record_slot_endpoint(slot_acc, slot, ep) do
    Map.put_new(slot_acc, slot, ep)
  end

  defp parse_http_endpoint_allowing_step_vars(url) when is_binary(url) do
    sanitized_path_url =
      Regex.replace(~r/(\$\{steps\.[^}]+\}|\{\{steps\.[^}]+\}\})/, url, "stepvar")

    parse_http_endpoint(sanitized_path_url)
  end

  defp parse_http_endpoint_allowing_step_vars(_), do: {:error, :missing_http_url}

  defp parse_http_endpoint(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" or unsafe_text?(trimmed) do
      {:error, :invalid_http_url}
    else
      uri = URI.parse(trimmed)
      scheme = uri.scheme && String.downcase(uri.scheme)

      if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
           is_nil(uri.userinfo) do
        default_port = if scheme == "https", do: 443, else: 80
        validate_host_port(uri.host, uri.port || default_port, scheme, trimmed)
      else
        {:error, :invalid_http_url}
      end
    end
  end

  defp parse_http_endpoint(_), do: {:error, :missing_http_url}

  defp validate_host_port(host, port, scheme, full_url \\ nil) do
    clean_host =
      host
      |> to_string()
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim_trailing(".")

    cond do
      clean_host == "" or unsafe_host?(clean_host) ->
        {:error, :invalid_target_host}

      not (is_integer(port) and port in 1..65_535) ->
        {:error, :invalid_target_port}

      true ->
        host_kind = classify_host(clean_host)
        url = full_url || if(scheme, do: "#{scheme}://#{clean_host}:#{port}")
        {:ok, %{scheme: scheme, host: clean_host, host_kind: host_kind, port: port, url: url}}
    end
  end

  defp classify_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {_, _, _, _} = ipv4} ->
        ip_str = ipv4 |> :inet.ntoa() |> to_string()
        {:ip, "#{ip_str}/32", ip_str}

      {:ok, {_, _, _, _, _, _, _, _} = ipv6} ->
        ip_str = ipv6 |> :inet.ntoa() |> to_string() |> String.downcase()
        {:ip, "#{ip_str}/128", ip_str}

      _ ->
        {:domain, String.downcase(host)}
    end
  end

  defp split_nameserver(nil, default_port), do: {"", default_port}

  defp split_nameserver(ns, default_port) when is_binary(ns) do
    trimmed = String.trim(ns)

    case String.split(trimmed, ":") do
      [h, p_str] ->
        case Integer.parse(p_str) do
          {p, ""} when p in 1..65_535 -> {h, p}
          _ -> {trimmed, default_port}
        end

      _ ->
        {trimmed, default_port}
    end
  end

  defp parse_port(p) when is_integer(p) and p in 1..65_535, do: p

  defp parse_port(p) when is_binary(p) do
    case Integer.parse(String.trim(p)) do
      {num, ""} when num in 1..65_535 -> num
      _ -> nil
    end
  end

  defp parse_port(_), do: nil

  defp unsafe_text?(s), do: String.contains?(s, ["\r", "\n", "\0", " ", "\t"])
  defp unsafe_host?(s), do: unsafe_text?(s) or String.contains?(s, ["/", "\\", "?", "#", "@"])

  defp active_check?(check, opts) do
    if Keyword.get(opts, :include_inactive?, false) do
      true
    else
      fetch_val(check, :state) in [:enabled, "enabled"]
    end
  end

  defp normalize_nodes(nodes) do
    nodes
    |> List.wrap()
    |> Enum.map(fn n ->
      m = stringify_map(n)
      kind = Map.get(m, "kind") || Map.get(m, "type") || ""

      Map.merge(m, %{
        "kind" => to_string(kind),
        "config" => stringify_map(Map.get(m, "config", %{}))
      })
    end)
  end

  defp normalize_edges(edges) do
    edges
    |> List.wrap()
    |> Enum.map(fn e ->
      m = stringify_map(e)
      src = Map.get(m, "source") || Map.get(m, "from")
      dst = Map.get(m, "target") || Map.get(m, "to")
      Map.merge(m, %{"source" => to_string(src || ""), "target" => to_string(dst || "")})
    end)
  end

  defp stringify_map(map) when is_struct(map), do: map |> Map.from_struct() |> stringify_map()

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) ->
        {to_string(k), stringify_map(v)}

      {k, v} when is_list(v) ->
        {to_string(k), Enum.map(v, &if(is_map(&1), do: stringify_map(&1), else: &1))}

      {k, v} ->
        {to_string(k), v}
    end)
  end

  defp stringify_map(_), do: %{}

  defp fetch_val(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end

  defp non_empty_str(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_str(_), do: nil

  defp int_or_default(v, _default) when is_integer(v) and v > 0, do: v
  defp int_or_default(_, default), do: default
end
