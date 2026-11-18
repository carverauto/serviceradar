defmodule ServiceRadarWebNG.TestSupport.DeclarativeChecksStub do
  @moduledoc false

  @store_key {__MODULE__, :checks}

  @secret_keys MapSet.new([
                 "password",
                 "secret",
                 "token",
                 "private_key",
                 "access_key_id",
                 "secret_access_key",
                 "session_token",
                 "credential_secret_id",
                 "credential_rule_id",
                 "client_secret",
                 "api_key"
               ])

  @allowed_top_keys MapSet.new([
                      "schema_version",
                      "slug",
                      "name",
                      "description",
                      "state",
                      "pack_id",
                      "pack_version",
                      "managed",
                      "template_fingerprint",
                      "parameter_overrides",
                      "schedule",
                      "target_binding",
                      "inputs",
                      "credential_slots",
                      "nodes",
                      "edges",
                      "alert_policy",
                      "ui_layout"
                    ])

  @semantic_keys [
    "schema_version",
    "slug",
    "schedule",
    "target_binding",
    "inputs",
    "credential_slots",
    "nodes",
    "edges",
    "alert_policy"
  ]

  @structural_keys [
    "schedule",
    "target_binding",
    "inputs",
    "credential_slots",
    "nodes",
    "edges",
    "alert_policy"
  ]

  def reset! do
    Process.put(@store_key, %{})
    :ok
  end

  def list_checks(opts \\ []) do
    state_filter = opts[:state] && to_string(opts[:state])
    pack_filter = opts[:pack_id]

    checks =
      store()
      |> Map.values()
      |> Enum.filter(fn entry ->
        state_ok? = is_nil(state_filter) or entry.check["state"] == state_filter
        pack_ok? = is_nil(pack_filter) or entry.check["pack_id"] == pack_filter
        state_ok? and pack_ok?
      end)
      |> Enum.sort_by(& &1.check["slug"])
      |> Enum.map(&serialize_entry/1)

    {:ok, checks}
  end

  def get_check(slug, _opts \\ []) do
    case Map.fetch(store(), slug) do
      {:ok, entry} -> {:ok, serialize_entry(entry)}
      :error -> {:error, :not_found}
    end
  end

  def create_check(attrs, _opts \\ []) when is_map(attrs) do
    normalized = stringify_map(attrs)
    bindings_input = Map.get(normalized, "credential_bindings", [])
    doc_candidate = Map.drop(normalized, ["credential_bindings", "confirm_detach", "allow_detach"])

    with :ok <- validate_document(doc_candidate),
         :ok <- ensure_slug_available(doc_candidate["slug"]) do
      entry = build_entry(doc_candidate, bindings_input)
      put_entry(entry)
      {:ok, serialize_entry(entry)}
    end
  end

  def update_check(slug, attrs, opts \\ []) when is_binary(slug) and is_map(attrs) do
    case Map.fetch(store(), slug) do
      :error ->
        {:error, :not_found}

      {:ok, existing} ->
        apply_update(existing, stringify_map(attrs), opts)
    end
  end

  def delete_check(slug, _opts \\ []) when is_binary(slug) do
    case Map.fetch(store(), slug) do
      :error ->
        {:error, :not_found}

      {:ok, _entry} ->
        Process.put(@store_key, Map.delete(store(), slug))
        :ok
    end
  end

  def export_check_json(slug, _opts \\ []) when is_binary(slug) do
    case Map.fetch(store(), slug) do
      :error ->
        {:error, :not_found}

      {:ok, entry} ->
        doc = canonical_export_map(entry.check)
        {:ok, encode_sorted_json(doc, 0) <> "\n"}
    end
  end

  def import_check(raw_doc, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    force_overwrite = Keyword.get(opts, :force_overwrite, false)

    with {:ok, parsed} <- parse_doc(raw_doc),
         :ok <- validate_document(parsed) do
      reconcile_import(parsed, dry_run, force_overwrite)
    end
  end

  def test_run(slug, params, _opts) when is_binary(slug) and is_map(params) do
    case Map.fetch(store(), slug) do
      :error -> {:error, :not_found}
      {:ok, entry} -> execute_ephemeral(entry.check, stringify_map(params))
    end
  end

  def test_run(doc, params, _opts) when is_map(doc) and is_map(params) do
    normalized = stringify_map(doc)

    with :ok <- validate_document(normalized) do
      execute_ephemeral(normalized, stringify_map(params))
    end
  end

  defp apply_update(existing, patch, opts) do
    confirm_detach =
      Keyword.get(opts, :confirm_detach, false) ||
        Keyword.get(opts, :allow_detach, false) ||
        patch["confirm_detach"] == true ||
        patch["allow_detach"] == true

    bindings_patch = Map.get(patch, "credential_bindings")

    clean_patch =
      Map.drop(patch, ["credential_bindings", "confirm_detach", "allow_detach", "id"])

    structural_change? =
      Enum.any?(@structural_keys, fn key ->
        Map.has_key?(clean_patch, key) and clean_patch[key] != existing.check[key]
      end)

    if existing.check["managed"] == true and structural_change? and not confirm_detach do
      {:error, :managed_detach_confirmation_required}
    else
      merged =
        existing.check
        |> Map.merge(clean_patch)
        |> then(fn updated ->
          if existing.check["managed"] == true and structural_change? and confirm_detach do
            updated
            |> Map.put("managed", false)
            |> Map.put("template_fingerprint", compute_fingerprint(updated))
          else
            updated
          end
        end)
        |> Map.put("updated_at", "2026-11-18T05:00:00Z")

      doc_to_validate = canonical_export_map(merged)

      with :ok <- validate_document(doc_to_validate) do
        bindings =
          if is_list(bindings_patch),
            do: normalize_bindings(bindings_patch),
            else: existing.bindings

        updated_entry = %{existing | check: merged, bindings: bindings}
        put_entry(updated_entry)
        {:ok, serialize_entry(updated_entry)}
      end
    end
  end

  defp reconcile_import(doc, true, _force_overwrite) do
    canonical = with_defaults_and_fingerprint(doc)

    {:ok,
     %{
       "action" => "dry_run",
       "dry_run" => true,
       "template_fingerprint" => canonical["template_fingerprint"],
       "preserved_parameter_overrides" => canonical["parameter_overrides"],
       "warnings" => [],
       "document" => canonical_export_map(canonical),
       "check" => nil
     }}
  end

  defp reconcile_import(doc, false, force_overwrite) do
    canonical = with_defaults_and_fingerprint(doc)
    slug = canonical["slug"]

    case Map.fetch(store(), slug) do
      :error ->
        entry = build_entry(canonical, [])
        put_entry(entry)

        {:ok,
         %{
           "action" => "created",
           "dry_run" => false,
           "template_fingerprint" => entry.check["template_fingerprint"],
           "preserved_parameter_overrides" => entry.check["parameter_overrides"],
           "warnings" => [],
           "document" => canonical_export_map(entry.check),
           "check" => serialize_entry(entry)
         }}

      {:ok, existing} ->
        reconcile_existing(existing, canonical, force_overwrite)
    end
  end

  defp reconcile_existing(existing, incoming, force_overwrite) do
    stored_semantic_fp = compute_fingerprint(existing.check)
    unmodified_template? = stored_semantic_fp == existing.check["template_fingerprint"]

    cond do
      existing.check["managed"] == true and incoming["managed"] == true and unmodified_template? ->
        preserved_overrides = existing.check["parameter_overrides"] || %{}
        preserved_layout = existing.check["ui_layout"] || incoming["ui_layout"] || %{"nodes" => %{}}
        preserved_state = existing.check["state"] || incoming["state"]

        action =
          if existing.check["template_fingerprint"] == incoming["template_fingerprint"] and
               existing.check["pack_version"] == incoming["pack_version"] do
            "unchanged"
          else
            "updated"
          end

        merged =
          existing.check
          |> Map.merge(incoming)
          |> Map.put("parameter_overrides", preserved_overrides)
          |> Map.put("ui_layout", preserved_layout)
          |> Map.put("state", preserved_state)
          |> Map.put("template_fingerprint", compute_fingerprint(incoming))
          |> Map.put("updated_at", "2026-11-18T05:05:00Z")

        updated_entry = %{existing | check: merged}
        put_entry(updated_entry)

        {:ok,
         %{
           "action" => action,
           "dry_run" => false,
           "template_fingerprint" => merged["template_fingerprint"],
           "preserved_parameter_overrides" => preserved_overrides,
           "warnings" => [],
           "document" => canonical_export_map(merged),
           "check" => serialize_entry(updated_entry)
         }}

      force_overwrite ->
        merged =
          existing.check
          |> Map.merge(incoming)
          |> Map.put("template_fingerprint", compute_fingerprint(incoming))
          |> Map.put("updated_at", "2026-11-18T05:05:00Z")

        updated_entry = %{existing | check: merged}
        put_entry(updated_entry)

        {:ok,
         %{
           "action" => "updated",
           "dry_run" => false,
           "template_fingerprint" => merged["template_fingerprint"],
           "preserved_parameter_overrides" => merged["parameter_overrides"] || %{},
           "warnings" => [],
           "document" => canonical_export_map(merged),
           "check" => serialize_entry(updated_entry)
         }}

      true ->
        {:ok,
         %{
           "action" => "skipped_diverged",
           "dry_run" => false,
           "template_fingerprint" => existing.check["template_fingerprint"],
           "preserved_parameter_overrides" => existing.check["parameter_overrides"] || %{},
           "warnings" => ["Existing check diverged from managed template; pass force_overwrite to replace"],
           "document" => canonical_export_map(existing.check),
           "check" => serialize_entry(existing)
         }}
    end
  end

  defp execute_ephemeral(check, params) do
    overrides =
      Map.merge(
        check["parameter_overrides"] || %{},
        params["parameter_overrides"] || %{}
      )

    traces =
      Enum.map(check["nodes"] || [], fn node ->
        redacted_inputs =
          node
          |> Map.get("config", %{})
          |> redact_secrets_for_trace()
          |> Map.put("effective_overrides", overrides)

        %{
          "node_id" => node["id"],
          "kind" => node["kind"],
          "status" => "healthy",
          "duration_ms" => 4,
          "resolved_inputs" => redacted_inputs,
          "output" => %{"verdict" => "healthy"},
          "error" => nil
        }
      end)

    {:ok,
     %{
       "schema_version" => 1,
       "ephemeral" => true,
       "slug" => check["slug"],
       "target_key" => "singleton",
       "verdict" => "within_entitlement",
       "status" => "healthy",
       "summary" => "Ephemeral test run completed without mutating ServiceState",
       "duration_ms" => length(traces) * 4,
       "evaluated_at" => "2026-11-18T05:10:00Z",
       "node_traces" => traces
     }}
  end

  defp redact_secrets_for_trace(config) when is_map(config) do
    Map.new(config, fn {key, value} ->
      cond do
        key in ["credential_slot", "auth_header"] ->
          {key, "[REDACTED]"}

        is_map(value) ->
          {key, redact_secrets_for_trace(value)}

        true ->
          {key, value}
      end
    end)
  end

  defp parse_doc(raw) when is_map(raw), do: {:ok, stringify_map(raw)}

  defp parse_doc(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error,
         %{
           kind: :invalid_json,
           errors: [%{path: "$", code: "invalid_json", message: "Top-level value must be a JSON object"}]
         }}

      {:error, err} ->
        {:error,
         %{
           kind: :invalid_json,
           errors: [%{path: "$", code: "invalid_json", message: Exception.message(err)}]
         }}
    end
  end

  defp validate_document(doc) when is_map(doc) do
    secret_issues = scan_secrets(doc, "$")

    if secret_issues == [] do
      schema_issues = validate_schema_and_dag(doc)

      if schema_issues == [] do
        :ok
      else
        {:error, %{kind: :schema_validation, errors: schema_issues}}
      end
    else
      {:error, %{kind: :secret_guard, errors: secret_issues}}
    end
  end

  defp scan_secrets(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      key = to_string(k)
      key_down = String.downcase(key)
      child_path = "#{path}.#{key}"

      key_issue =
        cond do
          MapSet.member?(@secret_keys, key_down) ->
            [
              %{
                path: child_path,
                code: "secret_forbidden",
                message: "Secret or local credential reference key '#{key}' is forbidden in portable check JSON"
              }
            ]

          key_down == "authorization" and is_binary(v) and not String.contains?(v, "{{") ->
            [
              %{
                path: child_path,
                code: "secret_forbidden",
                message: "Literal Authorization header values are forbidden; bind a credential_slot instead"
              }
            ]

          true ->
            []
        end

      key_issue ++ scan_secrets(v, child_path)
    end)
  end

  defp scan_secrets(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> scan_secrets(item, "#{path}[#{idx}]") end)
  end

  defp scan_secrets(value, path) when is_binary(value) do
    if Regex.match?(~r/\bBearer\s+[A-Za-z0-9._~+\/-]+/i, value) do
      [
        %{
          path: path,
          code: "secret_forbidden",
          message: "Literal Bearer token values are forbidden in declarative check JSON"
        }
      ]
    else
      []
    end
  end

  defp scan_secrets(_other, _path), do: []

  defp validate_schema_and_dag(doc) do
    unknown_key_issues =
      doc
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@allowed_top_keys, &1))
      |> Enum.map(fn key ->
        %{path: "$.#{key}", code: "unknown_field", message: "Unknown top-level field '#{key}'"}
      end)

    version_issues =
      if doc["schema_version"] == 1 do
        []
      else
        [%{path: "$.schema_version", code: "invalid_schema_version", message: "schema_version must be 1"}]
      end

    slug_issues =
      if is_binary(doc["slug"]) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,126}[a-z0-9]$/, doc["slug"]) do
        []
      else
        [%{path: "$.slug", code: "invalid_slug", message: "slug must be lowercase kebab-case"}]
      end

    name_issues =
      if is_binary(doc["name"]) and String.trim(doc["name"]) != "" do
        []
      else
        [%{path: "$.name", code: "missing_name", message: "name is required"}]
      end

    nodes = doc["nodes"]
    edges = doc["edges"] || []

    dag_issues =
      cond do
        not is_list(nodes) or nodes == [] ->
          [%{path: "$.nodes", code: "empty_nodes", message: "nodes must be a non-empty array"}]

        not Enum.any?(nodes, &(&1["kind"] == "alert_output")) ->
          [
            %{
              path: "$.nodes",
              code: "missing_alert_output",
              message: "DAG must terminate in at least one alert_output node"
            }
          ]

        has_cycle?(nodes, edges) ->
          [%{path: "$.edges", code: "cycle_detected", message: "Declarative check graph must be acyclic"}]

        true ->
          []
      end

    unknown_key_issues ++ version_issues ++ slug_issues ++ name_issues ++ dag_issues
  end

  defp has_cycle?(nodes, edges) do
    node_ids = MapSet.new(nodes, & &1["id"])

    adj =
      Enum.reduce(edges, %{}, fn edge, acc ->
        src = edge["source"]
        dst = edge["target"]

        if MapSet.member?(node_ids, src) and MapSet.member?(node_ids, dst) do
          Map.update(acc, src, [dst], &[dst | &1])
        else
          acc
        end
      end)

    {cycle?, _visited} =
      Enum.reduce_while(node_ids, {false, %{}}, fn node_id, {_flag, state} ->
        case dfs_visit(node_id, adj, state) do
          {:cycle, next_state} -> {:halt, {true, next_state}}
          {:ok, next_state} -> {:cont, {false, next_state}}
        end
      end)

    cycle?
  end

  defp dfs_visit(node_id, adj, state) do
    case Map.get(state, node_id, :unvisited) do
      :visiting ->
        {:cycle, state}

      :visited ->
        {:ok, state}

      :unvisited ->
        state = Map.put(state, node_id, :visiting)
        neighbors = Map.get(adj, node_id, [])

        result =
          Enum.reduce_while(neighbors, {:ok, state}, fn next_id, {:ok, acc_state} ->
            case dfs_visit(next_id, adj, acc_state) do
              {:cycle, _} = cyc -> {:halt, cyc}
              {:ok, next_state} -> {:cont, {:ok, next_state}}
            end
          end)

        case result do
          {:cycle, _} = cyc -> cyc
          {:ok, done_state} -> {:ok, Map.put(done_state, node_id, :visited)}
        end
    end
  end

  defp ensure_slug_available(slug) do
    if Map.has_key?(store(), slug) do
      {:error,
       %{
         kind: :schema_validation,
         errors: [%{path: "$.slug", code: "slug_taken", message: "Declarative check slug already exists"}]
       }}
    else
      :ok
    end
  end

  defp build_entry(doc, bindings_input) do
    check =
      doc
      |> with_defaults_and_fingerprint()
      |> Map.put_new("id", deterministic_uuid(doc["slug"]))
      |> Map.put_new("last_evaluated_at", nil)
      |> Map.put_new("inserted_at", "2026-11-18T04:30:00Z")
      |> Map.put_new("updated_at", "2026-11-18T04:30:00Z")

    %{
      check: check,
      bindings: normalize_bindings(bindings_input),
      rollup: %{
        "total" => 1,
        "healthy" => 1,
        "degraded" => 0,
        "down" => 0,
        "unknown" => 0
      }
    }
  end

  defp with_defaults_and_fingerprint(doc) do
    with_defaults =
      doc
      |> Map.put_new("schema_version", 1)
      |> Map.put_new("description", nil)
      |> Map.put_new("state", "draft")
      |> Map.put_new("pack_id", nil)
      |> Map.put_new("pack_version", nil)
      |> Map.put_new("managed", false)
      |> Map.put_new("parameter_overrides", %{})
      |> Map.put_new("inputs", [])
      |> Map.put_new("credential_slots", [])
      |> Map.put_new("edges", [])
      |> Map.put_new("alert_policy", %{"emit_ocsf_transition" => true, "open_on_statuses" => ["down"]})
      |> Map.put_new("ui_layout", %{"nodes" => %{}})

    Map.put(with_defaults, "template_fingerprint", compute_fingerprint(with_defaults))
  end

  defp compute_fingerprint(doc) do
    semantic = Map.take(doc, @semantic_keys)
    canonical = encode_sorted_json(semantic, nil)

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonical_export_map(check) do
    check
    |> with_defaults_and_fingerprint()
    |> Map.take(MapSet.to_list(@allowed_top_keys))
  end

  defp normalize_bindings(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.map(fn {raw, idx} ->
      item = stringify_map(raw)
      secret_id = item["credential_secret_id"]
      rule_id = item["credential_rule_id"]

      %{
        "id" => "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(idx), 12, "0")}",
        "slot" => item["slot"],
        "binding_kind" => if(is_binary(rule_id), do: "rule", else: "secret"),
        "credential_secret_id" => secret_id,
        "credential_rule_id" => rule_id,
        "inserted_at" => "2026-11-18T04:30:00Z",
        "updated_at" => "2026-11-18T04:30:00Z"
      }
    end)
  end

  defp serialize_entry(entry) do
    entry.check
    |> Map.put("credential_bindings", entry.bindings)
    |> Map.put("instance_rollup", entry.rollup)
  end

  defp deterministic_uuid(slug) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(3), d::binary-size(3), e::binary-size(12), _::binary>> =
      :sha256 |> :crypto.hash(slug) |> Base.encode16(case: :lower)

    "#{a}-#{b}-4#{c}-8#{d}-#{e}"
  end

  defp encode_sorted_json(map, indent) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    case {pairs, indent} do
      {[], _} ->
        "{}"

      {_, nil} ->
        inner =
          Enum.map_join(pairs, ",", fn {k, v} ->
            Jason.encode!(k) <> ":" <> encode_sorted_json(v, nil)
          end)

        "{" <> inner <> "}"

      {_, level} ->
        pad = String.duplicate("  ", level + 1)
        close_pad = String.duplicate("  ", level)

        inner =
          Enum.map_join(pairs, ",\n", fn {k, v} ->
            pad <> Jason.encode!(k) <> ": " <> encode_sorted_json(v, level + 1)
          end)

        "{\n" <> inner <> "\n" <> close_pad <> "}"
    end
  end

  defp encode_sorted_json(list, indent) when is_list(list) do
    case {list, indent} do
      {[], _} ->
        "[]"

      {_, nil} ->
        "[" <> Enum.map_join(list, ",", &encode_sorted_json(&1, nil)) <> "]"

      {_, level} ->
        pad = String.duplicate("  ", level + 1)
        close_pad = String.duplicate("  ", level)

        inner =
          Enum.map_join(list, ",\n", fn item ->
            pad <> encode_sorted_json(item, level + 1)
          end)

        "[\n" <> inner <> "\n" <> close_pad <> "]"
    end
  end

  defp encode_sorted_json(scalar, _indent), do: Jason.encode!(scalar)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), stringify_value(v)}
    end)
  end

  defp stringify_value(%_{} = struct), do: struct
  defp stringify_value(map) when is_map(map), do: stringify_map(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(other), do: other

  defp store, do: Process.get(@store_key, %{})

  defp put_entry(entry) do
    Process.put(@store_key, Map.put(store(), entry.check["slug"], entry))
  end
end
