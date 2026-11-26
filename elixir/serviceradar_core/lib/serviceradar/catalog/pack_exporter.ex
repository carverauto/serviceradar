defmodule ServiceRadar.Catalog.PackExporter do
  @moduledoc """
  Secret-free Solution Pack serializer (`2.4`, Decision 2).

  Projects live `DeclarativeCheck`, `StatefulAlertRule`, `EventRule`, `ZenRule`,
  and `AuthoredDashboard` (+ `:panels`) records/maps into a deterministic
  `pack_format_version: 1` file tree or `.srpack` archive:
  - Strips database PKs (`id`), `dashboard_ref`, `owner_id`, runtime timestamps,
    `credential_secret_id`, `credential_rule_id`, and `encrypted_secret_payload`.
  - Aggregates abstract `credential_slots` onto `manifest.json` while keeping
    abstract `credential_slots` on `checks/*.json`.
  - Runs `SecretFreeValidator` and `PackManifest` pre-flight validation before
    returning any file tree or archive bytes.
  """

  alias ServiceRadar.Catalog.CatalogNotifier
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON

  @default_icon_svg """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect x="6" y="6" width="36" height="36" rx="8" fill="#0f172a"/><path d="M16 24h16M24 16v16" stroke="#38bdf8" stroke-width="3" stroke-linecap="round"/></svg>
  """

  @doc """
  Exports authored checks, rules, dashboards, Vantage pipelines, signal schemas,
  and dashboard packages into an in-memory secret-free `pack_format_version: 1`
  or `pack_format_version: 2` file map (`%{relative_path => binary}`).
  """
  @spec export_tree(map(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def export_tree(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    pack_id = fetch_str(spec, :id) || "io.serviceradar.custom-pack"
    slug = fetch_str(spec, :slug) || default_slug(pack_id)
    name = fetch_str(spec, :name) || slug
    version = fetch_str(spec, :version) || "0.1.0"
    author = fetch_str(spec, :author) || "ServiceRadar Operator"
    license = fetch_str(spec, :license) || "Apache-2.0"
    description = fetch_str(spec, :description) || "Exported ServiceRadar Solution Pack."
    min_version = fetch_str(spec, :min_serviceradar_version) || "1.0.70"
    categories = fetch_val(spec, :categories, ["Infrastructure"])
    config_defs = fetch_val(spec, :config, [])
    plugin_deps = fetch_val(spec, :plugin_dependencies, [])
    worker_deps = fetch_val(spec, :worker_dependencies, [])
    dashboard_package_deps = fetch_val(spec, :dashboard_package_dependencies, [])
    raw_icon = fetch_str(spec, :icon) || @default_icon_svg
    readme = fetch_str(spec, :readme) || default_readme(name, description)

    checks = fetch_val(spec, :checks, [])
    rules = fetch_val(spec, :rules, [])
    dashboards = fetch_val(spec, :dashboards, [])
    vantage_pipelines = fetch_val(spec, :vantage_pipelines, [])
    signal_schemas = fetch_val(spec, :signal_schemas, [])
    dashboard_packages = fetch_val(spec, :dashboard_packages, [])
    assets = fetch_val(spec, :assets, %{})

    has_v2_content? =
      vantage_pipelines != [] or
        signal_schemas != [] or
        dashboard_packages != [] or
        worker_deps != [] or
        dashboard_package_deps != []

    requested_version =
      fetch_val(spec, :pack_format_version, Keyword.get(opts, :pack_format_version, nil))

    format_version =
      cond do
        requested_version in [1, 2] -> requested_version
        has_v2_content? -> 2
        true -> 1
      end

    with {:ok, icon_uri} <- SvgSanitizer.sanitize_icon(raw_icon),
         {:ok, clean_readme} <- SvgSanitizer.sanitize_markdown(readme),
         {:ok, check_files, check_entries, aggregated_slots} <-
           serialize_checks(checks, pack_id, version),
         {:ok, rule_files, rule_entries} <- serialize_rules(rules),
         {:ok, dashboard_files, dashboard_entries} <- serialize_dashboards(dashboards),
         {:ok, signal_schema_files, signal_schema_entries} <-
           serialize_signal_schemas(signal_schemas),
         {:ok, vantage_pipeline_files, vantage_pipeline_entries} <-
           serialize_vantage_pipelines(vantage_pipelines, pack_id, version),
         {:ok, dashboard_pkg_files, dashboard_pkg_entries} <-
           serialize_dashboard_packages(dashboard_packages, opts),
         {:ok, asset_files} <- serialize_assets(assets) do
      explicit_slots = fetch_val(spec, :credential_slots, nil)
      manifest_slots = if is_list(explicit_slots), do: explicit_slots, else: aggregated_slots

      non_manifest_files =
        %{"README.md" => clean_readme}
        |> Map.merge(check_files)
        |> Map.merge(rule_files)
        |> Map.merge(dashboard_files)
        |> Map.merge(signal_schema_files)
        |> Map.merge(vantage_pipeline_files)
        |> Map.merge(dashboard_pkg_files)
        |> Map.merge(asset_files)

      base_resources = %{
        "checks" => check_entries,
        "rules" => rule_entries,
        "dashboards" => dashboard_entries
      }

      resources =
        if format_version == 2 do
          base_resources
          |> Map.put("vantage_pipelines", vantage_pipeline_entries)
          |> Map.put("signal_schemas", signal_schema_entries)
          |> Map.put("dashboard_packages", dashboard_pkg_entries)
        else
          base_resources
        end

      base_manifest =
        maybe_put_v2_deps(
          %{
            "pack_format_version" => format_version,
            "id" => pack_id,
            "slug" => slug,
            "name" => name,
            "version" => version,
            "author" => author,
            "license" => license,
            "min_serviceradar_version" => min_version,
            "categories" => categories,
            "icon" => icon_uri,
            "description" => description,
            "config" => config_defs,
            "credential_slots" => manifest_slots,
            "plugin_dependencies" => plugin_deps,
            "resources" => resources,
            "files" => %{}
          },
          format_version,
          worker_deps,
          dashboard_package_deps
        )

      {:ok, _manifest, full_tree} =
        PackManifest.refresh_manifest_digests(base_manifest, non_manifest_files)

      with :ok <- SecretFreeValidator.validate_pack_tree(full_tree),
           {:ok, _validated} <- PackManifest.validate_pack_tree(full_tree, opts) do
        maybe_audit_export(pack_id, name, version, opts)
        {:ok, full_tree}
      end
    end
  end

  defp maybe_put_v2_deps(manifest, 2, worker_deps, dashboard_package_deps) do
    manifest
    |> Map.put("worker_dependencies", stringify_map(List.wrap(worker_deps)))
    |> Map.put("dashboard_package_dependencies", stringify_map(List.wrap(dashboard_package_deps)))
  end

  defp maybe_put_v2_deps(manifest, _version, _worker_deps, _dashboard_package_deps), do: manifest

  @doc """
  Exports authored checks, rules, and dashboards directly into deterministic
  `.srpack` (`tar.zst`) archive bytes.
  """
  @spec export_archive(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def export_archive(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    with {:ok, tree} <- export_tree(spec, opts) do
      PackArchive.build(tree, opts)
    end
  end

  ## Resource allowlist projections

  defp serialize_checks(checks, pack_id, version) when is_list(checks) do
    {files, entries, slots_map} =
      Enum.reduce(checks, {%{}, [], %{}}, fn check, {f_acc, e_acc, s_acc} ->
        projected =
          check
          |> strip_live_check_fields()
          |> CanonicalJSON.to_canonical_export_map()
          |> Map.put("pack_id", pack_id)
          |> Map.put("pack_version", version)
          |> Map.put("managed", true)
          |> Map.put("parameter_overrides", %{})

        stamped =
          Map.put(
            projected,
            "template_fingerprint",
            CanonicalJSON.template_fingerprint(projected)
          )

        check_slug = stamped["slug"]
        rel_path = "checks/#{check_slug}.json"
        slots = Enum.map(stamped["credential_slots"] || [], &sanitize_slot_descriptor/1)
        stamped = Map.put(stamped, "credential_slots", slots)

        next_slots =
          Enum.reduce(slots, s_acc, fn s, acc ->
            Map.put_new(acc, s["slot"], s)
          end)

        entry = %{"file" => rel_path, "slug" => check_slug}

        {
          Map.put(f_acc, rel_path, CanonicalJSON.encode_pretty(stamped)),
          [entry | e_acc],
          next_slots
        }
      end)

    sorted_entries = Enum.sort_by(entries, & &1["slug"])
    sorted_slots = slots_map |> Map.values() |> Enum.sort_by(& &1["slot"])
    {:ok, files, sorted_entries, sorted_slots}
  end

  defp strip_live_check_fields(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> strip_live_check_fields()
  end

  defp strip_live_check_fields(map) when is_map(map) do
    Map.drop(map, [
      :id,
      "id",
      :credential_bindings,
      "credential_bindings",
      :credential_secret_id,
      "credential_secret_id",
      :credential_rule_id,
      "credential_rule_id",
      :instances,
      "instances",
      :edge_observations,
      "edge_observations",
      :inserted_at,
      "inserted_at",
      :updated_at,
      "updated_at",
      :last_evaluated_at,
      "last_evaluated_at"
    ])
  end

  defp sanitize_slot_descriptor(slot) when is_map(slot) do
    %{
      "slot" => to_string(fetch_val(slot, :slot, "")),
      "provider" => to_string(fetch_val(slot, :provider, "generic_http")),
      "role" => to_string(fetch_val(slot, :role, "bearer_token")),
      "purpose" => to_string(fetch_val(slot, :purpose, "Authenticate check request")),
      "required" => fetch_val(slot, :required, true) != false
    }
  end

  defp serialize_rules(rules) when is_list(rules) do
    {files, entries} =
      Enum.reduce(rules, {%{}, []}, fn raw_rule, {f_acc, e_acc} ->
        {kind, projected} = project_rule(raw_rule)
        rule_name = projected["name"]
        file_slug = slugify_name(rule_name)
        rel_path = "rules/#{file_slug}.json"
        install_state = projected["install_state"]

        entry = %{
          "file" => rel_path,
          "kind" => kind,
          "name" => rule_name,
          "install_state" => install_state
        }

        {
          Map.put(f_acc, rel_path, CanonicalJSON.encode_pretty(projected)),
          [entry | e_acc]
        }
      end)

    {:ok, files, Enum.sort_by(entries, & &1["name"])}
  end

  defp project_rule(raw_rule) do
    plain = to_plain_map(raw_rule)
    kind = infer_rule_kind(raw_rule, plain)

    install_state =
      case fetch_val(plain, :install_state, nil) do
        state when state in ["enabled", "paused"] ->
          state

        _ ->
          if fetch_val(plain, :enabled, true) == false, do: "paused", else: "enabled"
      end

    projected =
      case kind do
        "stateful_alert_rule" ->
          %{
            "kind" => "stateful_alert_rule",
            "name" => to_string(fetch_val(plain, :name, "")),
            "description" => fetch_val(plain, :description, nil),
            "install_state" => install_state,
            "priority" => fetch_val(plain, :priority, 100),
            "signal" => to_string(fetch_val(plain, :signal, "log")),
            "match" => stringify_map(fetch_val(plain, :match, %{})),
            "group_by" =>
              fetch_val(plain, :group_by, ["serviceradar.sync.integration_source_id"]),
            "threshold" => fetch_val(plain, :threshold, 5),
            "window_seconds" => fetch_val(plain, :window_seconds, 600),
            "bucket_seconds" => fetch_val(plain, :bucket_seconds, 60),
            "cooldown_seconds" => fetch_val(plain, :cooldown_seconds, 300),
            "renotify_seconds" => fetch_val(plain, :renotify_seconds, 21_600),
            "event" => stringify_map(fetch_val(plain, :event, %{})),
            "alert" => stringify_map(fetch_val(plain, :alert, %{}))
          }

        "event_rule" ->
          %{
            "kind" => "event_rule",
            "name" => to_string(fetch_val(plain, :name, "")),
            "install_state" => install_state,
            "priority" => fetch_val(plain, :priority, 100),
            "source_type" => to_string(fetch_val(plain, :source_type, "log")),
            "source" => stringify_map(fetch_val(plain, :source, %{})),
            "match" => stringify_map(fetch_val(plain, :match, %{})),
            "event" => stringify_map(fetch_val(plain, :event, %{}))
          }

        "zen_rule" ->
          %{
            "kind" => "zen_rule",
            "name" => to_string(fetch_val(plain, :name, "")),
            "description" => fetch_val(plain, :description, nil),
            "install_state" => install_state,
            "order" => fetch_val(plain, :order, 100),
            "stream_name" => to_string(fetch_val(plain, :stream_name, "events")),
            "subject" => to_string(fetch_val(plain, :subject, "")),
            "format" => to_string(fetch_val(plain, :format, "json")),
            "template" => to_string(fetch_val(plain, :template, "")),
            "builder_config" => stringify_map(fetch_val(plain, :builder_config, %{})),
            "jdm_definition" => fetch_val(plain, :jdm_definition, nil)
          }
      end

    {kind, projected}
  end

  defp infer_rule_kind(%ServiceRadar.Observability.StatefulAlertRule{}, _plain),
    do: "stateful_alert_rule"

  defp infer_rule_kind(%ServiceRadar.Observability.EventRule{}, _plain), do: "event_rule"
  defp infer_rule_kind(%ServiceRadar.Observability.ZenRule{}, _plain), do: "zen_rule"

  defp infer_rule_kind(_other, plain) do
    cond do
      fetch_val(plain, :kind, nil) in ["stateful_alert_rule", "event_rule", "zen_rule"] ->
        fetch_val(plain, :kind, "stateful_alert_rule")

      not is_nil(fetch_val(plain, :template, nil)) and not is_nil(fetch_val(plain, :subject, nil)) ->
        "zen_rule"

      not is_nil(fetch_val(plain, :source_type, nil)) ->
        "event_rule"

      true ->
        "stateful_alert_rule"
    end
  end

  defp serialize_dashboards(dashboards) when is_list(dashboards) do
    {files, entries} =
      Enum.reduce(dashboards, {%{}, []}, fn raw_dash, {f_acc, e_acc} ->
        projected = project_dashboard(raw_dash)
        dash_slug = projected["slug"]
        rel_path = "dashboards/#{dash_slug}.json"
        entry = %{"file" => rel_path, "slug" => dash_slug}

        {
          Map.put(f_acc, rel_path, CanonicalJSON.encode_pretty(projected)),
          [entry | e_acc]
        }
      end)

    {:ok, files, Enum.sort_by(entries, & &1["slug"])}
  end

  defp project_dashboard(raw_dash) do
    plain = to_plain_map(raw_dash)
    title = to_string(fetch_val(plain, :title, "Overview"))
    slug = fetch_str(plain, :slug) || slugify_dashboard(title)

    panels =
      plain
      |> fetch_val(:panels, [])
      |> List.wrap()
      |> Enum.map(&to_plain_map/1)
      |> Enum.sort_by(&(fetch_val(&1, :position, 0) || 0))
      |> Enum.with_index()
      |> Enum.map(fn {panel, idx} ->
        %{
          "title" => to_string(fetch_val(panel, :title, "Panel #{idx + 1}")),
          "srql_query" => to_string(fetch_val(panel, :srql_query, "")),
          "visual_type" => to_string(fetch_val(panel, :visual_type, "table")),
          "data_binding" => stringify_map(fetch_val(panel, :data_binding, %{})),
          "display_config" => stringify_map(fetch_val(panel, :display_config, %{})),
          "visual_config" => stringify_map(fetch_val(panel, :visual_config, %{})),
          "layout" => stringify_map(fetch_val(panel, :layout, %{})),
          "position" => fetch_val(panel, :position, idx) || idx
        }
      end)

    %{
      "version" => 1,
      "slug" => slug,
      "title" => title,
      "description" => fetch_val(plain, :description, nil),
      "default_time_range" => fetch_str(plain, :default_time_range) || "last_1h",
      "metadata" => stringify_map(fetch_val(plain, :metadata, %{})),
      "variables" => stringify_map(fetch_val(plain, :variables, %{})),
      "panels" => panels
    }
  end

  defp serialize_signal_schemas(schemas) when is_list(schemas) do
    {files, entries} =
      Enum.reduce(schemas, {%{}, []}, fn raw_item, {f_acc, e_acc} ->
        plain = to_plain_map(raw_item)
        schema_id = fetch_str(plain, :schema_id) || fetch_str(plain, :id) || "signal_schema"

        version =
          fetch_str(plain, :version) || fetch_str(plain, :signal_schema_version) || "1.0.0"

        signal_schema =
          fetch_val(plain, :signal_schema, nil) ||
            fetch_val(plain, :schema, %{})

        display_contract =
          fetch_val(plain, :display_contract, nil) ||
            fetch_val(plain, :display, %{})

        display_contract_id =
          fetch_str(plain, :display_contract_id) || schema_id

        file_slug = slugify_name(schema_id)
        schema_doc = stringify_map(signal_schema)
        display_doc = stringify_map(display_contract)

        if is_map(display_doc) and display_doc != %{} do
          schema_path = "signal_schemas/#{file_slug}.schema.json"
          display_path = "signal_schemas/#{file_slug}.display.json"

          entry = %{
            "schema_id" => schema_id,
            "version" => version,
            "schema_file" => schema_path,
            "display_file" => display_path,
            "display_contract_id" => display_contract_id
          }

          next_files =
            f_acc
            |> Map.put(schema_path, CanonicalJSON.encode_pretty(schema_doc))
            |> Map.put(display_path, CanonicalJSON.encode_pretty(display_doc))

          {next_files, [entry | e_acc]}
        else
          combined_path = "signal_schemas/#{file_slug}.json"

          combined_doc = %{
            "schema_id" => schema_id,
            "version" => version,
            "display_contract_id" => display_contract_id,
            "schema" => schema_doc
          }

          entry = %{
            "schema_id" => schema_id,
            "version" => version,
            "file" => combined_path,
            "display_contract_id" => display_contract_id
          }

          {
            Map.put(f_acc, combined_path, CanonicalJSON.encode_pretty(combined_doc)),
            [entry | e_acc]
          }
        end
      end)

    {:ok, files, Enum.sort_by(entries, & &1["schema_id"])}
  end

  defp serialize_vantage_pipelines(pipelines, pack_id, pack_version) when is_list(pipelines) do
    {files, entries} =
      Enum.reduce(pipelines, {%{}, []}, fn raw_pipeline, {f_acc, e_acc} ->
        projected = project_vantage_pipeline(raw_pipeline, pack_id, pack_version)
        pipeline_id = projected["pipeline_id"]
        pipeline_version = projected["version"]
        file_slug = slugify_name(pipeline_id)
        rel_path = "vantage_pipelines/#{file_slug}.json"
        install_state = if projected["enabled"] == false, do: "paused", else: "enabled"

        entry = %{
          "file" => rel_path,
          "pipeline_id" => pipeline_id,
          "version" => pipeline_version,
          "install_state" => install_state
        }

        {
          Map.put(f_acc, rel_path, CanonicalJSON.encode_pretty(projected)),
          [entry | e_acc]
        }
      end)

    {:ok, files, Enum.sort_by(entries, & &1["pipeline_id"])}
  end

  defp project_vantage_pipeline(raw_pipeline, pack_id, pack_version) do
    plain = to_plain_map(raw_pipeline)
    enabled = fetch_val(plain, :enabled, true) != false

    projected =
      %{
        "pipeline_id" => to_string(fetch_val(plain, :pipeline_id, "")),
        "version" => to_string(fetch_val(plain, :version, "1.0.0")),
        "name" => to_string(fetch_val(plain, :name, "")),
        "description" => fetch_val(plain, :description, nil),
        "enabled" => enabled,
        "source_mode" => to_string(fetch_val(plain, :source_mode, "recorded_block")),
        "trigger_kind" => to_string(fetch_val(plain, :trigger_kind, "on_stage1_detection")),
        "camera_selector" => stringify_map(fetch_val(plain, :camera_selector, %{})),
        "object_classes" => List.wrap(fetch_val(plain, :object_classes, [])),
        "min_confidence" => fetch_val(plain, :min_confidence, nil),
        "roi_polygons" => stringify_map(List.wrap(fetch_val(plain, :roi_polygons, []))),
        "input_mode" => to_string(fetch_val(plain, :input_mode, "detection_crop")),
        "crop_policy" => stringify_map(fetch_val(plain, :crop_policy, %{})),
        "max_jobs_per_minute" => fetch_val(plain, :max_jobs_per_minute, 60),
        "max_frames_per_track" => fetch_val(plain, :max_frames_per_track, 3),
        "runner" => to_string(fetch_val(plain, :runner, "camera_vlm")),
        "capability" => fetch_val(plain, :capability, nil),
        "fallback_runner" =>
          case fetch_val(plain, :fallback_runner, nil) do
            nil -> nil
            val -> to_string(val)
          end,
        "vlm_config" => stringify_map(fetch_val(plain, :vlm_config, %{})),
        "signal_schema_id" => to_string(fetch_val(plain, :signal_schema_id, "")),
        "signal_schema_version" => to_string(fetch_val(plain, :signal_schema_version, "1.0.0")),
        "signal_schema" => stringify_map(fetch_val(plain, :signal_schema, %{})),
        "display_contract_id" => to_string(fetch_val(plain, :display_contract_id, "")),
        "display_contract" => stringify_map(fetch_val(plain, :display_contract, %{})),
        "emit_ocsf_events" => fetch_val(plain, :emit_ocsf_events, false) == true,
        "live_observation_retention_days" =>
          fetch_val(plain, :live_observation_retention_days, 30),
        "pack_id" => pack_id,
        "pack_version" => pack_version,
        "managed" => true,
        "parameter_overrides" => %{}
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Map.put(projected, "template_fingerprint", CanonicalJSON.template_fingerprint(projected))
  end

  defp serialize_dashboard_packages(packages, opts) when is_list(packages) do
    blob_loader = Keyword.get(opts, :dashboard_blob_loader)

    packages
    |> Enum.reduce_while({:ok, %{}, []}, fn raw_pkg, {:ok, f_acc, e_acc} ->
      plain = to_plain_map(raw_pkg)
      raw_manifest = fetch_val(plain, :manifest, nil) || %{}

      dash_manifest =
        case raw_manifest do
          bytes when is_binary(bytes) ->
            case Jason.decode(bytes) do
              {:ok, m} when is_map(m) -> m
              _ -> %{}
            end

          m when is_map(m) ->
            stringify_map(m)

          _ ->
            %{}
        end

      dashboard_id =
        fetch_str(plain, :dashboard_id) ||
          Map.get(dash_manifest, "id") ||
          "dashboard-package"

      slug = fetch_str(plain, :slug) || slugify_name(dashboard_id)

      renderer_bytes =
        fetch_val(plain, :renderer_bytes, nil) ||
          fetch_val(plain, :bytes, nil) ||
          fetch_val(plain, :renderer_js, nil) ||
          if(is_function(blob_loader, 1), do: blob_loader.(raw_pkg))

      if is_binary(renderer_bytes) do
        sha256 = PackManifest.sha256_hex(renderer_bytes)
        base_dir = "dashboard_packages/#{slug}"
        manifest_path = "#{base_dir}/manifest.json"
        renderer_path = "#{base_dir}/renderer.js"

        renderer_meta =
          dash_manifest
          |> Map.get("renderer", %{})
          |> stringify_map()
          |> Map.put_new("kind", "browser_module")
          |> Map.put_new("interface_version", "dashboard-browser-module-v1")
          |> Map.put("artifact", "renderer.js")
          |> Map.put("sha256", sha256)
          |> then(fn r ->
            if r["kind"] == "browser_module", do: Map.put_new(r, "trust", "trusted"), else: r
          end)

        normalized_manifest =
          dash_manifest
          |> Map.put_new("id", dashboard_id)
          |> Map.put_new("name", fetch_str(plain, :name) || dashboard_id)
          |> Map.put_new("version", fetch_str(plain, :version) || "1.0.0")
          |> Map.put_new("data_frames", fetch_val(plain, :data_frames, []))
          |> Map.put_new("capabilities", fetch_val(plain, :capabilities, []))
          |> Map.put_new("settings_schema", fetch_val(plain, :settings_schema, %{}))
          |> Map.put("renderer", renderer_meta)

        entry =
          then(%{"slug" => slug, "dir" => base_dir}, fn e ->
            case fetch_str(plain, :route_slug) do
              nil -> e
              rs -> Map.put(e, "route_slug", rs)
            end
          end)

        next_files =
          f_acc
          |> Map.put(manifest_path, CanonicalJSON.encode_pretty(normalized_manifest))
          |> Map.put(renderer_path, renderer_bytes)

        {:cont, {:ok, next_files, [entry | e_acc]}}
      else
        {:halt, {:error, {:missing_dashboard_renderer_bytes, slug}}}
      end
    end)
    |> case do
      {:ok, files, entries} -> {:ok, files, Enum.sort_by(entries, & &1["slug"])}
      err -> err
    end
  end

  defp serialize_assets(assets) when is_map(assets) do
    Enum.reduce_while(assets, {:ok, %{}}, fn {raw_name, bytes}, {:ok, acc} ->
      name = to_string(raw_name)
      rel_path = if String.starts_with?(name, "assets/"), do: name, else: "assets/#{name}"

      cond do
        not PackManifest.safe_relative_path?(rel_path) ->
          {:halt, {:error, {:unsafe_asset_path, rel_path}}}

        String.ends_with?(String.downcase(rel_path), ".svg") ->
          case SvgSanitizer.sanitize_svg(bytes) do
            {:ok, clean} -> {:cont, {:ok, Map.put(acc, rel_path, clean)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        is_binary(bytes) ->
          {:cont, {:ok, Map.put(acc, rel_path, bytes)}}

        true ->
          {:halt, {:error, {:invalid_asset_bytes, rel_path}}}
      end
    end)
  end

  defp maybe_audit_export(pack_id, name, version, opts) do
    if Keyword.get(opts, :emit_audit, false) == true do
      CatalogNotifier.write_operation_audit(:pack_export,
        resource_type: "solution_pack",
        resource_id: pack_id,
        resource_name: name,
        actor: Keyword.get(opts, :actor),
        details: %{"pack_id" => pack_id, "pack_version" => version}
      )
    end
  end

  defp default_slug(pack_id) do
    pack_id
    |> String.split(".")
    |> List.last()
    |> slugify_name()
  end

  defp slugify_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "item"
      s -> s
    end
  end

  defp slugify_dashboard(title) do
    base = slugify_name(title)

    if Regex.match?(~r/\A[a-z]/, base) do
      base
    else
      "dashboard-" <> base
    end
  end

  defp default_readme(name, description) do
    "# #{name}\n\n#{description}\n"
  end

  defp to_plain_map(%{__struct__: _} = s) do
    s
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__lateral_join_source__, :calculations, :aggregates])
  end

  defp to_plain_map(m) when is_map(m), do: m

  defp stringify_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_map(v)} end)
  end

  defp stringify_map(list) when is_list(list), do: Enum.map(list, &stringify_map/1)

  defp stringify_map(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp stringify_map(other), do: other

  defp fetch_val(map, atom_key, default) do
    str_key = Atom.to_string(atom_key)

    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      true -> default
    end
  end

  defp fetch_str(map, atom_key) do
    case fetch_val(map, atom_key, nil) do
      val when is_binary(val) ->
        case String.trim(val) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
