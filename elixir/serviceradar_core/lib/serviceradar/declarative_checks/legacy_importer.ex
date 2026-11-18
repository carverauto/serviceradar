defmodule ServiceRadar.DeclarativeChecks.LegacyImporter do
  @moduledoc """
  Pure 1-click legacy conversion adapters (`from_service_check/2` and
  `from_composite_check/2`, `2.5`) producing validated `schema_version: 1`
  `DeclarativeCheck` documents in `state: "draft"`.

  Leaves the source `ServiceCheck` and `CompositeCheck` records completely
  untouched so operators can preview via Test Run and cut over without
  duplicate alerts.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Monitoring.ServiceCheck

  @doc """
  Converts a `ServiceRadar.Monitoring.ServiceCheck` struct, map, or UUID into a
  validated `schema_version: 1` `state: "draft"` declarative check document map.
  """
  @spec from_service_check(ServiceCheck.t() | map() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def from_service_check(service_check_or_id, opts \\ [])

  def from_service_check(id, opts) when is_binary(id) and is_list(opts) do
    actor = extract_actor(opts)

    with {:ok, %ServiceCheck{} = sc} <- ServiceCheck.get_by_id(id, actor: actor) do
      from_service_check(sc, opts)
    end
  end

  def from_service_check(sc, opts) when is_map(sc) and is_list(opts) do
    name = to_string(field_val(sc, :name) || "Imported Service Check")
    slug = derive_slug(Keyword.get(opts, :slug) || name, "service-check")
    description = field_val(sc, :description)
    check_type = normalize_atom(field_val(sc, :check_type) || :http)
    target = to_string(field_val(sc, :target) || "example.com")
    port = field_val(sc, :port)
    interval = clamp_int(field_val(sc, :interval_seconds), 30, 86_400, 60)
    timeout = clamp_int(field_val(sc, :timeout_seconds), 1, 300, 10)
    warn_ms = field_val(sc, :warning_threshold_ms) || 500
    crit_ms = field_val(sc, :critical_threshold_ms) || 2_000
    agent_uid = field_val(sc, :agent_uid)
    device_uid = field_val(sc, :device_uid)

    target_binding =
      if is_binary(device_uid) and device_uid != "" do
        %{
          "mode" => "srql_devices",
          "scope_query" => "in:devices uid:\"#{escape_srql(device_uid)}\""
        }
      else
        %{"mode" => "singleton"}
      end

    signal_node = build_service_signal_node(check_type, target, port, timeout * 1_000, agent_uid)

    doc = %{
      "schema_version" => 1,
      "slug" => slug,
      "name" => name,
      "description" => description,
      "state" => "draft",
      "managed" => false,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => interval,
        "timeout_seconds" => timeout,
        "jitter_seconds" => min(15, div(interval, 4))
      },
      "target_binding" => target_binding,
      "inputs" => [
        %{
          "key" => "warn_latency_ms",
          "type" => "integer",
          "default" => warn_ms,
          "min" => 1,
          "max" => 300_000,
          "description" => "Warning response time threshold in milliseconds"
        },
        %{
          "key" => "crit_latency_ms",
          "type" => "integer",
          "default" => crit_ms,
          "min" => 1,
          "max" => 300_000,
          "description" => "Critical response time threshold in milliseconds"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        signal_node,
        %{
          "id" => "assert_1",
          "kind" => "threshold_assert",
          "label" => "Latency & Availability Assert",
          "config" => %{
            "field" => "latency_ms",
            "warn" => %{"op" => ">=", "value" => "{{inputs.warn_latency_ms}}"},
            "crit" => %{"op" => ">=", "value" => "{{inputs.crit_latency_ms}}"},
            "fail_closed_field" => "probe_failed"
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Service Check Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "service_healthy",
              "degraded" => "service_degraded",
              "down" => "service_unreachable",
              "unknown" => "service_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "probe_1",
          "source_handle" => "signal",
          "target" => "assert_1",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "assert_1",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 3,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "probe_1" => %{"x" => 80, "y" => 120},
          "assert_1" => %{"x" => 380, "y" => 120},
          "out_1" => %{"x" => 680, "y" => 120}
        }
      }
    }

    SchemaValidator.validate_document(doc, Keyword.put_new(opts, :skip_srql_nif?, true))
  end

  @doc """
  Converts a `ServiceRadar.CompositeChecks.CompositeCheck` (plus its inputs and
  rules) into a validated `schema_version: 1` `state: "draft"` declarative check
  document map.
  """
  @spec from_composite_check(CompositeCheck.t() | map() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def from_composite_check(composite_or_id, opts \\ [])

  def from_composite_check(id, opts) when is_binary(id) and is_list(opts) do
    actor = extract_actor(opts)

    with {:ok, %CompositeCheck{} = cc} <- CompositeCheck.get_by_id(id, actor: actor),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(cc.id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(cc.id, actor: actor) do
      from_composite_check(cc, Keyword.merge(opts, inputs: inputs, rules: rules))
    end
  end

  def from_composite_check(cc, opts) when is_map(cc) and is_list(opts) do
    inputs = Keyword.get(opts, :inputs) || field_val(cc, :inputs) || []
    rules = Keyword.get(opts, :rules) || field_val(cc, :rules) || []

    name = to_string(field_val(cc, :name) || "Imported Composite Check")
    base_slug = Keyword.get(opts, :slug) || field_val(cc, :slug) || name
    slug = derive_slug(base_slug, "composite-check")
    description = field_val(cc, :description)
    scope_query = to_string(field_val(cc, :scope_query) || "in:devices")
    interval = clamp_int(field_val(cc, :evaluation_interval_seconds), 30, 86_400, 300)

    sorted_inputs = Enum.sort_by(inputs, &(field_val(&1, :position) || 0))

    {signal_nodes, signal_edges, dt_inputs, layout_nodes} =
      build_composite_signal_graph(sorted_inputs)

    input_keys = Enum.map(dt_inputs, & &1["key"])
    dt_rules = convert_composite_rules(rules, input_keys)

    decision_node = %{
      "id" => "decision_1",
      "kind" => "decision_table",
      "label" => "Composite Decision Table",
      "config" => %{
        "inputs" => dt_inputs,
        "rules" => dt_rules
      }
    }

    output_node = %{
      "id" => "out_1",
      "kind" => "alert_output",
      "label" => "Composite Verdict Output",
      "config" => %{}
    }

    out_edge = %{
      "id" => "e_decision_out",
      "source" => "decision_1",
      "source_handle" => "verdict",
      "target" => "out_1",
      "target_handle" => "in"
    }

    full_layout =
      layout_nodes
      |> Map.put("decision_1", %{"x" => 420, "y" => 160})
      |> Map.put("out_1", %{"x" => 740, "y" => 160})

    doc = %{
      "schema_version" => 1,
      "slug" => slug,
      "name" => name,
      "description" => description,
      "state" => "draft",
      "managed" => false,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => interval,
        "timeout_seconds" => 30,
        "jitter_seconds" => 15
      },
      "target_binding" => %{
        "mode" => "srql_devices",
        "scope_query" => scope_query
      },
      "inputs" => [],
      "credential_slots" => [],
      "nodes" => signal_nodes ++ [decision_node, output_node],
      "edges" => signal_edges ++ [out_edge],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 3,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{"nodes" => full_layout}
    }

    SchemaValidator.validate_document(doc, Keyword.put_new(opts, :skip_srql_nif?, true))
  end

  defp build_service_signal_node(:dns, target, _port, timeout_ms, agent_uid) do
    cfg =
      maybe_put(
        %{"hostname" => extract_host(target), "record_type" => "A", "timeout_ms" => timeout_ms},
        "agent_id",
        agent_uid
      )

    %{"id" => "probe_1", "kind" => "dns_lookup", "label" => "DNS Lookup", "config" => cfg}
  end

  defp build_service_signal_node(kind, target, port, timeout_ms, agent_uid)
       when kind in [:tcp, :ping, :grpc] do
    resolved_port =
      cond do
        is_integer(port) and port in 1..65_535 -> port
        kind == :grpc -> 443
        true -> 80
      end

    cfg =
      maybe_put(
        %{"host" => extract_host(target), "port" => resolved_port, "timeout_ms" => timeout_ms},
        "agent_id",
        agent_uid
      )

    %{"id" => "probe_1", "kind" => "tcp_connect", "label" => "TCP Connect", "config" => cfg}
  end

  defp build_service_signal_node(_http, target, port, timeout_ms, agent_uid) do
    url = ensure_http_url(target, port)

    cfg =
      maybe_put(
        %{
          "url" => url,
          "method" => "GET",
          "expected_statuses" => [200, 201, 204],
          "timeout_ms" => timeout_ms
        },
        "agent_id",
        agent_uid
      )

    %{"id" => "probe_1", "kind" => "http_request", "label" => "HTTP Request", "config" => cfg}
  end

  defp build_composite_signal_graph(inputs) do
    inputs
    |> Enum.with_index()
    |> Enum.reduce({[], [], [], %{}}, fn {inp, idx}, {nodes_acc, edges_acc, dt_acc, lay_acc} ->
      key = to_string(field_val(inp, :key) || "in_#{idx}")
      label = to_string(field_val(inp, :label) || key)
      kind = normalize_atom(field_val(inp, :kind) || :vantage_point)
      raw_cfg = field_val(inp, :config) || %{}
      node_id = "sig_#{key}"
      max_age = raw_cfg["max_age_seconds"] || raw_cfg[:max_age_seconds]

      node =
        case kind do
          :device_metadata ->
            path = to_string(raw_cfg["path"] || raw_cfg[:path] || "fact")

            cfg =
              if is_integer(max_age),
                do: %{"path" => path, "max_age_seconds" => max_age},
                else: %{"path" => path}

            %{"id" => node_id, "kind" => "device_metadata", "label" => label, "config" => cfg}

          _vantage_point ->
            agent_id = to_string(raw_cfg["agent_id"] || raw_cfg[:agent_id] || "default-agent")

            cfg =
              %{"agent_id" => agent_id}
              |> maybe_put("max_age_seconds", if(is_integer(max_age), do: max_age))
              |> maybe_put("expected", field_val(inp, :expected))

            %{"id" => node_id, "kind" => "vantage_point", "label" => label, "config" => cfg}
        end

      edge = %{
        "id" => "e_#{key}",
        "source" => node_id,
        "source_handle" => "signal",
        "target" => "decision_1",
        "target_handle" => key
      }

      dt_input =
        maybe_put(
          %{"key" => key, "source_node_id" => node_id, "label" => label},
          "max_age_seconds",
          if(is_integer(max_age), do: max_age)
        )

      next_lay = Map.put(lay_acc, node_id, %{"x" => 80, "y" => 80 + idx * 120})
      {[node | nodes_acc], [edge | edges_acc], [dt_input | dt_acc], next_lay}
    end)
    |> then(fn {n, e, d, l} -> {Enum.reverse(n), Enum.reverse(e), Enum.reverse(d), l} end)
  end

  defp convert_composite_rules(rules, input_keys) do
    sorted = Enum.sort_by(rules, &(field_val(&1, :position) || 0))

    converted =
      Enum.map(sorted, fn r ->
        raw_match = field_val(r, :match) || %{}
        catch_all? = field_val(r, :catch_all) == true or map_size(raw_match) == 0

        match_map =
          if catch_all? do
            Map.new(input_keys, &{&1, "*"})
          else
            Map.new(raw_match, fn {k, v} -> {to_string(k), stringify_matcher(v)} end)
          end

        status = field_val(r, :status) || :unknown

        %{
          "match" => match_map,
          "verdict" => to_string(field_val(r, :verdict) || "inconclusive"),
          "status" => to_string(status)
        }
        |> maybe_put("label", field_val(r, :verdict_label))
        |> maybe_put("description", field_val(r, :verdict_description))
      end)

    has_catch_all? =
      case List.last(converted) do
        %{"match" => m} when is_map(m) ->
          map_size(m) == 0 or Enum.all?(Map.values(m), &(&1 == "*"))

        _ ->
          false
      end

    if has_catch_all? do
      converted
    else
      converted ++
        [
          %{
            "match" => Map.new(input_keys, &{&1, "*"}),
            "verdict" => "inconclusive",
            "status" => "unknown",
            "label" => "Inconclusive"
          }
        ]
    end
  end

  defp stringify_matcher(list) when is_list(list), do: Enum.map(list, &stringify_matcher/1)
  defp stringify_matcher(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_matcher(v), do: to_string(v)

  defp ensure_http_url(target, port) do
    cond do
      String.starts_with?(target, "http://") or String.starts_with?(target, "https://") ->
        target

      is_integer(port) and port == 80 ->
        "http://#{target}"

      is_integer(port) and port not in [80, 443] ->
        "https://#{target}:#{port}"

      true ->
        "https://#{target}"
    end
  end

  defp extract_host(target) do
    if String.contains?(target, "://") do
      URI.parse(target).host || target
    else
      target |> String.split(":") |> hd()
    end
  end

  defp derive_slug(raw, fallback) do
    sanitized =
      raw
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 120)

    if sanitized == "" or not Regex.match?(~r/\A[a-z0-9]/, sanitized),
      do: fallback,
      else: sanitized
  end

  defp escape_srql(val), do: val |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp clamp_int(v, min_v, max_v, _def) when is_integer(v), do: v |> max(min_v) |> min(max_v)
  defp clamp_int(_, _min_v, _max_v, default), do: default

  defp field_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp normalize_atom(a) when is_atom(a), do: a

  defp normalize_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :http
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp extract_actor(opts) do
    ServiceRadar.DeclarativeChecks.extract_actor(opts)
  end
end
