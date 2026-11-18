defmodule ServiceRadar.DeclarativeChecks.SchemaValidator do
  @moduledoc """
  Strict `schema_version: 1` validator, secret-free preflight guard, handle/port
  type checker, and acyclic DAG verifier for `ServiceRadar.DeclarativeChecks` (`1.4`).

  Rejects unknown top-level or node-config fields, embedded secrets or credential
  UUIDs, cyclic graphs, incompatible port handles, unbounded SRQL queries,
  catastrophic-backtracking regexes, recursive/scripted JSONPath selectors, and
  decision tables missing a trailing catch-all row.
  """

  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SRQLTargetQuery

  @max_nodes 64
  @max_edges 128
  @max_regex_pattern_bytes 512
  @max_jsonpath_depth 16
  @max_srql_limit 1_000
  @max_srql_timeout_ms 10_000
  @max_journey_steps 16

  @slug_regex ~r/\A[a-z0-9][a-z0-9._-]{0,126}\z/
  @hex64_regex ~r/\A[0-9a-f]{64}\z/
  @ident_regex ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,126}\z/

  @allowed_top_keys ~w(
    schema_version
    slug
    name
    description
    state
    pack_id
    pack_version
    managed
    template_fingerprint
    parameter_overrides
    schedule
    target_binding
    inputs
    credential_slots
    nodes
    edges
    alert_policy
    ui_layout
  )

  @allowed_states ~w(draft enabled disabled)
  @allowed_schedule_keys ~w(interval_seconds timeout_seconds jitter_seconds)
  @allowed_target_binding_keys ~w(mode scope_query target_ids selector_query url host port metadata)
  @allowed_target_modes ~w(singleton srql_devices service_targets)
  @allowed_input_keys ~w(key type default min max description label)
  @allowed_input_types ~w(number integer string boolean)
  @allowed_slot_keys ~w(slot kind provider role purpose required description label)
  @allowed_node_keys ~w(id kind label config)
  @allowed_edge_keys ~w(id source source_handle target target_handle)
  @allowed_alert_policy_keys ~w(
    emit_ocsf_transition
    open_on_statuses
    priority
    threshold
    window_seconds
    cooldown_seconds
    renotify_seconds
  )
  @allowed_ui_layout_keys ~w(nodes viewport)
  @allowed_statuses ~w(healthy degraded down unknown)
  @allowed_comparators ~w(== != > >= < <= in contains matches)

  @core_signal_kinds ~w(srql_query platform_posture vantage_point device_metadata)
  @edge_signal_kinds ~w(http_request http_journey tcp_connect tls_handshake dns_lookup)
  @transform_and_verdict_kinds ~w(extract_field threshold_assert decision_table alert_output)
  @allowed_node_kinds @core_signal_kinds ++ @edge_signal_kinds ++ @transform_and_verdict_kinds

  @supported_posture_evaluators ~w(
    storage.entitlement_utilization
    storage.hold_pin_pressure
    storage.archive_credential_and_usage_health
    camera.continuous_recording_silence
  )

  @forbidden_secret_keys MapSet.new(~w(
    password
    encrypted_password
    secret
    client_secret
    secret_key
    secret_payload
    encrypted_secret_payload
    token
    api_token
    access_token
    refresh_token
    bearer_token
    auth_token
    api_key
    private_key
    ssh_private_key
    access_key
    access_key_id
    secret_access_key
    session_token
    credential_secret_id
    credential_rule_id
    credentials_encrypted
  ))

  @forbidden_auth_header_names MapSet.new(~w(
    authorization
    proxy-authorization
    x-api-key
    api-key
    x-auth-token
  ))

  @literal_bearer_regex ~r/(?i)\bauthorization\s*:\s*(bearer|basic|token|apikey|digest)\s+\S+/
  @header_auth_scheme_regex ~r/(?i)\A\s*(bearer|basic|token|apikey|digest|aws4-hmac-sha256)\s+\S+/
  @pem_private_key_regex ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/

  @type diagnostic :: %{
          path: String.t(),
          code: String.t(),
          message: String.t()
        }

  @type validation_error :: %{
          kind: :secret_guard | :schema_validation | :invalid_json,
          errors: [diagnostic()]
        }

  @doc "Returns the closed list of supported `platform_posture` evaluator identifiers."
  @spec supported_posture_evaluators() :: [String.t()]
  def supported_posture_evaluators, do: @supported_posture_evaluators

  @doc "Returns the closed list of supported v1 node `kind` strings."
  @spec allowed_node_kinds() :: [String.t()]
  def allowed_node_kinds, do: @allowed_node_kinds

  @doc "Classifies a list of nodes into `:core_only`, `:edge_only`, or `:hybrid`."
  @spec classify_topology([map()]) :: :core_only | :edge_only | :hybrid
  def classify_topology(nodes) when is_list(nodes) do
    kinds =
      Enum.map(nodes, fn node ->
        to_string(Map.get(node, "kind") || Map.get(node, :kind) || "")
      end)

    has_core? = Enum.any?(kinds, &(&1 in @core_signal_kinds))
    has_edge? = Enum.any?(kinds, &(&1 in @edge_signal_kinds))

    cond do
      has_core? and has_edge? -> :hybrid
      has_edge? -> :edge_only
      true -> :core_only
    end
  end

  @doc """
  Runs a deep secret-free preflight check over a raw check document map.

  Rejects embedded secret-shaped keys (`password`, `secret`, `token`,
  `private_key`, `access_key_id`, `secret_access_key`, `credential_secret_id`,
  `credential_rule_id`, etc.) and literal credential header values (`Authorization: Bearer ...`).
  """
  @spec validate_secret_free(term()) :: :ok | {:error, [diagnostic()]}
  def validate_secret_free(document) when is_map(document) do
    case scan_secrets(document, "$", false) do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate_secret_free(_), do: :ok

  @doc """
  Validates and normalizes a `schema_version: 1` declarative check document.

  Returns `{:ok, normalized_map}` with deterministic string keys and computed
  `template_fingerprint`, or `{:error, %{kind: :secret_guard | :schema_validation, errors: [...]}}`.
  """
  @spec validate_document(term(), keyword()) :: {:ok, map()} | {:error, validation_error()}
  def validate_document(raw_doc, opts \\ [])

  def validate_document(raw_doc, opts) when is_map(raw_doc) and is_list(opts) do
    doc = stringify_deep(raw_doc)

    case validate_secret_free(doc) do
      {:error, secret_errors} ->
        {:error, %{kind: :secret_guard, errors: secret_errors}}

      :ok ->
        run_schema_validation(doc, opts)
    end
  end

  def validate_document(_other, _opts) do
    {:error,
     %{
       kind: :schema_validation,
       errors: [diag("$", "invalid_type", "declarative check document must be a JSON object")]
     }}
  end

  @doc """
  Computes a deterministic topological execution order over `nodes` and `edges`,
  returning `{:ok, ordered_node_ids}` or `{:error, [diagnostic()]}` naming any
  cycle nodes and edges.
  """
  @spec topological_order([map()], [map()]) :: {:ok, [String.t()]} | {:error, [diagnostic()]}
  def topological_order(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_ids = Enum.map(nodes, &to_string(Map.get(&1, "id") || Map.get(&1, :id)))
    id_set = MapSet.new(node_ids)

    valid_edges =
      Enum.filter(edges, fn edge ->
        src = to_string(Map.get(edge, "source") || Map.get(edge, :source) || "")
        dst = to_string(Map.get(edge, "target") || Map.get(edge, :target) || "")
        MapSet.member?(id_set, src) and MapSet.member?(id_set, dst)
      end)

    in_degrees =
      Enum.reduce(valid_edges, Map.new(node_ids, &{&1, 0}), fn edge, acc ->
        dst = to_string(Map.get(edge, "target") || Map.get(edge, :target))
        Map.update!(acc, dst, &(&1 + 1))
      end)

    adj =
      valid_edges
      |> Enum.reduce(Map.new(node_ids, &{&1, []}), fn edge, acc ->
        src = to_string(Map.get(edge, "source") || Map.get(edge, :source))
        dst = to_string(Map.get(edge, "target") || Map.get(edge, :target))
        Map.update!(acc, src, &[dst | &1])
      end)
      |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)

    initial_ready = Enum.filter(node_ids, &(Map.fetch!(in_degrees, &1) == 0))
    kahn_walk(initial_ready, in_degrees, adj, node_ids, valid_edges, [])
  end

  defp kahn_walk([], in_degrees, _adj, node_ids, valid_edges, acc) do
    ordered = Enum.reverse(acc)

    if length(ordered) == length(node_ids) do
      {:ok, ordered}
    else
      ordered_set = MapSet.new(ordered)

      cycle_nodes =
        Enum.reject(node_ids, &MapSet.member?(ordered_set, &1))

      cycle_node_set = MapSet.new(cycle_nodes)

      cycle_edges =
        valid_edges
        |> Enum.filter(fn edge ->
          src = to_string(Map.get(edge, "source") || Map.get(edge, :source))
          dst = to_string(Map.get(edge, "target") || Map.get(edge, :target))
          MapSet.member?(cycle_node_set, src) and MapSet.member?(cycle_node_set, dst)
        end)
        |> Enum.map(&to_string(Map.get(&1, "id") || Map.get(&1, :id)))

      _ = in_degrees

      {:error,
       [
         diag(
           "$.edges",
           "cyclic_graph",
           "graph contains a cycle involving nodes [#{Enum.join(cycle_nodes, ", ")}] " <>
             "and edges [#{Enum.join(cycle_edges, ", ")}]"
         )
       ]}
    end
  end

  defp kahn_walk([current | rest_ready], in_degrees, adj, node_ids, valid_edges, acc) do
    neighbors = Map.get(adj, current, [])

    {next_in_degrees, newly_ready} =
      Enum.reduce(neighbors, {in_degrees, []}, fn dst, {deg_acc, ready_acc} ->
        new_deg = Map.fetch!(deg_acc, dst) - 1
        updated_deg = Map.put(deg_acc, dst, new_deg)

        if new_deg == 0 do
          {updated_deg, [dst | ready_acc]}
        else
          {updated_deg, ready_acc}
        end
      end)

    next_ready = rest_ready ++ Enum.reverse(newly_ready)
    kahn_walk(next_ready, next_in_degrees, adj, node_ids, valid_edges, [current | acc])
  end

  ## Secret-free preflight scanning

  defp scan_secrets(map, path, in_headers?) when is_map(map) do
    Enum.reduce(map, [], fn {raw_key, val}, acc ->
      key = to_string(raw_key)
      norm_key = key |> String.trim() |> String.downcase()
      child_path = "#{path}.#{key}"

      acc =
        cond do
          MapSet.member?(@forbidden_secret_keys, norm_key) ->
            [
              diag(
                child_path,
                "secret_forbidden",
                "embedded secret or local credential reference '#{key}' is forbidden in declarative check JSON; use credential_slots instead"
              )
              | acc
            ]

          in_headers? and MapSet.member?(@forbidden_auth_header_names, norm_key) and
            is_binary(val) and String.trim(val) != "" ->
            [
              diag(
                child_path,
                "secret_forbidden",
                "literal authentication header '#{key}' is forbidden in declarative check JSON; bind a credential_slot instead"
              )
              | acc
            ]

          true ->
            acc
        end

      child_in_headers? = norm_key == "headers"
      scan_secrets(val, child_path, child_in_headers?) ++ acc
    end)
  end

  defp scan_secrets(list, path, in_headers?) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, idx}, acc ->
      scan_secrets(item, "#{path}[#{idx}]", in_headers?) ++ acc
    end)
  end

  defp scan_secrets(str, path, in_headers?) when is_binary(str) do
    cond do
      Regex.match?(@pem_private_key_regex, str) ->
        [
          diag(
            path,
            "secret_forbidden",
            "PEM private key material is forbidden in declarative check JSON"
          )
        ]

      Regex.match?(@literal_bearer_regex, str) ->
        [
          diag(
            path,
            "secret_forbidden",
            "literal Authorization credential header is forbidden in declarative check JSON; use credential_slots instead"
          )
        ]

      in_headers? and Regex.match?(@header_auth_scheme_regex, str) ->
        [
          diag(
            path,
            "secret_forbidden",
            "literal authorization token scheme is forbidden in header values; use credential_slots instead"
          )
        ]

      has_url_userinfo?(str) ->
        [
          diag(
            path,
            "secret_forbidden",
            "embedded URL userinfo credentials are forbidden in declarative check JSON; use credential_slots instead"
          )
        ]

      true ->
        []
    end
  end

  defp scan_secrets(_other, _path, _in_headers?), do: []

  defp has_url_userinfo?(str) when is_binary(str) do
    if String.starts_with?(str, ["http://", "https://", "rtsp://", "rtsps://"]) do
      case URI.parse(str) do
        %URI{userinfo: ui} when is_binary(ui) and ui != "" -> true
        _ -> false
      end
    else
      false
    end
  end

  ## Full Schema Validation

  defp run_schema_validation(doc, opts) do
    errors =
      []
      |> check_allowed_keys(doc, @allowed_top_keys, "$")
      |> validate_schema_version(doc)
      |> validate_slug_and_name(doc)
      |> validate_state_and_provenance(doc)
      |> validate_schedule(Map.get(doc, "schedule"))
      |> validate_target_binding(Map.get(doc, "target_binding"), opts)

    {input_defs_by_key, errors} = validate_inputs(Map.get(doc, "inputs", []), errors)

    errors =
      validate_parameter_overrides(
        Map.get(doc, "parameter_overrides", %{}),
        input_defs_by_key,
        errors
      )

    {slot_set, errors} = validate_credential_slots(Map.get(doc, "credential_slots", []), errors)
    {nodes_by_id, errors} = validate_nodes(Map.get(doc, "nodes"), slot_set, opts, errors)
    errors = validate_edges(Map.get(doc, "edges"), nodes_by_id, errors)
    errors = validate_alert_policy(Map.get(doc, "alert_policy"), errors)
    errors = validate_ui_layout(Map.get(doc, "ui_layout"), nodes_by_id, errors)

    case Enum.reverse(errors) do
      [] ->
        {:ok, build_normalized_document(doc)}

      diagnostics ->
        {:error, %{kind: :schema_validation, errors: diagnostics}}
    end
  end

  defp build_normalized_document(doc) do
    nodes = Map.get(doc, "nodes") || []
    nodes_by_id = Map.new(nodes, fn n -> {Map.get(n, "id"), n} end)

    edges =
      doc
      |> Map.get("edges", [])
      |> List.wrap()
      |> Enum.map(fn edge ->
        src_node = Map.get(nodes_by_id, Map.get(edge, "source"))

        edge
        |> Map.put_new("source_handle", default_source_handle(src_node))
        |> Map.put_new("target_handle", "in")
      end)

    normalized = %{
      "schema_version" => 1,
      "slug" => String.trim(doc["slug"]),
      "name" => String.trim(doc["name"]),
      "description" => normalize_optional_string(Map.get(doc, "description")),
      "state" => Map.get(doc, "state") || "draft",
      "pack_id" => normalize_optional_string(Map.get(doc, "pack_id")),
      "pack_version" => normalize_optional_string(Map.get(doc, "pack_version")),
      "managed" => Map.get(doc, "managed", false) == true,
      "parameter_overrides" => Map.get(doc, "parameter_overrides") || %{},
      "schedule" => CanonicalJSON.normalize_schedule(Map.get(doc, "schedule")),
      "target_binding" => CanonicalJSON.normalize_target_binding(Map.get(doc, "target_binding")),
      "inputs" => Map.get(doc, "inputs") || [],
      "credential_slots" => Map.get(doc, "credential_slots") || [],
      "nodes" => nodes,
      "edges" => edges,
      "alert_policy" => CanonicalJSON.normalize_alert_policy(Map.get(doc, "alert_policy")),
      "ui_layout" => Map.get(doc, "ui_layout")
    }

    fingerprint = CanonicalJSON.template_fingerprint(normalized)
    Map.put(normalized, "template_fingerprint", fingerprint)
  end

  defp check_allowed_keys(errors, map, allowed, path) when is_map(map) do
    allowed_set = MapSet.new(allowed)

    Enum.reduce(Map.keys(map), errors, fn key, acc ->
      if MapSet.member?(allowed_set, key) do
        acc
      else
        [diag("#{path}.#{key}", "unknown_field", "unknown field '#{key}' is not permitted") | acc]
      end
    end)
  end

  defp check_allowed_keys(errors, _other, _allowed, _path), do: errors

  defp validate_schema_version(errors, doc) do
    case Map.get(doc, "schema_version", 1) do
      1 ->
        errors

      other ->
        [
          diag(
            "$.schema_version",
            "invalid_schema_version",
            "schema_version must be 1, got #{inspect(other)}"
          )
          | errors
        ]
    end
  end

  defp validate_slug_and_name(errors, doc) do
    errors =
      case Map.get(doc, "slug") do
        slug when is_binary(slug) ->
          trimmed = String.trim(slug)

          if Regex.match?(@slug_regex, trimmed) do
            errors
          else
            [
              diag(
                "$.slug",
                "invalid_slug",
                "slug must match [a-z0-9][a-z0-9._-]{0,126}"
              )
              | errors
            ]
          end

        _ ->
          [diag("$.slug", "required", "slug is required and must be a non-empty string") | errors]
      end

    case Map.get(doc, "name") do
      name when is_binary(name) ->
        trimmed = String.trim(name)

        if byte_size(trimmed) in 1..255 do
          errors
        else
          [diag("$.name", "invalid_name", "name must be between 1 and 255 characters") | errors]
        end

      _ ->
        [diag("$.name", "required", "name is required and must be a non-empty string") | errors]
    end
  end

  defp validate_state_and_provenance(errors, doc) do
    errors =
      case Map.get(doc, "state", "draft") do
        s when s in @allowed_states ->
          errors

        other ->
          [
            diag(
              "$.state",
              "invalid_state",
              "state must be one of #{Enum.join(@allowed_states, ", ")}, got #{inspect(other)}"
            )
            | errors
          ]
      end

    errors =
      case Map.get(doc, "managed", false) do
        b when is_boolean(b) -> errors
        _ -> [diag("$.managed", "invalid_type", "managed must be a boolean") | errors]
      end

    errors =
      case Map.get(doc, "description") do
        nil ->
          errors

        s when is_binary(s) and byte_size(s) <= 4_096 ->
          errors

        _ ->
          [
            diag("$.description", "invalid_type", "description must be a string <= 4096 bytes")
            | errors
          ]
      end

    errors =
      case Map.get(doc, "pack_id") do
        nil ->
          errors

        s when is_binary(s) and byte_size(s) in 1..255 ->
          errors

        _ ->
          [
            diag(
              "$.pack_id",
              "invalid_pack_id",
              "pack_id must be a string between 1 and 255 bytes"
            )
            | errors
          ]
      end

    errors =
      case Map.get(doc, "pack_version") do
        nil ->
          errors

        s when is_binary(s) and byte_size(s) in 1..64 ->
          errors

        _ ->
          [
            diag(
              "$.pack_version",
              "invalid_pack_version",
              "pack_version must be a string between 1 and 64 bytes"
            )
            | errors
          ]
      end

    case Map.get(doc, "template_fingerprint") do
      nil ->
        errors

      fp when is_binary(fp) ->
        if Regex.match?(@hex64_regex, fp) do
          errors
        else
          [
            diag(
              "$.template_fingerprint",
              "invalid_fingerprint",
              "template_fingerprint must be a 64-character lowercase SHA-256 hex digest"
            )
            | errors
          ]
        end

      _ ->
        [
          diag("$.template_fingerprint", "invalid_type", "template_fingerprint must be a string")
          | errors
        ]
    end
  end

  defp validate_schedule(errors, nil), do: errors

  defp validate_schedule(errors, schedule) when is_map(schedule) do
    errors = check_allowed_keys(errors, schedule, @allowed_schedule_keys, "$.schedule")

    errors =
      case Map.get(schedule, "interval_seconds", 300) do
        n when is_integer(n) and n in 30..86_400 ->
          errors

        _ ->
          [
            diag(
              "$.schedule.interval_seconds",
              "out_of_range",
              "interval_seconds must be an integer between 30 and 86400"
            )
            | errors
          ]
      end

    errors =
      case Map.get(schedule, "timeout_seconds", 30) do
        n when is_integer(n) and n in 1..300 ->
          errors

        _ ->
          [
            diag(
              "$.schedule.timeout_seconds",
              "out_of_range",
              "timeout_seconds must be an integer between 1 and 300"
            )
            | errors
          ]
      end

    case Map.get(schedule, "jitter_seconds", 15) do
      n when is_integer(n) and n in 0..300 ->
        errors

      _ ->
        [
          diag(
            "$.schedule.jitter_seconds",
            "out_of_range",
            "jitter_seconds must be an integer between 0 and 300"
          )
          | errors
        ]
    end
  end

  defp validate_schedule(errors, _other) do
    [diag("$.schedule", "invalid_type", "schedule must be an object") | errors]
  end

  defp validate_target_binding(errors, nil, _opts), do: errors
  defp validate_target_binding(errors, binding, _opts) when binding == %{}, do: errors

  defp validate_target_binding(errors, binding, opts) when is_map(binding) do
    errors = check_allowed_keys(errors, binding, @allowed_target_binding_keys, "$.target_binding")

    case Map.get(binding, "mode") do
      "singleton" ->
        errors

      "srql_devices" ->
        validate_srql_devices_binding(errors, Map.get(binding, "scope_query"), opts)

      "service_targets" ->
        validate_service_targets_binding(errors, binding)

      other ->
        [
          diag(
            "$.target_binding.mode",
            "invalid_mode",
            "target_binding.mode must be one of #{Enum.join(@allowed_target_modes, ", ")}, got #{inspect(other)}"
          )
          | errors
        ]
    end
  end

  defp validate_target_binding(errors, _other, _opts) do
    [diag("$.target_binding", "invalid_type", "target_binding must be an object") | errors]
  end

  defp validate_srql_devices_binding(errors, scope_query, opts) when is_binary(scope_query) do
    trimmed = String.trim(scope_query)

    if trimmed == "" do
      [
        diag(
          "$.target_binding.scope_query",
          "required",
          "scope_query is required when mode is srql_devices"
        )
        | errors
      ]
    else
      validate_devices_scope_query(errors, trimmed, opts)
    end
  end

  defp validate_srql_devices_binding(errors, _other, _opts) do
    [
      diag(
        "$.target_binding.scope_query",
        "required",
        "scope_query is required when mode is srql_devices"
      )
      | errors
    ]
  end

  defp validate_devices_scope_query(errors, query, opts) do
    normalized = SRQLQuery.ensure_target(query, :devices)

    cond do
      SRQLAst.entity(normalized) != "devices" ->
        [
          diag(
            "$.target_binding.scope_query",
            "invalid_srql_entity",
            "scope_query must target in:devices"
          )
          | errors
        ]

      Keyword.get(opts, :skip_srql_nif?, false) ->
        errors

      true ->
        case safe_validate_target_query(normalized) do
          :ok ->
            errors

          {:error, message} ->
            [diag("$.target_binding.scope_query", "invalid_srql_query", message) | errors]
        end
    end
  end

  defp safe_validate_target_query(query) do
    case SRQLTargetQuery.validate(query, entity: :devices) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  rescue
    UndefinedFunctionError -> :ok
    ErlangError -> :ok
  end

  defp validate_service_targets_binding(errors, binding) do
    target_ids = Map.get(binding, "target_ids")
    selector_query = Map.get(binding, "selector_query")

    cond do
      is_list(target_ids) and target_ids != [] and
          Enum.all?(target_ids, &(is_binary(&1) and &1 != "")) ->
        errors

      is_binary(selector_query) and String.trim(selector_query) != "" ->
        errors

      true ->
        [
          diag(
            "$.target_binding",
            "missing_service_targets",
            "service_targets mode requires a non-empty target_ids list or selector_query"
          )
          | errors
        ]
    end
  end

  defp validate_inputs(inputs, errors) when is_list(inputs) do
    {map, _seen, next_errors} =
      inputs
      |> Enum.with_index()
      |> Enum.reduce({%{}, MapSet.new(), errors}, fn {item, idx}, {by_key, seen, acc} ->
        path = "$.inputs[#{idx}]"

        if is_map(item) do
          acc = check_allowed_keys(acc, item, @allowed_input_keys, path)
          key = Map.get(item, "key")
          type = Map.get(item, "type")

          {seen, acc} =
            cond do
              not (is_binary(key) and Regex.match?(@ident_regex, key)) ->
                {seen,
                 [
                   diag("#{path}.key", "invalid_key", "input key must be a valid identifier")
                   | acc
                 ]}

              MapSet.member?(seen, key) ->
                {seen,
                 [diag("#{path}.key", "duplicate_key", "duplicate input key '#{key}'") | acc]}

              true ->
                {MapSet.put(seen, key), acc}
            end

          acc =
            if type in @allowed_input_types do
              validate_input_bounds_and_default(acc, item, type, path)
            else
              [
                diag(
                  "#{path}.type",
                  "invalid_input_type",
                  "input type must be one of #{Enum.join(@allowed_input_types, ", ")}"
                )
                | acc
              ]
            end

          next_by_key = if is_binary(key), do: Map.put(by_key, key, item), else: by_key
          {next_by_key, seen, acc}
        else
          {by_key, seen, [diag(path, "invalid_type", "input entry must be an object") | acc]}
        end
      end)

    {map, next_errors}
  end

  defp validate_inputs(_other, errors) do
    {%{}, [diag("$.inputs", "invalid_type", "inputs must be an array") | errors]}
  end

  defp validate_input_bounds_and_default(errors, item, type, path) do
    min_val = Map.get(item, "min")
    max_val = Map.get(item, "max")

    errors =
      if not is_nil(min_val) and not is_number(min_val) do
        [diag("#{path}.min", "invalid_type", "min must be numeric") | errors]
      else
        errors
      end

    errors =
      if not is_nil(max_val) and not is_number(max_val) do
        [diag("#{path}.max", "invalid_type", "max must be numeric") | errors]
      else
        errors
      end

    errors =
      if is_number(min_val) and is_number(max_val) and min_val > max_val do
        [diag("#{path}.max", "invalid_bounds", "max must be >= min") | errors]
      else
        errors
      end

    case Map.fetch(item, "default") do
      :error ->
        errors

      {:ok, nil} ->
        errors

      {:ok, default} ->
        validate_typed_value(errors, default, type, min_val, max_val, "#{path}.default")
    end
  end

  defp validate_parameter_overrides(nil, _inputs_by_key, errors), do: errors

  defp validate_parameter_overrides(overrides, inputs_by_key, errors) when is_map(overrides) do
    Enum.reduce(overrides, errors, fn {key, val}, acc ->
      path = "$.parameter_overrides.#{key}"

      case Map.fetch(inputs_by_key, key) do
        :error ->
          [
            diag(
              path,
              "unknown_parameter",
              "parameter_override '#{key}' does not match any declared input"
            )
            | acc
          ]

        {:ok, input_def} ->
          validate_typed_value(
            acc,
            val,
            Map.get(input_def, "type"),
            Map.get(input_def, "min"),
            Map.get(input_def, "max"),
            path
          )
      end
    end)
  end

  defp validate_parameter_overrides(_other, _inputs_by_key, errors) do
    [
      diag("$.parameter_overrides", "invalid_type", "parameter_overrides must be an object")
      | errors
    ]
  end

  defp validate_typed_value(errors, val, "number", min_val, max_val, path) do
    if is_number(val) do
      check_numeric_bounds(errors, val, min_val, max_val, path)
    else
      [diag(path, "invalid_type", "expected number") | errors]
    end
  end

  defp validate_typed_value(errors, val, "integer", min_val, max_val, path) do
    if is_integer(val) do
      check_numeric_bounds(errors, val, min_val, max_val, path)
    else
      [diag(path, "invalid_type", "expected integer") | errors]
    end
  end

  defp validate_typed_value(errors, val, "string", _min, _max, path) do
    if is_binary(val), do: errors, else: [diag(path, "invalid_type", "expected string") | errors]
  end

  defp validate_typed_value(errors, val, "boolean", _min, _max, path) do
    if is_boolean(val),
      do: errors,
      else: [diag(path, "invalid_type", "expected boolean") | errors]
  end

  defp validate_typed_value(errors, _val, _type, _min, _max, _path), do: errors

  defp check_numeric_bounds(errors, val, min_val, max_val, path) do
    errors =
      if is_number(min_val) and val < min_val do
        [diag(path, "out_of_range", "value #{val} is below minimum #{min_val}") | errors]
      else
        errors
      end

    if is_number(max_val) and val > max_val do
      [diag(path, "out_of_range", "value #{val} exceeds maximum #{max_val}") | errors]
    else
      errors
    end
  end

  defp validate_credential_slots(slots, errors) when is_list(slots) do
    {seen, next_errors} =
      slots
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), errors}, fn {item, idx}, {seen, acc} ->
        path = "$.credential_slots[#{idx}]"

        if is_map(item) do
          acc = check_allowed_keys(acc, item, @allowed_slot_keys, path)
          slot = Map.get(item, "slot")
          provider = Map.get(item, "provider")
          role = Map.get(item, "role")
          purpose = Map.get(item, "purpose")
          required = Map.get(item, "required", true)

          {seen, acc} =
            cond do
              not (is_binary(slot) and Regex.match?(@ident_regex, slot)) ->
                {seen,
                 [diag("#{path}.slot", "invalid_slot", "slot must be a valid identifier") | acc]}

              MapSet.member?(seen, slot) ->
                {seen,
                 [
                   diag("#{path}.slot", "duplicate_slot", "duplicate credential slot '#{slot}'")
                   | acc
                 ]}

              true ->
                {MapSet.put(seen, slot), acc}
            end

          acc =
            acc
            |> validate_optional_nonblank_str(provider, "#{path}.provider")
            |> validate_optional_nonblank_str(role, "#{path}.role")
            |> validate_optional_nonblank_str(purpose, "#{path}.purpose")
            |> validate_optional_nonblank_str(Map.get(item, "kind"), "#{path}.kind")

          acc =
            if is_boolean(required),
              do: acc,
              else: [diag("#{path}.required", "invalid_type", "required must be a boolean") | acc]

          {seen, acc}
        else
          {seen, [diag(path, "invalid_type", "credential_slot entry must be an object") | acc]}
        end
      end)

    {seen, next_errors}
  end

  defp validate_credential_slots(_other, errors) do
    {MapSet.new(),
     [diag("$.credential_slots", "invalid_type", "credential_slots must be an array") | errors]}
  end

  ## Nodes Validation

  defp validate_nodes(nodes, slot_set, opts, errors) when is_list(nodes) do
    errors =
      cond do
        nodes == [] ->
          [diag("$.nodes", "empty_nodes", "nodes must contain at least one node") | errors]

        length(nodes) > @max_nodes ->
          [
            diag(
              "$.nodes",
              "too_many_nodes",
              "nodes count #{length(nodes)} exceeds maximum of #{@max_nodes}"
            )
            | errors
          ]

        true ->
          errors
      end

    {by_id, has_alert_output?, next_errors} =
      nodes
      |> Enum.with_index()
      |> Enum.reduce({%{}, false, errors}, fn {node, idx}, {by_id, has_out?, acc} ->
        path = "$.nodes[#{idx}]"

        if is_map(node) do
          acc = check_allowed_keys(acc, node, @allowed_node_keys, path)
          id = Map.get(node, "id")
          kind = Map.get(node, "kind")
          config = Map.get(node, "config", %{})

          acc =
            cond do
              not (is_binary(id) and Regex.match?(@ident_regex, id)) ->
                [
                  diag("#{path}.id", "invalid_node_id", "node id must be a valid identifier")
                  | acc
                ]

              Map.has_key?(by_id, id) ->
                [diag("#{path}.id", "duplicate_node_id", "duplicate node id '#{id}'") | acc]

              true ->
                acc
            end

          acc =
            if kind in @allowed_node_kinds do
              validate_node_config(acc, kind, config, slot_set, opts, "#{path}.config")
            else
              [
                diag(
                  "#{path}.kind",
                  "invalid_node_kind",
                  "node kind #{inspect(kind)} is not permitted; allowed kinds: #{Enum.join(@allowed_node_kinds, ", ")}"
                )
                | acc
              ]
            end

          next_by_id = if is_binary(id), do: Map.put(by_id, id, node), else: by_id
          {next_by_id, has_out? or kind == "alert_output", acc}
        else
          {by_id, has_out?, [diag(path, "invalid_type", "node must be an object") | acc]}
        end
      end)

    final_errors =
      if nodes != [] and not has_alert_output? do
        [
          diag(
            "$.nodes",
            "missing_alert_output",
            "graph must terminate in at least one alert_output node"
          )
          | next_errors
        ]
      else
        next_errors
      end

    {by_id, final_errors}
  end

  defp validate_nodes(_other, _slot_set, _opts, errors) do
    {%{}, [diag("$.nodes", "required", "nodes is required and must be an array") | errors]}
  end

  defp validate_node_config(errors, _kind, config, _slot_set, _opts, path)
       when not is_map(config) do
    [diag(path, "invalid_type", "node config must be an object") | errors]
  end

  defp validate_node_config(errors, "platform_posture", config, _slot_set, _opts, path) do
    allowed = ~w(evaluator consumer silence_window_minutes max_report_age_hours params)
    errors = check_allowed_keys(errors, config, allowed, path)

    case Map.get(config, "evaluator") do
      ev when ev in @supported_posture_evaluators ->
        errors

      other ->
        [
          diag(
            "#{path}.evaluator",
            "invalid_posture_evaluator",
            "unsupported platform_posture evaluator #{inspect(other)}; supported: #{Enum.join(@supported_posture_evaluators, ", ")}"
          )
          | errors
        ]
    end
  end

  defp validate_node_config(errors, "srql_query", config, _slot_set, opts, path) do
    allowed = ~w(query limit timeout_ms result_mode)
    errors = check_allowed_keys(errors, config, allowed, path)
    query = Map.get(config, "query")
    limit = Map.get(config, "limit", 100)
    timeout_ms = Map.get(config, "timeout_ms", 5_000)
    result_mode = Map.get(config, "result_mode", "rows")

    errors =
      cond do
        not (is_binary(query) and String.trim(query) != "") ->
          [
            diag("#{path}.query", "required", "srql_query requires a non-empty query string")
            | errors
          ]

        raw_sql_or_mutation?(query) ->
          [
            diag(
              "#{path}.query",
              "forbidden_query",
              "srql_query must be a read-only SRQL query; raw SQL and mutations are forbidden"
            )
            | errors
          ]

        not Keyword.get(opts, :skip_srql_nif?, false) and not String.contains?(query, "{{") ->
          validate_srql_syntax(errors, query, "#{path}.query")

        true ->
          errors
      end

    errors =
      if is_integer(limit) and limit in 1..@max_srql_limit do
        errors
      else
        [
          diag(
            "#{path}.limit",
            "out_of_range",
            "srql_query limit must be an integer between 1 and #{@max_srql_limit}"
          )
          | errors
        ]
      end

    errors =
      if is_integer(timeout_ms) and timeout_ms in 100..@max_srql_timeout_ms do
        errors
      else
        [
          diag(
            "#{path}.timeout_ms",
            "out_of_range",
            "srql_query timeout_ms must be an integer between 100 and #{@max_srql_timeout_ms}"
          )
          | errors
        ]
      end

    if result_mode in ~w(rows count first_row) do
      errors
    else
      [
        diag(
          "#{path}.result_mode",
          "invalid_result_mode",
          "result_mode must be rows, count, or first_row"
        )
        | errors
      ]
    end
  end

  defp validate_node_config(errors, "vantage_point", config, _slot_set, _opts, path) do
    allowed = ~w(agent_id max_age_seconds expected)
    errors = check_allowed_keys(errors, config, allowed, path)

    case Map.get(config, "agent_id") do
      s when is_binary(s) and s != "" -> errors
      _ -> [diag("#{path}.agent_id", "required", "vantage_point requires agent_id") | errors]
    end
  end

  defp validate_node_config(errors, "device_metadata", config, _slot_set, _opts, path) do
    allowed = ~w(path max_age_seconds)
    errors = check_allowed_keys(errors, config, allowed, path)

    case Map.get(config, "path") do
      s when is_binary(s) and s != "" -> errors
      _ -> [diag("#{path}.path", "required", "device_metadata requires path") | errors]
    end
  end

  defp validate_node_config(errors, "http_request", config, slot_set, _opts, path) do
    allowed =
      ~w(url method headers body timeout_ms expected_statuses credential_slot agent_id follow_redirects)

    errors = check_allowed_keys(errors, config, allowed, path)

    errors =
      case Map.get(config, "url") do
        url when is_binary(url) and url != "" ->
          validate_safe_url_template(errors, url, "#{path}.url")

        _ ->
          [diag("#{path}.url", "required", "http_request requires url") | errors]
      end

    validate_optional_slot_ref(
      errors,
      Map.get(config, "credential_slot"),
      slot_set,
      "#{path}.credential_slot"
    )
  end

  defp validate_node_config(errors, "http_journey", config, slot_set, _opts, path) do
    allowed = ~w(steps timeout_ms agent_id credential_slot)
    errors = check_allowed_keys(errors, config, allowed, path)

    errors =
      validate_optional_slot_ref(
        errors,
        Map.get(config, "credential_slot"),
        slot_set,
        "#{path}.credential_slot"
      )

    case Map.get(config, "steps") do
      steps when is_list(steps) and steps != [] and length(steps) <= @max_journey_steps ->
        steps
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {step, idx}, acc ->
          step_path = "#{path}.steps[#{idx}]"

          if is_map(step) do
            step_allowed =
              ~w(id name url method headers body expected_statuses extract assertions credential_slot)

            acc = check_allowed_keys(acc, step, step_allowed, step_path)

            acc =
              case Map.get(step, "url") do
                u when is_binary(u) and u != "" ->
                  validate_safe_url_template(acc, u, "#{step_path}.url")

                _ ->
                  [diag("#{step_path}.url", "required", "journey step requires url") | acc]
              end

            validate_optional_slot_ref(
              acc,
              Map.get(step, "credential_slot"),
              slot_set,
              "#{step_path}.credential_slot"
            )
          else
            [diag(step_path, "invalid_type", "journey step must be an object") | acc]
          end
        end)

      _ ->
        [
          diag(
            "#{path}.steps",
            "invalid_steps",
            "http_journey requires between 1 and #{@max_journey_steps} steps"
          )
          | errors
        ]
    end
  end

  defp validate_node_config(errors, "tcp_connect", config, _slot_set, _opts, path) do
    allowed = ~w(host port timeout_ms agent_id)
    errors = check_allowed_keys(errors, config, allowed, path)

    errors =
      case Map.get(config, "host") do
        h when is_binary(h) and h != "" -> errors
        _ -> [diag("#{path}.host", "required", "tcp_connect requires host") | errors]
      end

    case Map.get(config, "port") do
      p when is_integer(p) and p in 1..65_535 ->
        errors

      s when is_binary(s) and s != "" ->
        errors

      _ ->
        [
          diag("#{path}.port", "required", "tcp_connect requires port (1..65535 or template)")
          | errors
        ]
    end
  end

  defp validate_node_config(errors, "tls_handshake", config, _slot_set, _opts, path) do
    allowed = ~w(host port sni timeout_ms agent_id min_days_remaining)
    errors = check_allowed_keys(errors, config, allowed, path)

    case Map.get(config, "host") do
      h when is_binary(h) and h != "" -> errors
      _ -> [diag("#{path}.host", "required", "tls_handshake requires host") | errors]
    end
  end

  defp validate_node_config(errors, "dns_lookup", config, _slot_set, _opts, path) do
    allowed = ~w(hostname host record_type nameserver timeout_ms agent_id)
    errors = check_allowed_keys(errors, config, allowed, path)
    host = Map.get(config, "hostname") || Map.get(config, "host")

    if is_binary(host) and host != "" do
      errors
    else
      [diag("#{path}.hostname", "required", "dns_lookup requires hostname") | errors]
    end
  end

  defp validate_node_config(errors, "extract_field", config, _slot_set, _opts, path) do
    allowed = ~w(source_type expression path header pattern field output_key default cast group)
    errors = check_allowed_keys(errors, config, allowed, path)
    source_type = Map.get(config, "source_type", "field")

    expr =
      Map.get(config, "expression") ||
        Map.get(config, "path") ||
        Map.get(config, "header") ||
        Map.get(config, "pattern") ||
        Map.get(config, "field")

    case source_type do
      "jsonpath" ->
        validate_jsonpath_expression(errors, expr, "#{path}.expression")

      "regex" ->
        validate_linear_regex(errors, expr, "#{path}.expression")

      t when t in ~w(header srql_field field) ->
        if is_binary(expr) and String.trim(expr) != "" do
          errors
        else
          [
            diag("#{path}.expression", "required", "extract_field requires a non-empty selector")
            | errors
          ]
        end

      other ->
        [
          diag(
            "#{path}.source_type",
            "invalid_source_type",
            "extract_field source_type must be jsonpath, header, regex, srql_field, or field, got #{inspect(other)}"
          )
          | errors
        ]
    end
  end

  defp validate_node_config(errors, "threshold_assert", config, _slot_set, _opts, path) do
    allowed =
      ~w(field warn crit fail_closed_field pass_verdict warn_verdict crit_verdict unknown_verdict)

    errors = check_allowed_keys(errors, config, allowed, path)
    warn_spec = Map.get(config, "warn")
    crit_spec = Map.get(config, "crit")
    fail_closed = Map.get(config, "fail_closed_field")

    errors =
      if is_nil(warn_spec) and is_nil(crit_spec) and is_nil(fail_closed) do
        [
          diag(
            path,
            "missing_threshold",
            "threshold_assert requires at least one of warn, crit, or fail_closed_field"
          )
          | errors
        ]
      else
        errors
      end

    errors =
      if is_nil(warn_spec),
        do: errors,
        else: validate_comparator_spec(errors, warn_spec, "#{path}.warn")

    if is_nil(crit_spec),
      do: errors,
      else: validate_comparator_spec(errors, crit_spec, "#{path}.crit")
  end

  defp validate_node_config(errors, "decision_table", config, _slot_set, _opts, path) do
    allowed = ~w(inputs rules)
    errors = check_allowed_keys(errors, config, allowed, path)
    dt_inputs = Map.get(config, "inputs", [])
    rules = Map.get(config, "rules")

    {input_keys, errors} = validate_decision_table_inputs(dt_inputs, "#{path}.inputs", errors)
    validate_decision_table_rules(rules, input_keys, "#{path}.rules", errors)
  end

  defp validate_node_config(errors, "alert_output", config, _slot_set, _opts, path) do
    allowed = ~w(verdict_map summary_template)
    errors = check_allowed_keys(errors, config, allowed, path)

    case Map.get(config, "verdict_map") do
      nil ->
        errors

      vmap when is_map(vmap) ->
        check_allowed_keys(errors, vmap, @allowed_statuses, "#{path}.verdict_map")

      _ ->
        [diag("#{path}.verdict_map", "invalid_type", "verdict_map must be an object") | errors]
    end
  end

  defp validate_optional_slot_ref(errors, nil, _slot_set, _path), do: errors

  defp validate_optional_slot_ref(errors, slot_name, slot_set, path) when is_binary(slot_name) do
    if MapSet.member?(slot_set, slot_name) do
      errors
    else
      [
        diag(
          path,
          "undeclared_credential_slot",
          "credential_slot '#{slot_name}' is not declared in credential_slots"
        )
        | errors
      ]
    end
  end

  defp validate_optional_slot_ref(errors, _other, _slot_set, path) do
    [diag(path, "invalid_type", "credential_slot must be a string") | errors]
  end

  defp validate_safe_url_template(errors, url, path) do
    trimmed = String.trim(url)

    cond do
      trimmed == "{{target.url}}" ->
        errors

      String.starts_with?(trimmed, "https://") or String.starts_with?(trimmed, "http://") ->
        errors

      true ->
        [
          diag(
            path,
            "invalid_url",
            "url must start with http://, https://, or equal {{target.url}}"
          )
          | errors
        ]
    end
  end

  defp validate_jsonpath_expression(errors, expr, path) when is_binary(expr) do
    trimmed = String.trim(expr)

    cond do
      trimmed == "" or not String.starts_with?(trimmed, "$") ->
        [diag(path, "invalid_jsonpath", "JSONPath expression must start with '$'") | errors]

      String.contains?(trimmed, "..") ->
        [
          diag(
            path,
            "recursive_jsonpath_forbidden",
            "recursive descent ('..') is forbidden in JSONPath selectors"
          )
          | errors
        ]

      String.contains?(trimmed, "?(") or String.contains?(trimmed, "(") ->
        [
          diag(
            path,
            "script_jsonpath_forbidden",
            "filter/script expressions are forbidden in JSONPath selectors"
          )
          | errors
        ]

      jsonpath_depth(trimmed) > @max_jsonpath_depth ->
        [
          diag(
            path,
            "jsonpath_depth_exceeded",
            "JSONPath depth exceeds maximum of #{@max_jsonpath_depth}"
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_jsonpath_expression(errors, _other, path) do
    [diag(path, "required", "JSONPath expression is required") | errors]
  end

  defp jsonpath_depth("$"), do: 0

  defp jsonpath_depth("$" <> rest) do
    rest
    |> String.split([".", "["], trim: true)
    |> length()
  end

  defp validate_linear_regex(errors, pattern, path) when is_binary(pattern) do
    cond do
      pattern == "" ->
        [diag(path, "required", "regex pattern must not be empty") | errors]

      byte_size(pattern) > @max_regex_pattern_bytes ->
        [
          diag(
            path,
            "regex_too_long",
            "regex pattern exceeds maximum length of #{@max_regex_pattern_bytes} bytes"
          )
          | errors
        ]

      Regex.match?(~r/\\[1-9]/, pattern) ->
        [
          diag(
            path,
            "unsafe_regex",
            "regex backreferences are forbidden to guarantee linear-time evaluation"
          )
          | errors
        ]

      String.contains?(pattern, ["(?=", "(?!", "(?<=", "(?<!"]) ->
        [
          diag(
            path,
            "unsafe_regex",
            "regex lookaround assertions are forbidden to guarantee linear-time evaluation"
          )
          | errors
        ]

      true ->
        case Regex.compile(pattern) do
          {:ok, _} ->
            errors

          {:error, {reason, pos}} ->
            [
              diag(
                path,
                "invalid_regex",
                "invalid regex at position #{pos}: #{reason}"
              )
              | errors
            ]
        end
    end
  end

  defp validate_linear_regex(errors, _other, path) do
    [diag(path, "required", "regex pattern must be a string") | errors]
  end

  defp validate_comparator_spec(errors, spec, path) when is_map(spec) do
    errors = check_allowed_keys(errors, spec, ~w(op value), path)
    op = Map.get(spec, "op")

    errors =
      if op in @allowed_comparators do
        errors
      else
        [
          diag(
            "#{path}.op",
            "invalid_comparator",
            "comparator op must be one of #{Enum.join(@allowed_comparators, ", ")}"
          )
          | errors
        ]
      end

    if Map.has_key?(spec, "value") and not is_nil(Map.get(spec, "value")) do
      errors
    else
      [diag("#{path}.value", "required", "comparator value is required") | errors]
    end
  end

  defp validate_comparator_spec(errors, _other, path) do
    [diag(path, "invalid_type", "comparator specification must be an object") | errors]
  end

  defp validate_decision_table_inputs(inputs, path, errors) when is_list(inputs) do
    {keys, next_errors} =
      inputs
      |> Enum.with_index()
      |> Enum.reduce({[], errors}, fn {item, idx}, {keys_acc, acc} ->
        item_path = "#{path}[#{idx}]"

        if is_map(item) do
          allowed = ~w(key source_node_id field max_age_seconds label)
          acc = check_allowed_keys(acc, item, allowed, item_path)
          key = Map.get(item, "key")
          max_age = Map.get(item, "max_age_seconds")

          acc =
            if is_binary(key) and Regex.match?(@ident_regex, key),
              do: acc,
              else: [
                diag("#{item_path}.key", "invalid_key", "decision_table input key is required")
                | acc
              ]

          acc =
            if is_nil(max_age) or (is_integer(max_age) and max_age in 1..604_800) do
              acc
            else
              [
                diag(
                  "#{item_path}.max_age_seconds",
                  "out_of_range",
                  "max_age_seconds must be a positive integer <= 604800"
                )
                | acc
              ]
            end

          next_keys = if is_binary(key), do: [key | keys_acc], else: keys_acc
          {next_keys, acc}
        else
          {keys_acc,
           [diag(item_path, "invalid_type", "decision_table input must be an object") | acc]}
        end
      end)

    {Enum.reverse(keys), next_errors}
  end

  defp validate_decision_table_inputs(_other, path, errors) do
    {[], [diag(path, "invalid_type", "decision_table inputs must be an array") | errors]}
  end

  defp validate_decision_table_rules(rules, input_keys, path, errors)
       when is_list(rules) and rules != [] do
    errors =
      rules
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {rule, idx}, acc ->
        rule_path = "#{path}[#{idx}]"

        if is_map(rule) do
          allowed = ~w(id match verdict status label summary description)
          acc = check_allowed_keys(acc, rule, allowed, rule_path)
          match = Map.get(rule, "match")
          verdict = Map.get(rule, "verdict")
          status = Map.get(rule, "status")

          acc =
            if is_map(match),
              do: acc,
              else: [
                diag("#{rule_path}.match", "invalid_type", "rule match must be an object") | acc
              ]

          acc =
            if is_binary(verdict) and String.trim(verdict) != "",
              do: acc,
              else: [diag("#{rule_path}.verdict", "required", "rule verdict is required") | acc]

          if status in @allowed_statuses do
            acc
          else
            [
              diag(
                "#{rule_path}.status",
                "invalid_status",
                "rule status must be one of #{Enum.join(@allowed_statuses, ", ")}"
              )
              | acc
            ]
          end
        else
          [diag(rule_path, "invalid_type", "decision_table rule must be an object") | acc]
        end
      end)

    last_rule = List.last(rules)

    if catch_all_rule?(last_rule, input_keys) do
      errors
    else
      [
        diag(
          path,
          "missing_catch_all",
          "decision_table must end with a mandatory catch-all row mapping every input to '*' (or empty match)"
        )
        | errors
      ]
    end
  end

  defp validate_decision_table_rules(_other, _input_keys, path, errors) do
    [diag(path, "required", "decision_table rules must be a non-empty array") | errors]
  end

  defp catch_all_rule?(%{"match" => match}, input_keys) when is_map(match) do
    cond do
      map_size(match) == 0 ->
        true

      input_keys == [] ->
        Enum.all?(Map.values(match), &(&1 == "*"))

      true ->
        Enum.all?(Map.values(match), &(&1 == "*")) and
          Enum.all?(Map.keys(match), &(&1 in input_keys))
    end
  end

  defp catch_all_rule?(_other, _input_keys), do: false

  defp raw_sql_or_mutation?(query) do
    String.contains?(query, ";") or
      Regex.match?(
        ~r/(?i)\A\s*(select|insert|update|delete|drop|alter|create|truncate|grant|revoke|copy|with)\b/,
        query
      )
  end

  defp validate_srql_syntax(errors, query, path) do
    case SRQLAst.validate(query) do
      :ok ->
        errors

      {:error, reason} ->
        [diag(path, "invalid_srql_query", "invalid SRQL query: #{inspect(reason)}") | errors]
    end
  rescue
    UndefinedFunctionError -> errors
    ErlangError -> errors
  end

  ## Edges, Port Types, and Acyclic DAG Verification

  defp validate_edges(nil, _nodes_by_id, errors), do: errors

  defp validate_edges(edges, nodes_by_id, errors) when is_list(edges) do
    errors =
      if length(edges) > @max_edges do
        [
          diag(
            "$.edges",
            "too_many_edges",
            "edges count #{length(edges)} exceeds maximum of #{@max_edges}"
          )
          | errors
        ]
      else
        errors
      end

    {_seen_ids, errors} =
      edges
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), errors}, fn {edge, idx}, {seen, acc} ->
        path = "$.edges[#{idx}]"

        if is_map(edge) do
          acc = check_allowed_keys(acc, edge, @allowed_edge_keys, path)
          id = Map.get(edge, "id")
          src_id = Map.get(edge, "source")
          dst_id = Map.get(edge, "target")
          src_node = is_binary(src_id) && Map.get(nodes_by_id, src_id)
          dst_node = is_binary(dst_id) && Map.get(nodes_by_id, dst_id)
          src_handle = Map.get(edge, "source_handle") || default_source_handle(src_node)
          dst_handle = Map.get(edge, "target_handle") || "in"

          {seen, acc} =
            cond do
              not (is_binary(id) and Regex.match?(@ident_regex, id)) ->
                {seen,
                 [
                   diag("#{path}.id", "invalid_edge_id", "edge id must be a valid identifier")
                   | acc
                 ]}

              MapSet.member?(seen, id) ->
                {seen,
                 [diag("#{path}.id", "duplicate_edge_id", "duplicate edge id '#{id}'") | acc]}

              true ->
                {MapSet.put(seen, id), acc}
            end

          acc =
            cond do
              is_nil(src_node) ->
                [
                  diag(
                    "#{path}.source",
                    "unknown_node",
                    "edge '#{id}' references unknown source node #{inspect(src_id)}"
                  )
                  | acc
                ]

              is_nil(dst_node) ->
                [
                  diag(
                    "#{path}.target",
                    "unknown_node",
                    "edge '#{id}' references unknown target node #{inspect(dst_id)}"
                  )
                  | acc
                ]

              src_id == dst_id ->
                [
                  diag(
                    path,
                    "cyclic_graph",
                    "edge '#{id}' forms a self-loop on node '#{src_id}'"
                  )
                  | acc
                ]

              true ->
                validate_port_compatibility(
                  acc,
                  id,
                  src_node,
                  src_handle,
                  dst_node,
                  dst_handle,
                  path
                )
            end

          {seen, acc}
        else
          {seen, [diag(path, "invalid_type", "edge must be an object") | acc]}
        end
      end)

    case topological_order(Map.values(nodes_by_id), edges) do
      {:ok, _order} -> errors
      {:error, cycle_diags} -> Enum.reverse(cycle_diags, errors)
    end
  end

  defp validate_edges(_other, _nodes_by_id, errors) do
    [diag("$.edges", "invalid_type", "edges must be an array") | errors]
  end

  defp validate_port_compatibility(
         errors,
         edge_id,
         src_node,
         src_handle,
         dst_node,
         dst_handle,
         path
       ) do
    src_kind = Map.get(src_node, "kind")
    dst_kind = Map.get(dst_node, "kind")
    src_id = Map.get(src_node, "id")
    dst_id = Map.get(dst_node, "id")

    src_port_type = source_port_type(src_kind, src_handle)
    dst_accepts = target_accepted_port_types(dst_node, dst_kind, dst_handle)

    cond do
      src_port_type == :invalid ->
        [
          diag(
            "#{path}.source_handle",
            "incompatible_handle",
            "edge '#{edge_id}' cannot read handle #{inspect(src_handle)} on #{src_kind} node '#{src_id}'"
          )
          | errors
        ]

      dst_accepts == :invalid ->
        [
          diag(
            "#{path}.target_handle",
            "incompatible_handle",
            "edge '#{edge_id}' cannot connect to handle #{inspect(dst_handle)} on #{dst_kind} node '#{dst_id}'"
          )
          | errors
        ]

      src_port_type not in dst_accepts ->
        [
          diag(
            path,
            "incompatible_handle_types",
            "edge '#{edge_id}' connects #{src_kind} ('#{src_id}:#{src_handle}', type #{src_port_type}) " <>
              "to incompatible #{dst_kind} ('#{dst_id}:#{dst_handle}', accepts #{Enum.join(dst_accepts, "|")})"
          )
          | errors
        ]

      true ->
        errors
    end
  end

  defp source_port_type(kind, "signal")
       when kind in @core_signal_kinds or kind in @edge_signal_kinds, do: :signal

  defp source_port_type("extract_field", handle) when handle in ["value", "signal", "out"],
    do: :value

  defp source_port_type("threshold_assert", "verdict"), do: :verdict
  defp source_port_type("decision_table", "verdict"), do: :verdict
  defp source_port_type(_kind, _handle), do: :invalid

  defp default_source_handle(%{"kind" => kind})
       when kind in ["threshold_assert", "decision_table"], do: "verdict"

  defp default_source_handle(%{"kind" => "extract_field"}), do: "value"
  defp default_source_handle(_), do: "signal"

  defp validate_optional_nonblank_str(errors, nil, _path), do: errors

  defp validate_optional_nonblank_str(errors, val, path) when is_binary(val) do
    if String.trim(val) == "",
      do: [diag(path, "invalid_string", "must be a non-empty string when provided") | errors],
      else: errors
  end

  defp validate_optional_nonblank_str(errors, _other, path) do
    [diag(path, "invalid_type", "must be a string") | errors]
  end

  defp target_accepted_port_types(_node, kind, _handle)
       when kind in @core_signal_kinds or kind in @edge_signal_kinds,
       do: :invalid

  defp target_accepted_port_types(_node, "extract_field", "in"), do: [:signal, :value]
  defp target_accepted_port_types(_node, "threshold_assert", "in"), do: [:signal, :value]
  defp target_accepted_port_types(_node, "alert_output", "in"), do: [:verdict]

  defp target_accepted_port_types(node, "decision_table", handle) when is_binary(handle) do
    declared_keys =
      node
      |> get_in(["config", "inputs"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "key"))
      |> Enum.filter(&is_binary/1)

    normalized = String.replace_prefix(handle, "in:", "")

    if handle == "in" or normalized in declared_keys do
      [:signal, :value, :verdict]
    else
      :invalid
    end
  end

  defp target_accepted_port_types(_node, _kind, _handle), do: :invalid

  ## Alert Policy & UI Layout

  defp validate_alert_policy(nil, errors), do: errors

  defp validate_alert_policy(policy, errors) when is_map(policy) do
    errors = check_allowed_keys(errors, policy, @allowed_alert_policy_keys, "$.alert_policy")

    errors =
      case Map.get(policy, "emit_ocsf_transition", true) do
        b when is_boolean(b) ->
          errors

        _ ->
          [
            diag("$.alert_policy.emit_ocsf_transition", "invalid_type", "must be boolean")
            | errors
          ]
      end

    case Map.get(policy, "open_on_statuses", ["down"]) do
      list when is_list(list) ->
        if Enum.all?(list, &(&1 in @allowed_statuses)) do
          errors
        else
          [
            diag(
              "$.alert_policy.open_on_statuses",
              "invalid_status",
              "open_on_statuses entries must be in #{Enum.join(@allowed_statuses, ", ")}"
            )
            | errors
          ]
        end

      _ ->
        [diag("$.alert_policy.open_on_statuses", "invalid_type", "must be an array") | errors]
    end
  end

  defp validate_alert_policy(_other, errors) do
    [diag("$.alert_policy", "invalid_type", "alert_policy must be an object") | errors]
  end

  defp validate_ui_layout(nil, _nodes_by_id, errors), do: errors

  defp validate_ui_layout(layout, _nodes_by_id, errors) when is_map(layout) do
    errors = check_allowed_keys(errors, layout, @allowed_ui_layout_keys, "$.ui_layout")

    case Map.get(layout, "nodes") do
      nil ->
        errors

      nodes_map when is_map(nodes_map) ->
        Enum.reduce(nodes_map, errors, fn {node_id, coords}, acc ->
          pos_path = "$.ui_layout.nodes.#{node_id}"

          if is_map(coords) and is_number(Map.get(coords, "x")) and
               is_number(Map.get(coords, "y")) do
            check_allowed_keys(acc, coords, ~w(x y width height), pos_path)
          else
            [
              diag(
                pos_path,
                "invalid_coordinates",
                "ui_layout node entry must have numeric x and y"
              )
              | acc
            ]
          end
        end)

      _ ->
        [diag("$.ui_layout.nodes", "invalid_type", "ui_layout.nodes must be an object") | errors]
    end
  end

  defp validate_ui_layout(_other, _nodes_by_id, errors) do
    [diag("$.ui_layout", "invalid_type", "ui_layout must be an object") | errors]
  end

  ## Helpers

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(str) when is_binary(str) do
    trimmed = String.trim(str)
    if trimmed == "", do: nil, else: trimmed
  end

  defp stringify_deep(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_deep(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      key_str = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key_str, stringify_deep(v)}
    end)
  end

  defp stringify_deep(list) when is_list(list), do: Enum.map(list, &stringify_deep/1)
  defp stringify_deep(val) when is_boolean(val) or is_nil(val), do: val
  defp stringify_deep(val) when is_atom(val), do: Atom.to_string(val)
  defp stringify_deep(val), do: val

  defp diag(path, code, message), do: %{path: path, code: code, message: message}
end
