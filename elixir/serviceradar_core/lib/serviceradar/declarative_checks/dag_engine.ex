defmodule ServiceRadar.DeclarativeChecks.DAGEngine do
  @moduledoc """
  Shared Directed Acyclic Graph (DAG) execution engine for `DeclarativeChecks`
  (`2.1`-`2.4`, `3.5`).

  Executes nodes in deterministic topological order for a single target context,
  resolving Core signals (`platform_posture`, `srql_query`, `vantage_point`,
  `device_metadata`), reading cached or simulated Edge signal observations,
  evaluating `extract_field`, `threshold_assert`, `decision_table`, and
  `alert_output`, scrubbing secrets (`"[REDACTED]"`), and bounding persisted
  `node_snapshots` to `<= 16_384` bytes.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Resolvers
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.SecretTextScrubber
  alias ServiceRadar.DeclarativeChecks.NodeEvaluators
  alias ServiceRadar.DeclarativeChecks.PostureEvaluators
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.DeclarativeChecks.SRQLQueryNode
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  @max_snapshot_bytes 16_384
  @edge_kinds ~w(http_request http_journey tcp_connect tls_handshake dns_lookup)

  @doc """
  Evaluates a declarative check DAG for a single `target_ctx`, returning the
  unified verdict, status, summary, redacted `node_traces` (for Test Run), and
  bounded `node_snapshots` (for `DeclarativeCheckInstance` persistence).
  """
  @spec evaluate_target(map() | struct(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate_target(check_or_doc, target_ctx \\ %{}, opts \\ [])
      when is_map(check_or_doc) and is_map(target_ctx) and is_list(opts) do
    started_ms = System.monotonic_time(:millisecond)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    raw = if is_struct(check_or_doc), do: Map.from_struct(check_or_doc), else: check_or_doc

    nodes = normalize_nodes(fetch_val(raw, "nodes", []))
    edges = normalize_edges(fetch_val(raw, "edges", []))
    inputs_decl = fetch_val(raw, "inputs", [])

    param_overrides =
      merge_overrides(
        fetch_val(raw, "parameter_overrides", %{}),
        Keyword.get(opts, :parameter_overrides)
      )

    effective_inputs = NodeEvaluators.resolve_effective_inputs(inputs_decl, param_overrides)
    scrub_values = Keyword.get(opts, :secret_values_to_scrub, [])

    with {:ok, order} <- SchemaValidator.topological_order(nodes, edges) do
      nodes_by_id = Map.new(nodes, &{&1["id"], &1})
      incoming_by_target = Enum.group_by(edges, & &1["target"])

      {outputs_by_id, traces_rev} =
        Enum.reduce(order, {%{}, []}, fn node_id, {out_acc, tr_acc} ->
          node = Map.fetch!(nodes_by_id, node_id)
          in_edges = Map.get(incoming_by_target, node_id, [])

          {node_out, trace} =
            execute_single_node(
              node,
              in_edges,
              out_acc,
              effective_inputs,
              target_ctx,
              now,
              scrub_values,
              opts
            )

          {Map.put(out_acc, node_id, node_out), [trace | tr_acc]}
        end)

      traces = Enum.reverse(traces_rev)
      alert_nodes = Enum.filter(nodes, &(&1["kind"] == "alert_output"))
      {status, verdict, summary} = aggregate_terminal_outputs(alert_nodes, outputs_by_id)
      total_ms = max(0, System.monotonic_time(:millisecond) - started_ms)

      target_key =
        to_string(
          Map.get(target_ctx, "target_key") || Map.get(target_ctx, :target_key) || "singleton"
        )

      {:ok,
       %{
         target_key: target_key,
         device_uid: Map.get(target_ctx, "uid") || Map.get(target_ctx, :uid),
         service_target_id:
           Map.get(target_ctx, "service_target_id") || Map.get(target_ctx, :service_target_id),
         status: status,
         verdict: verdict,
         summary: sanitize_text(summary, scrub_values),
         evaluated_at: now,
         duration_ms: total_ms,
         node_traces: traces,
         node_snapshots: build_bounded_snapshots(traces)
       }}
    end
  end

  defp execute_single_node(
         node,
         in_edges,
         outputs_by_id,
         effective_inputs,
         target_ctx,
         now,
         scrub_values,
         opts
       ) do
    t0 = System.monotonic_time(:millisecond)
    node_id = node["id"]
    kind = node["kind"]
    raw_config = node["config"] || %{}

    result =
      with {:ok, resolved_config} <-
             NodeEvaluators.interpolate(raw_config, effective_inputs, target_ctx) do
        kind
        |> dispatch_node(node_id, resolved_config, in_edges, outputs_by_id, target_ctx, now, opts)
        |> attach_resolved_inputs(resolved_config, in_edges, outputs_by_id)
      end

    elapsed_ms = max(0, System.monotonic_time(:millisecond) - t0)

    case result do
      {:ok, out_map, resolved_in} ->
        node_status = Map.get(out_map, :status) || Map.get(out_map, "status") || :healthy

        trace = %{
          "node_id" => node_id,
          "kind" => kind,
          "status" => to_string(node_status),
          "duration_ms" => elapsed_ms,
          "resolved_inputs" => sanitize_term(resolved_in, scrub_values),
          "output" => sanitize_term(stringify_output(out_map), scrub_values),
          "error" => nil
        }

        {out_map, trace}

      {:error, reason} ->
        err_str = sanitize_text(format_error(reason), scrub_values)

        fallback_out = %{
          status: :unknown,
          verdict: "unknown",
          value: nil,
          summary: err_str,
          observed_at: now,
          payload: %{"error" => err_str}
        }

        trace = %{
          "node_id" => node_id,
          "kind" => kind,
          "status" => "unknown",
          "duration_ms" => elapsed_ms,
          "resolved_inputs" => sanitize_term(raw_config, scrub_values),
          "output" => %{"status" => "unknown", "verdict" => "unknown"},
          "error" => err_str
        }

        {fallback_out, trace}
    end
  end

  defp attach_resolved_inputs({:ok, out_map}, resolved_config, in_edges, outputs_by_id) do
    upstream_summary =
      Map.new(in_edges, fn edge ->
        src_id = edge["source"]
        dst_handle = edge["target_handle"] || "in"
        src_out = Map.get(outputs_by_id, src_id, %{})

        val =
          Map.get(src_out, :value, Map.get(src_out, "value")) ||
            Map.get(src_out, :verdict, Map.get(src_out, "verdict")) ||
            Map.get(src_out, :status, Map.get(src_out, "status"))

        {"#{src_id}->#{dst_handle}", val}
      end)

    resolved_in =
      if map_size(upstream_summary) == 0 do
        resolved_config
      else
        Map.put(resolved_config, "_upstream", upstream_summary)
      end

    {:ok, out_map, resolved_in}
  end

  defp attach_resolved_inputs({:error, _} = err, _resolved_config, _in_edges, _outputs_by_id),
    do: err

  defp dispatch_node(
         "platform_posture",
         _node_id,
         config,
         _in_edges,
         _outputs,
         _target,
         now,
         opts
       ) do
    PostureEvaluators.evaluate(config, Keyword.put(opts, :now, now))
  end

  defp dispatch_node("srql_query", _node_id, config, _in_edges, _outputs, _target, now, opts) do
    SRQLQueryNode.evaluate(config, Keyword.put(opts, :now, now))
  end

  defp dispatch_node("vantage_point", node_id, config, _in_edges, _outputs, target_ctx, now, opts) do
    agent_id = Map.get(config, "agent_id")
    max_age = Map.get(config, "max_age_seconds", 900)
    uid = Map.get(target_ctx, "uid") || Map.get(target_ctx, :uid)
    vantage_map = Keyword.get(opts, :vantage_observations, %{})

    raw_row =
      get_in(vantage_map, [uid, agent_id]) ||
        Map.get(vantage_map, agent_id) ||
        Map.get(vantage_map, node_id)

    row =
      case raw_row do
        %DeviceAgentAvailability{} = avail -> avail
        m when is_map(m) -> struct(DeviceAgentAvailability, m)
        _ -> nil
      end

    input_struct = %CompositeCheckInput{
      key: node_id,
      kind: :vantage_point,
      config: %{"agent_id" => agent_id, "max_age_seconds" => max_age}
    }

    res = Resolvers.VantagePoint.resolve(input_struct, row, now)
    val_str = to_string(res.value)

    status =
      case res.value do
        :available -> :healthy
        :blocked -> :down
        _ -> :unknown
      end

    {:ok,
     %{
       status: status,
       value: val_str,
       observed_at: res.observed_at,
       stale: res.stale,
       payload: %{
         "value" => val_str,
         "stale" => res.stale,
         "agent_id" => agent_id,
         "reason" => res.reason && to_string(res.reason)
       }
     }}
  end

  defp dispatch_node(
         "device_metadata",
         node_id,
         config,
         _in_edges,
         _outputs,
         target_ctx,
         now,
         opts
       ) do
    path = Map.get(config, "path")
    max_age = Map.get(config, "max_age_seconds")
    uid = Map.get(target_ctx, "uid") || Map.get(target_ctx, :uid)

    metadata =
      Map.get(target_ctx, "metadata") ||
        Map.get(target_ctx, :metadata) ||
        get_in(Keyword.get(opts, :device_metadata, %{}), [uid]) ||
        %{}

    cfg =
      if is_integer(max_age),
        do: %{"path" => path, "max_age_seconds" => max_age},
        else: %{"path" => path}

    input_struct = %CompositeCheckInput{key: node_id, kind: :device_metadata, config: cfg}
    res = Resolvers.DeviceMetadata.resolve(input_struct, metadata, now)

    {:ok,
     %{
       status: if(res.value == :unknown, do: :unknown, else: :healthy),
       value: res.value,
       observed_at: res.observed_at,
       stale: res.stale,
       payload: %{
         "value" => res.value,
         "path" => path,
         "stale" => res.stale,
         "reason" => res.reason && to_string(res.reason)
       }
     }}
  end

  defp dispatch_node(kind, node_id, config, _in_edges, _outputs, target_ctx, now, opts)
       when kind in @edge_kinds do
    case Keyword.get(opts, :edge_probe_runner) do
      runner when is_function(runner, 4) ->
        runner.(kind, node_id, config, target_ctx)

      _ ->
        resolve_cached_edge_observation(node_id, config, target_ctx, now, opts)
    end
  end

  defp dispatch_node("extract_field", _node_id, config, in_edges, outputs, _target, _now, _opts) do
    upstream = primary_upstream(in_edges, outputs)
    NodeEvaluators.evaluate_extract_field(config, upstream)
  end

  defp dispatch_node(
         "threshold_assert",
         _node_id,
         config,
         in_edges,
         outputs,
         _target,
         _now,
         _opts
       ) do
    upstream = primary_upstream(in_edges, outputs)
    NodeEvaluators.evaluate_threshold_assert(config, upstream)
  end

  defp dispatch_node("decision_table", _node_id, config, in_edges, outputs, _target, now, _opts) do
    inputs_by_handle =
      Enum.reduce(in_edges, %{}, fn edge, acc ->
        src_id = edge["source"]
        dst_handle = edge["target_handle"] || "in"
        stripped = String.replace_prefix(dst_handle, "in:", "")
        src_out = Map.get(outputs, src_id, %{})

        acc
        |> Map.put(dst_handle, src_out)
        |> Map.put(stripped, src_out)
        |> Map.put(src_id, src_out)
      end)

    NodeEvaluators.evaluate_decision_table(config, inputs_by_handle, now)
  end

  defp dispatch_node("alert_output", _node_id, config, in_edges, outputs, _target, _now, _opts) do
    upstream = primary_upstream(in_edges, outputs)
    NodeEvaluators.evaluate_alert_output(config, upstream)
  end

  defp resolve_cached_edge_observation(node_id, config, target_ctx, _now, opts) do
    edge_obs = Keyword.get(opts, :edge_observations, %{})

    target_key =
      to_string(
        Map.get(target_ctx, "target_key") || Map.get(target_ctx, :target_key) || "singleton"
      )

    agent_id = Map.get(config, "agent_id")

    found =
      (agent_id && Map.get(edge_obs, {node_id, target_key, agent_id})) ||
        Map.get(edge_obs, {node_id, target_key}) ||
        Map.get(edge_obs, node_id) ||
        get_in(edge_obs, [target_key, node_id])

    case found do
      %{} = obs ->
        status = normalize_status_atom(Map.get(obs, :status) || Map.get(obs, "status"))
        val = Map.get(obs, :value, Map.get(obs, "value"))
        payload = Map.get(obs, :payload) || Map.get(obs, "payload") || %{}
        observed_at = Map.get(obs, :observed_at) || Map.get(obs, "observed_at")

        {:ok,
         %{
           status: status,
           value: val || Atom.to_string(status),
           observed_at: observed_at,
           from_edge_observation: true,
           payload:
             Map.merge(payload, %{
               "status" => Atom.to_string(status),
               "value" => val || Atom.to_string(status)
             })
         }}

      nil ->
        {:ok,
         %{
           status: :unknown,
           value: nil,
           observed_at: nil,
           from_edge_observation: true,
           payload: %{"status" => "unknown", "reason" => "awaiting_edge_observation"}
         }}
    end
  end

  defp primary_upstream([first_edge | _], outputs) do
    Map.get(outputs, first_edge["source"], %{})
  end

  defp primary_upstream([], _outputs), do: %{}

  defp aggregate_terminal_outputs([], _outputs), do: {:unknown, "unknown", "no alert_output node"}

  defp aggregate_terminal_outputs(alert_nodes, outputs_by_id) do
    results =
      Enum.map(alert_nodes, fn node ->
        out = Map.get(outputs_by_id, node["id"], %{})
        status = normalize_status_atom(Map.get(out, :status) || Map.get(out, "status"))

        verdict =
          to_string(Map.get(out, :verdict) || Map.get(out, "verdict") || Atom.to_string(status))

        summary = to_string(Map.get(out, :summary) || Map.get(out, "summary") || verdict)
        {status, verdict, summary}
      end)

    Enum.max_by(results, fn {status, _v, _s} -> status_severity_rank(status) end)
  end

  defp status_severity_rank(:healthy), do: 0
  defp status_severity_rank(:unknown), do: 1
  defp status_severity_rank(:degraded), do: 2
  defp status_severity_rank(:down), do: 3

  defp build_bounded_snapshots(traces) do
    compact =
      Map.new(traces, fn trace ->
        {trace["node_id"],
         %{
           "kind" => trace["kind"],
           "status" => trace["status"],
           "duration_ms" => trace["duration_ms"],
           "output" => compact_output(trace["output"]),
           "error" => trace["error"]
         }}
      end)

    encoded = Jason.encode!(compact)

    if byte_size(encoded) <= @max_snapshot_bytes do
      compact
    else
      minimal =
        Map.new(traces, fn trace ->
          {trace["node_id"],
           %{
             "kind" => trace["kind"],
             "status" => trace["status"],
             "duration_ms" => trace["duration_ms"]
           }}
        end)

      if byte_size(Jason.encode!(minimal)) <= @max_snapshot_bytes do
        Map.put(minimal, "_truncated", true)
      else
        %{"_truncated" => true, "node_count" => length(traces)}
      end
    end
  end

  defp compact_output(output) when is_map(output) do
    output
    |> Map.delete("rows")
    |> Enum.take(12)
    |> Map.new()
  end

  defp compact_output(other), do: other

  defp stringify_output(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      val =
        case v do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          a when is_atom(a) and not is_boolean(a) and not is_nil(a) -> Atom.to_string(a)
          other -> other
        end

      {to_string(k), val}
    end)
  end

  defp sanitize_term(term, scrub_values) do
    term
    |> CredentialRedactor.redact()
    |> SecretTextScrubber.scrub_value()
    |> scrub_known_secrets(scrub_values)
  end

  defp scrub_known_secrets(term, []), do: term

  defp scrub_known_secrets(str, secrets) when is_binary(str) do
    Enum.reduce(secrets, str, fn secret, acc ->
      if is_binary(secret) and secret != "" do
        String.replace(acc, secret, "[REDACTED]")
      else
        acc
      end
    end)
  end

  defp scrub_known_secrets(map, secrets) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, scrub_known_secrets(v, secrets)} end)
  end

  defp scrub_known_secrets(list, secrets) when is_list(list) do
    Enum.map(list, &scrub_known_secrets(&1, secrets))
  end

  defp scrub_known_secrets(other, _secrets), do: other

  defp sanitize_text(nil, _scrub_values), do: nil

  defp sanitize_text(text, scrub_values) when is_binary(text) do
    text
    |> SecretTextScrubber.scrub_text()
    |> scrub_known_secrets(scrub_values)
    |> String.slice(0, 512)
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    Enum.map(nodes, fn n ->
      Map.new(n, fn {k, v} -> {to_string(k), v} end)
    end)
  end

  defp normalize_edges(edges) when is_list(edges) do
    Enum.map(edges, fn e ->
      Map.new(e, fn {k, v} -> {to_string(k), v} end)
    end)
  end

  defp merge_overrides(base, nil) when is_map(base), do: base

  defp merge_overrides(base, extra) when is_map(base) and is_map(extra),
    do: Map.merge(base, extra)

  defp merge_overrides(_, extra) when is_map(extra), do: extra
  defp merge_overrides(_, _), do: %{}

  defp fetch_val(map, str_key, default) do
    atom_key =
      try do
        String.to_existing_atom(str_key)
      rescue
        ArgumentError -> nil
      end

    cond do
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> default
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp normalize_status_atom(s) when s in [:healthy, :degraded, :down, :unknown], do: s
  defp normalize_status_atom("healthy"), do: :healthy
  defp normalize_status_atom("degraded"), do: :degraded
  defp normalize_status_atom("down"), do: :down
  defp normalize_status_atom(_), do: :unknown
end
