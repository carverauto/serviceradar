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
  Exports authored checks, rules, and dashboards into an in-memory secret-free
  `pack_format_version: 1` file map (`%{relative_path => binary}`).
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
    raw_icon = fetch_str(spec, :icon) || @default_icon_svg
    readme = fetch_str(spec, :readme) || default_readme(name, description)

    checks = fetch_val(spec, :checks, [])
    rules = fetch_val(spec, :rules, [])
    dashboards = fetch_val(spec, :dashboards, [])
    assets = fetch_val(spec, :assets, %{})

    with {:ok, icon_uri} <- SvgSanitizer.sanitize_icon(raw_icon),
         {:ok, clean_readme} <- SvgSanitizer.sanitize_markdown(readme),
         {:ok, check_files, check_entries, aggregated_slots} <-
           serialize_checks(checks, pack_id, version),
         {:ok, rule_files, rule_entries} <- serialize_rules(rules),
         {:ok, dashboard_files, dashboard_entries} <- serialize_dashboards(dashboards),
         {:ok, asset_files} <- serialize_assets(assets) do
      explicit_slots = fetch_val(spec, :credential_slots, nil)
      manifest_slots = if is_list(explicit_slots), do: explicit_slots, else: aggregated_slots

      non_manifest_files =
        %{"README.md" => clean_readme}
        |> Map.merge(check_files)
        |> Map.merge(rule_files)
        |> Map.merge(dashboard_files)
        |> Map.merge(asset_files)

      base_manifest = %{
        "pack_format_version" => 1,
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
        "resources" => %{
          "checks" => check_entries,
          "rules" => rule_entries,
          "dashboards" => dashboard_entries
        },
        "files" => %{}
      }

      {:ok, _manifest, full_tree} =
        PackManifest.refresh_manifest_digests(base_manifest, non_manifest_files)

      with :ok <- SecretFreeValidator.validate_pack_tree(full_tree),
           {:ok, _validated} <- PackManifest.validate_pack_tree(full_tree, opts) do
        maybe_audit_export(pack_id, name, version, opts)
        {:ok, full_tree}
      end
    end
  end

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
