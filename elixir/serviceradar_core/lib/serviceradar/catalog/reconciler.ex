defmodule ServiceRadar.Catalog.Reconciler do
  @moduledoc """
  Guided installation, dry-run diff planner, and `RuleSeeder`-style managed
  upgrade reconciler (`0.1.0 -> 0.2.0`) for Solution Packs (`2.5`, Decision 3).

  ## Reconciliation Guarantees
  1. Validates typed `config` values against `manifest.json` (`min`, `max`, `enum`,
     `required`), binds abstract `credential_slots` to CNPG
     `InstalledSolutionPackCredentialBinding` + `DeclarativeCheckCredentialBinding`,
     and verifies Wasm `plugin_dependencies` via `DependencyChecker`.
  2. Computes baseline `template_fingerprint` digests *after* substituting
     baseline `manifest.config` defaults and *before* applying operator
     `parameter_overrides`, so tuning parameters/thresholds/schedules or toggling
     `enabled` preserves `managed: true` and `template_fingerprint` parity.
  3. Honors `install_state: "paused"` on rules (`enabled: false`, recorded in
     `parameter_overrides["enabled"] = false` so subsequent upgrades never
     re-enable a paused rule without operator action).
  4. Never silently overwrites a structurally diverged (`template_fingerprint`
     mismatch) or detached (`managed: false`) check, rule, or dashboard unless
     the caller explicitly passes `decisions: %{resource_key => :reset_to_upstream}`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Catalog.DependencyChecker
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.Dashboards.PackageImport
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Policies.Checks.ActorHasPermission
  alias ServiceRadar.Repo

  require Ash.Query

  @reconciler_actor SystemActor.system(:solution_pack_reconciler)

  @transaction_resources [
    DeclarativeCheck,
    DeclarativeCheckCredentialBinding,
    StatefulAlertRule,
    EventRule,
    ZenRule,
    AuthoredDashboard,
    DashboardPanel,
    VantagePipeline,
    DashboardPackage,
    DashboardInstance,
    InstalledSolutionPack,
    InstalledSolutionPackCredentialBinding
  ]

  @stateful_rule_structural_fields ~w(signal match group_by event alert)
  @event_rule_structural_fields ~w(source_type source match event)
  @zen_rule_structural_fields ~w(stream_name subject format template builder_config jdm_definition)

  @doc """
  The installed record for `pack_id`, or `nil` when the pack is not installed.
  """
  @spec installed_pack(String.t(), keyword()) :: map() | nil
  def installed_pack(pack_id, opts \\ []) when is_binary(pack_id) and is_list(opts) do
    load_existing_pack(pack_id, opts)
  end

  @doc """
  Computes a dry-run installation or upgrade preview without mutating CNPG.
  """
  @spec preview(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(pack_tree_or_validated, params \\ %{}, opts \\ []) do
    reconcile(pack_tree_or_validated, params, Keyword.put(opts, :dry_run, true))
  end

  @doc """
  Installs or upgrades a Solution Pack atomically (or computes a dry-run plan
  when `dry_run: true`).

  `params` accepts:
  - `"config"` / `:config` -- map of operator parameter values
  - `"credential_bindings"` / `:credential_bindings` -- map or list of slot bindings
    (`%{slot => %{credential_secret_id: ..., credential_rule_id: ...}}` or list of maps)
  - `"decisions"` / `:decisions` -- per-resource conflict choices on upgrade:
    `%{"check:slug" => :keep_customized | :reset_to_upstream | :delete}`
  - `"source"` / `:source` -- provenance metadata (`source_type`, `catalog_repository_id`,
    `source_commit_sha`, `source_release_tag`, `source_branch`, `source_pr_url`, `content_hash`)
  """
  @spec reconcile(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(pack_tree_or_validated, params \\ %{}, opts \\ [])
      when is_map(pack_tree_or_validated) and is_map(params) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    opts =
      if truthy?(fetch_param(params, :install_paused, nil)) do
        Keyword.put_new(opts, :install_paused, true)
      else
        opts
      end

    with :ok <- authorize_reconcile(opts, dry_run?),
         {:ok, validated} <- ensure_validated_pack(pack_tree_or_validated, opts),
         existing_pack = load_existing_pack(validated.manifest["id"], opts),
         merged_raw_config = merge_config_inputs(existing_pack, params),
         {:ok, resolved_config} <-
           PackManifest.validate_config_values(validated.manifest["config"], merged_raw_config),
         {:ok, default_config} <-
           PackManifest.validate_config_values(validated.manifest["config"], %{}),
         {:ok, dep_report} <- DependencyChecker.check(validated.manifest, opts),
         :ok <- enforce_dependencies(dep_report, dry_run?, opts),
         :ok <- authorize_dashboard_activation(validated, params, dry_run?, opts),
         {:ok, normalized_bindings} <-
           normalize_and_validate_bindings(
             validated.manifest["credential_slots"],
             existing_pack,
             params,
             dry_run?,
             opts
           ),
         {:ok, plan} <-
           build_reconciliation_plan(
             validated,
             existing_pack,
             default_config,
             resolved_config,
             normalized_bindings,
             params,
             opts
           ) do
      if dry_run? do
        {:ok, Map.put(plan, :dry_run, true)}
      else
        apply_plan(
          plan,
          validated,
          existing_pack,
          resolved_config,
          normalized_bindings,
          params,
          opts
        )
      end
    end
  end

  @doc """
  Uninstalls a Solution Pack by `pack_id` or `slug`.

  Removes or disables `managed: true` resources (checks, rules, authored
  dashboards, Vantage pipelines, DashboardInstances, and unreferenced
  DashboardPackages + blobs via `:dashboard_blob_store`) while preserving all
  `managed: false` operator-detached/customized resources.
  """
  @spec uninstall(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def uninstall(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    with :ok <- authorize_reconcile(opts, false) do
      case load_existing_pack_by_id_or_slug(id_or_slug, opts) do
        nil ->
          {:error, :not_found}

        existing_pack ->
          case Keyword.get(opts, :state_store) do
            store when is_pid(store) ->
              uninstall_in_memory(existing_pack, store, opts)

            _ ->
              uninstall_in_cnpg(existing_pack, opts)
          end
      end
    end
  end

  @doc """
  Detaches a Solution Pack by `pack_id` or `slug`, marking all `managed: true`
  resources as `managed: false` and removing the `InstalledSolutionPack` record.
  """
  @spec detach(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detach(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    uninstall(id_or_slug, Keyword.put(opts, :mode, :detach))
  end

  @doc """
  Computes the canonical lowercase SHA-256 `template_fingerprint` for a rule map
  or struct (`"stateful_alert_rule" | "event_rule" | "zen_rule"`).
  """
  @spec rule_template_fingerprint(map() | struct(), String.t()) :: String.t()
  def rule_template_fingerprint(rule, kind) do
    plain = to_plain_string_map(rule)

    fields =
      case kind do
        "stateful_alert_rule" -> @stateful_rule_structural_fields
        "event_rule" -> @event_rule_structural_fields
        "zen_rule" -> @zen_rule_structural_fields
      end

    plain
    |> Map.take(fields)
    |> CanonicalJSON.sha256()
  end

  @vantage_pipeline_structural_fields ~w(
    pipeline_id
    version
    name
    source_mode
    trigger_kind
    camera_selector
    object_classes
    min_confidence
    roi_polygons
    input_mode
    crop_policy
    max_jobs_per_minute
    max_frames_per_track
    runner
    capability
    fallback_runner
    vlm_config
    signal_schema_id
    signal_schema_version
    signal_schema
    display_contract_id
    display_contract
    emit_ocsf_events
    live_observation_retention_days
  )

  @doc """
  Computes the canonical lowercase SHA-256 `template_fingerprint` for a
  `VantagePipeline` definition or `%VantagePipeline{}`.
  """
  @spec vantage_pipeline_template_fingerprint(map() | struct()) :: String.t()
  def vantage_pipeline_template_fingerprint(pipeline) do
    plain = to_plain_string_map(pipeline)

    crop_policy =
      case Map.get(plain, "crop_policy") do
        m when is_map(m) and map_size(m) > 0 -> m
        _ -> default_vantage_crop_policy()
      end

    normalized = %{
      "pipeline_id" => to_string(Map.get(plain, "pipeline_id") || ""),
      "version" => to_string(Map.get(plain, "version") || "1.0.0"),
      "name" => to_string(Map.get(plain, "name") || ""),
      "source_mode" => to_string(Map.get(plain, "source_mode") || "recorded_block"),
      "trigger_kind" => to_string(Map.get(plain, "trigger_kind") || "on_stage1_detection"),
      "camera_selector" => Map.get(plain, "camera_selector") || %{},
      "object_classes" => List.wrap(Map.get(plain, "object_classes")),
      "min_confidence" => coerce_optional_float(Map.get(plain, "min_confidence")),
      "roi_polygons" => List.wrap(Map.get(plain, "roi_polygons")),
      "input_mode" => to_string(Map.get(plain, "input_mode") || "detection_crop"),
      "crop_policy" => crop_policy,
      "max_jobs_per_minute" => Map.get(plain, "max_jobs_per_minute") || 60,
      "max_frames_per_track" => Map.get(plain, "max_frames_per_track") || 3,
      "runner" => to_string(Map.get(plain, "runner") || "camera_vlm"),
      "capability" => Map.get(plain, "capability"),
      "fallback_runner" =>
        case Map.get(plain, "fallback_runner") do
          nil -> nil
          val -> to_string(val)
        end,
      "vlm_config" => Map.get(plain, "vlm_config") || %{},
      "signal_schema_id" => to_string(Map.get(plain, "signal_schema_id") || ""),
      "signal_schema_version" => to_string(Map.get(plain, "signal_schema_version") || "1.0.0"),
      "signal_schema" => Map.get(plain, "signal_schema") || %{},
      "display_contract_id" => Map.get(plain, "display_contract_id"),
      "display_contract" => Map.get(plain, "display_contract") || %{},
      "emit_ocsf_events" => Map.get(plain, "emit_ocsf_events") == true,
      "live_observation_retention_days" => Map.get(plain, "live_observation_retention_days") || 30
    }

    normalized
    |> Map.take(@vantage_pipeline_structural_fields)
    |> CanonicalJSON.sha256()
  end

  @doc """
  Computes the canonical lowercase SHA-256 `template_fingerprint` for an authored
  dashboard definition or `%AuthoredDashboard{}` (with `:panels`).
  """
  @spec dashboard_template_fingerprint(map() | struct()) :: String.t()
  def dashboard_template_fingerprint(dash) do
    plain = to_plain_string_map(dash)

    panels =
      plain
      |> Map.get("panels", [])
      |> List.wrap()
      |> Enum.map(&to_plain_string_map/1)
      |> Enum.sort_by(&(Map.get(&1, "position") || 0))
      |> Enum.with_index()
      |> Enum.map(fn {p, idx} ->
        %{
          "title" => to_string(Map.get(p, "title", "")),
          "srql_query" => to_string(Map.get(p, "srql_query", "")),
          "visual_type" => to_string(Map.get(p, "visual_type", "table")),
          "data_binding" => Map.get(p, "data_binding") || %{},
          "display_config" => Map.get(p, "display_config") || %{},
          "visual_config" => Map.get(p, "visual_config") || %{},
          "layout" => Map.get(p, "layout") || %{},
          "position" => Map.get(p, "position", idx)
        }
      end)

    CanonicalJSON.sha256(%{
      "version" => 1,
      "slug" => to_string(Map.get(plain, "slug", "")),
      "title" => to_string(Map.get(plain, "title", "")),
      "default_time_range" => to_string(Map.get(plain, "default_time_range") || "last_1h"),
      "panels" => panels
    })
  end

  ## Plan construction

  defp build_reconciliation_plan(
         validated,
         existing_pack,
         default_config,
         resolved_config,
         bindings,
         params,
         opts
       ) do
    manifest = validated.manifest
    decisions = normalize_decisions(fetch_param(params, :decisions, %{}))
    custom_overrides = compute_config_overrides(default_config, resolved_config)
    activate_dashboards? = activate_dashboard_packages_requested?(params, opts)
    activation_permitted? = has_dashboard_activation_permission?(opts)

    with {:ok, check_plans} <-
           plan_checks(
             validated.checks,
             manifest,
             default_config,
             resolved_config,
             custom_overrides,
             decisions,
             opts
           ),
         {:ok, rule_plans} <-
           plan_rules(
             validated.rules,
             manifest,
             default_config,
             resolved_config,
             custom_overrides,
             decisions,
             opts
           ),
         {:ok, dashboard_plans} <-
           plan_dashboards(
             validated.dashboards,
             manifest,
             default_config,
             resolved_config,
             custom_overrides,
             decisions,
             opts
           ),
         {:ok, {vantage_pipeline_plans, resolved_signal_schemas}} <-
           plan_vantage_pipelines(
             Map.get(validated, :vantage_pipelines, []),
             Map.get(validated, :signal_schemas, []),
             manifest,
             default_config,
             resolved_config,
             custom_overrides,
             decisions,
             opts
           ),
         {:ok, dashboard_package_plans} <-
           plan_dashboard_packages(
             Map.get(validated, :dashboard_packages, []),
             manifest,
             resolved_config,
             params,
             activate_dashboards? and activation_permitted?,
             decisions,
             opts
           ) do
      orphan_plans =
        plan_orphans(
          existing_pack,
          check_plans,
          rule_plans,
          dashboard_plans,
          vantage_pipeline_plans,
          dashboard_package_plans,
          decisions
        )

      {:ok,
       %{
         pack_id: manifest["id"],
         slug: manifest["slug"],
         pack_version: manifest["version"],
         previous_version: existing_pack && field_val(existing_pack, :pack_version),
         mode: if(is_nil(existing_pack), do: :install, else: :upgrade),
         config_values: resolved_config,
         credential_bindings: bindings,
         checks: check_plans,
         rules: rule_plans,
         dashboards: dashboard_plans,
         vantage_pipelines: vantage_pipeline_plans,
         signal_schemas: resolved_signal_schemas,
         dashboard_packages: dashboard_package_plans,
         activate_dashboard_packages: activate_dashboards?,
         dashboard_activation_permitted?: activation_permitted?,
         orphans: orphan_plans,
         has_diverged?:
           Enum.any?(
             check_plans ++ rule_plans ++ dashboard_plans ++ vantage_pipeline_plans,
             &(&1.diverged? == true)
           )
       }}
    end
  end

  defp plan_checks(
         checks,
         manifest,
         default_config,
         resolved_config,
         config_overrides,
         decisions,
         opts
       ) do
    checks
    |> Enum.reduce_while({:ok, []}, fn %{entry: entry, raw: raw_doc}, {:ok, acc} ->
      file = entry["file"]

      with {:ok, baseline_doc} <- PackManifest.resolve_pack_params(raw_doc, default_config, file),
           {:ok, active_doc} <- PackManifest.resolve_pack_params(raw_doc, resolved_config, file) do
        slug = baseline_doc["slug"]
        res_key = "check:#{slug}"
        baseline_fp = CanonicalJSON.template_fingerprint(baseline_doc)
        existing = lookup_existing_check(slug, opts)
        decision = Map.get(decisions, res_key, :keep_customized)

        plan_item =
          classify_check_action(
            res_key,
            slug,
            manifest,
            baseline_doc,
            active_doc,
            baseline_fp,
            config_overrides,
            existing,
            decision
          )

        {:cont, {:ok, [plan_item | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp classify_check_action(
         res_key,
         slug,
         manifest,
         baseline_doc,
         _active_doc,
         baseline_fp,
         config_overrides,
         nil,
         _decision
       ) do
    check_overrides = filter_check_input_overrides(baseline_doc, config_overrides)

    target_doc =
      baseline_doc
      |> Map.put("pack_id", manifest["id"])
      |> Map.put("pack_version", manifest["version"])
      |> Map.put("managed", true)
      |> Map.put("template_fingerprint", baseline_fp)
      |> Map.put("parameter_overrides", check_overrides)

    %{
      key: res_key,
      kind: :check,
      slug: slug,
      action: :create,
      diverged?: false,
      template_fingerprint: baseline_fp,
      parameter_overrides: check_overrides,
      target: target_doc,
      existing: nil
    }
  end

  defp classify_check_action(
         res_key,
         slug,
         manifest,
         baseline_doc,
         _active_doc,
         baseline_fp,
         config_overrides,
         existing,
         decision
       ) do
    was_managed? = field_val(existing, :managed) == true
    stored_fp = field_val(existing, :template_fingerprint)
    current_fp = CanonicalJSON.template_fingerprint(existing)
    diverged? = not was_managed? or stored_fp != current_fp

    existing_overrides = stringify_flat_map(field_val(existing, :parameter_overrides) || %{})

    merged_overrides =
      filter_check_input_overrides(baseline_doc, Map.merge(config_overrides, existing_overrides))

    cond do
      diverged? and decision != :reset_to_upstream ->
        %{
          key: res_key,
          kind: :check,
          slug: slug,
          action: if(was_managed?, do: :skipped_diverged, else: :skipped_detached),
          diverged?: true,
          template_fingerprint: stored_fp,
          parameter_overrides: existing_overrides,
          target: baseline_doc,
          existing: existing
        }

      not diverged? and stored_fp == baseline_fp and
        field_val(existing, :pack_version) == manifest["version"] and
          merged_overrides == existing_overrides ->
        %{
          key: res_key,
          kind: :check,
          slug: slug,
          action: :unchanged,
          diverged?: false,
          template_fingerprint: baseline_fp,
          parameter_overrides: existing_overrides,
          target: baseline_doc,
          existing: existing
        }

      true ->
        preserved_state =
          to_string(field_val(existing, :state) || baseline_doc["state"] || "enabled")

        target_doc =
          baseline_doc
          |> Map.put("pack_id", manifest["id"])
          |> Map.put("pack_version", manifest["version"])
          |> Map.put("managed", true)
          |> Map.put("state", preserved_state)
          |> Map.put("template_fingerprint", baseline_fp)
          |> Map.put("parameter_overrides", merged_overrides)

        %{
          key: res_key,
          kind: :check,
          slug: slug,
          action:
            if(decision == :reset_to_upstream and diverged?,
              do: :reset_to_upstream,
              else: :update
            ),
          diverged?: diverged?,
          template_fingerprint: baseline_fp,
          parameter_overrides: merged_overrides,
          target: target_doc,
          existing: existing
        }
    end
  end

  defp filter_check_input_overrides(baseline_doc, overrides) do
    declared =
      baseline_doc
      |> Map.get("inputs", [])
      |> MapSet.new(&to_string(Map.get(&1, "key") || ""))

    overrides
    |> Enum.filter(fn {k, _v} -> MapSet.member?(declared, to_string(k)) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp plan_rules(
         rules,
         manifest,
         default_config,
         resolved_config,
         config_overrides,
         decisions,
         opts
       ) do
    rules
    |> Enum.reduce_while({:ok, []}, fn %{entry: entry, raw: raw_doc}, {:ok, acc} ->
      file = entry["file"]
      rule_kind = entry["kind"]

      install_state =
        Map.get(raw_doc, "install_state") || Map.get(entry, "install_state", "enabled")

      with {:ok, baseline_doc} <- PackManifest.resolve_pack_params(raw_doc, default_config, file),
           {:ok, active_doc} <- PackManifest.resolve_pack_params(raw_doc, resolved_config, file) do
        name = baseline_doc["name"]
        res_key = "rule:#{rule_kind}:#{name}"
        baseline_fp = rule_template_fingerprint(baseline_doc, rule_kind)
        existing = lookup_existing_rule(rule_kind, name, baseline_doc["subject"], opts)
        decision = Map.get(decisions, res_key, :keep_customized)

        plan_item =
          classify_rule_action(
            res_key,
            rule_kind,
            name,
            install_state,
            manifest,
            baseline_doc,
            active_doc,
            baseline_fp,
            config_overrides,
            existing,
            decision
          )

        {:cont, {:ok, [plan_item | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp classify_rule_action(
         res_key,
         rule_kind,
         name,
         install_state,
         manifest,
         _baseline_doc,
         active_doc,
         baseline_fp,
         config_overrides,
         nil,
         _decision
       ) do
    initial_enabled? = install_state != "paused"

    overrides =
      %{}
      |> maybe_put_map("config", config_overrides)
      |> maybe_put_paused_override(install_state)

    target_doc =
      active_doc
      |> Map.put("enabled", initial_enabled?)
      |> Map.put("pack_id", manifest["id"])
      |> Map.put("pack_version", manifest["version"])
      |> Map.put("managed", true)
      |> Map.put("template_fingerprint", baseline_fp)
      |> Map.put("parameter_overrides", overrides)

    %{
      key: res_key,
      kind: :rule,
      rule_kind: rule_kind,
      name: name,
      install_state: install_state,
      action: :create,
      diverged?: false,
      template_fingerprint: baseline_fp,
      parameter_overrides: overrides,
      target: target_doc,
      existing: nil
    }
  end

  defp classify_rule_action(
         res_key,
         rule_kind,
         name,
         install_state,
         manifest,
         _baseline_doc,
         active_doc,
         baseline_fp,
         config_overrides,
         existing,
         decision
       ) do
    was_managed? = field_val(existing, :managed) == true
    stored_fp = field_val(existing, :template_fingerprint)
    current_fp = rule_template_fingerprint(existing, rule_kind)
    diverged? = not was_managed? or stored_fp != current_fp

    existing_overrides = stringify_flat_map(field_val(existing, :parameter_overrides) || %{})

    preserved_enabled =
      resolve_preserved_rule_enabled(existing, existing_overrides, install_state)

    merged_overrides =
      existing_overrides
      |> Map.put("enabled", preserved_enabled)
      |> maybe_merge_nested_config(config_overrides)

    cond do
      diverged? and decision != :reset_to_upstream ->
        %{
          key: res_key,
          kind: :rule,
          rule_kind: rule_kind,
          name: name,
          install_state: install_state,
          action: if(was_managed?, do: :skipped_diverged, else: :skipped_detached),
          diverged?: true,
          template_fingerprint: stored_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      not diverged? and stored_fp == baseline_fp and
        field_val(existing, :pack_version) == manifest["version"] and
          merged_overrides == existing_overrides ->
        %{
          key: res_key,
          kind: :rule,
          rule_kind: rule_kind,
          name: name,
          install_state: install_state,
          action: :unchanged,
          diverged?: false,
          template_fingerprint: baseline_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      true ->
        target_doc =
          active_doc
          |> apply_rule_knob_overrides(existing, existing_overrides)
          |> Map.put("enabled", preserved_enabled)
          |> Map.put("pack_id", manifest["id"])
          |> Map.put("pack_version", manifest["version"])
          |> Map.put("managed", true)
          |> Map.put("template_fingerprint", baseline_fp)
          |> Map.put("parameter_overrides", merged_overrides)

        %{
          key: res_key,
          kind: :rule,
          rule_kind: rule_kind,
          name: name,
          install_state: install_state,
          action:
            if(decision == :reset_to_upstream and diverged?,
              do: :reset_to_upstream,
              else: :update
            ),
          diverged?: diverged?,
          template_fingerprint: baseline_fp,
          parameter_overrides: merged_overrides,
          target: target_doc,
          existing: existing
        }
    end
  end

  defp resolve_preserved_rule_enabled(existing, existing_overrides, install_state) do
    cond do
      is_boolean(Map.get(existing_overrides, "enabled")) ->
        Map.get(existing_overrides, "enabled")

      is_boolean(field_val(existing, :enabled)) ->
        field_val(existing, :enabled)

      true ->
        install_state != "paused"
    end
  end

  defp apply_rule_knob_overrides(doc, existing, existing_overrides) do
    thresholds = Map.get(existing_overrides, "thresholds") || %{}

    Enum.reduce(
      ~w(threshold window_seconds cooldown_seconds renotify_seconds priority),
      doc,
      fn field, acc ->
        atom_f = String.to_existing_atom(field)

        cond do
          Map.has_key?(thresholds, field) ->
            Map.put(acc, field, Map.get(thresholds, field))

          not is_nil(field_val(existing, atom_f)) and not Map.has_key?(doc, field) ->
            Map.put(acc, field, field_val(existing, atom_f))

          true ->
            acc
        end
      end
    )
  end

  defp plan_dashboards(
         dashboards,
         manifest,
         default_config,
         resolved_config,
         config_overrides,
         decisions,
         opts
       ) do
    dashboards
    |> Enum.reduce_while({:ok, []}, fn %{entry: entry, raw: raw_doc}, {:ok, acc} ->
      file = entry["file"]

      with {:ok, baseline_doc} <- PackManifest.resolve_pack_params(raw_doc, default_config, file),
           {:ok, active_doc} <- PackManifest.resolve_pack_params(raw_doc, resolved_config, file) do
        slug = baseline_doc["slug"]
        res_key = "dashboard:#{slug}"
        baseline_fp = dashboard_template_fingerprint(baseline_doc)
        existing = lookup_existing_dashboard(slug, opts)
        decision = Map.get(decisions, res_key, :keep_customized)

        plan_item =
          classify_dashboard_action(
            res_key,
            slug,
            manifest,
            baseline_doc,
            active_doc,
            baseline_fp,
            config_overrides,
            existing,
            decision
          )

        {:cont, {:ok, [plan_item | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp classify_dashboard_action(
         res_key,
         slug,
         manifest,
         _baseline_doc,
         active_doc,
         baseline_fp,
         config_overrides,
         nil,
         _decision
       ) do
    overrides = maybe_put_map(%{}, "config", config_overrides)

    target_doc =
      active_doc
      |> Map.put("pack_id", manifest["id"])
      |> Map.put("pack_version", manifest["version"])
      |> Map.put("managed", true)
      |> Map.put("template_fingerprint", baseline_fp)
      |> Map.put("parameter_overrides", overrides)

    %{
      key: res_key,
      kind: :dashboard,
      slug: slug,
      action: :create,
      diverged?: false,
      template_fingerprint: baseline_fp,
      parameter_overrides: overrides,
      target: target_doc,
      existing: nil
    }
  end

  defp classify_dashboard_action(
         res_key,
         slug,
         manifest,
         _baseline_doc,
         active_doc,
         baseline_fp,
         config_overrides,
         existing,
         decision
       ) do
    was_managed? = field_val(existing, :managed) == true
    stored_fp = field_val(existing, :template_fingerprint)
    current_fp = dashboard_template_fingerprint(existing)
    diverged? = not was_managed? or stored_fp != current_fp

    existing_overrides = stringify_flat_map(field_val(existing, :parameter_overrides) || %{})
    merged_overrides = maybe_merge_nested_config(existing_overrides, config_overrides)

    cond do
      diverged? and decision != :reset_to_upstream ->
        %{
          key: res_key,
          kind: :dashboard,
          slug: slug,
          action: if(was_managed?, do: :skipped_diverged, else: :skipped_detached),
          diverged?: true,
          template_fingerprint: stored_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      not diverged? and stored_fp == baseline_fp and
        field_val(existing, :pack_version) == manifest["version"] and
          merged_overrides == existing_overrides ->
        %{
          key: res_key,
          kind: :dashboard,
          slug: slug,
          action: :unchanged,
          diverged?: false,
          template_fingerprint: baseline_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      true ->
        merged_vars =
          Map.merge(
            active_doc["variables"] || %{},
            Map.get(existing_overrides, "variables") || %{}
          )

        target_doc =
          active_doc
          |> Map.put("variables", merged_vars)
          |> Map.put("pack_id", manifest["id"])
          |> Map.put("pack_version", manifest["version"])
          |> Map.put("managed", true)
          |> Map.put("template_fingerprint", baseline_fp)
          |> Map.put("parameter_overrides", merged_overrides)

        %{
          key: res_key,
          kind: :dashboard,
          slug: slug,
          action:
            if(decision == :reset_to_upstream and diverged?,
              do: :reset_to_upstream,
              else: :update
            ),
          diverged?: diverged?,
          template_fingerprint: baseline_fp,
          parameter_overrides: merged_overrides,
          target: target_doc,
          existing: existing
        }
    end
  end

  defp plan_vantage_pipelines(
         pipelines,
         signal_schemas,
         manifest,
         default_config,
         resolved_config,
         config_overrides,
         decisions,
         opts
       ) do
    install_paused? = Keyword.get(opts, :install_paused, false) == true

    with {:ok, _baseline_schemas} <- resolve_signal_schemas(signal_schemas, default_config),
         {:ok, active_schemas} <- resolve_signal_schemas(signal_schemas, resolved_config) do
      pipelines
      |> Enum.reduce_while({:ok, []}, fn %{raw: raw_doc, normalized: active_doc, entry: entry},
                                         {:ok, acc} ->
        file = entry["file"] || "vantage_pipeline.json"
        pipeline_id = active_doc["pipeline_id"]
        pipeline_version = active_doc["version"]
        res_key = "vantage_pipeline:#{pipeline_id}:#{pipeline_version}"
        decision = Map.get(decisions, res_key, :keep_customized)

        with {:ok, _baseline_resolved} <-
               PackManifest.resolve_pack_params(raw_doc, default_config, file),
             {:ok, active_resolved} <-
               PackManifest.resolve_pack_params(raw_doc, resolved_config, file) do
          attached = PackManifest.attach_signal_schema(active_resolved, active_schemas)

          active_enriched =
            attached
            |> Map.put("signal_schema", attached["signal_schema"] || %{})
            |> Map.put("display_contract", attached["display_contract"] || %{})
            |> Map.put(
              "display_contract_id",
              attached["display_contract_id"] || attached["signal_schema_id"]
            )

          active_fp = vantage_pipeline_template_fingerprint(active_enriched)
          existing = lookup_existing_vantage_pipeline(pipeline_id, pipeline_version, opts)

          item =
            plan_single_vantage_pipeline(
              res_key,
              manifest,
              entry,
              active_enriched,
              active_fp,
              config_overrides,
              install_paused?,
              existing,
              decision
            )

          {:cont, {:ok, [item | acc]}}
        else
          {:error, errs} -> {:halt, {:error, errs}}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, {Enum.reverse(list), active_schemas}}
        err -> err
      end
    end
  end

  defp resolve_signal_schemas(signal_schemas, config) do
    signal_schemas
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case PackManifest.resolve_signal_schema_entry(item, config) do
        {:ok, resolved_item} -> {:cont, {:ok, [resolved_item | acc]}}
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp plan_single_vantage_pipeline(
         res_key,
         manifest,
         entry,
         active_doc,
         baseline_fp,
         config_overrides,
         install_paused?,
         nil,
         _decision
       ) do
    install_state = Map.get(entry, "install_state", "enabled")

    enabled? =
      cond do
        install_paused? -> false
        install_state == "paused" -> false
        true -> Map.get(active_doc, "enabled", true) != false
      end

    overrides =
      %{}
      |> maybe_put_map("config", config_overrides)
      |> then(fn m -> if enabled?, do: m, else: Map.put(m, "enabled", false) end)

    target =
      active_doc
      |> Map.put("enabled", enabled?)
      |> Map.put("pack_id", manifest["id"])
      |> Map.put("pack_version", manifest["version"])
      |> Map.put("managed", true)
      |> Map.put("template_fingerprint", baseline_fp)
      |> Map.put("parameter_overrides", overrides)

    %{
      key: res_key,
      kind: :vantage_pipeline,
      pipeline_id: active_doc["pipeline_id"],
      version: active_doc["version"],
      action: :create,
      diverged?: false,
      template_fingerprint: baseline_fp,
      parameter_overrides: overrides,
      target: target,
      existing: nil
    }
  end

  defp plan_single_vantage_pipeline(
         res_key,
         manifest,
         _entry,
         active_doc,
         baseline_fp,
         config_overrides,
         install_paused?,
         existing,
         decision
       ) do
    was_managed? = field_val(existing, :managed) == true
    stored_fp = field_val(existing, :template_fingerprint)
    current_fp = vantage_pipeline_template_fingerprint(existing)
    diverged? = not was_managed? or stored_fp != current_fp

    existing_overrides = stringify_flat_map(field_val(existing, :parameter_overrides) || %{})
    merged_overrides = maybe_merge_nested_config(existing_overrides, config_overrides)

    target_enabled =
      cond do
        install_paused? -> false
        Map.has_key?(existing_overrides, "enabled") -> existing_overrides["enabled"] != false
        decision == :reset_to_upstream -> Map.get(active_doc, "enabled", true) != false
        true -> field_val(existing, :enabled) != false
      end

    merged_overrides =
      if install_paused?,
        do: Map.put(merged_overrides, "enabled", false),
        else: merged_overrides

    cond do
      diverged? and decision != :reset_to_upstream ->
        %{
          key: res_key,
          kind: :vantage_pipeline,
          pipeline_id: active_doc["pipeline_id"],
          version: active_doc["version"],
          action: if(was_managed?, do: :skipped_diverged, else: :skipped_detached),
          diverged?: true,
          template_fingerprint: stored_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      not diverged? and stored_fp == baseline_fp and
        field_val(existing, :pack_version) == manifest["version"] and
        merged_overrides == existing_overrides and
          field_val(existing, :enabled) == target_enabled ->
        %{
          key: res_key,
          kind: :vantage_pipeline,
          pipeline_id: active_doc["pipeline_id"],
          version: active_doc["version"],
          action: :unchanged,
          diverged?: false,
          template_fingerprint: baseline_fp,
          parameter_overrides: existing_overrides,
          target: active_doc,
          existing: existing
        }

      true ->
        target =
          active_doc
          |> Map.put("enabled", target_enabled)
          |> Map.put("pack_id", manifest["id"])
          |> Map.put("pack_version", manifest["version"])
          |> Map.put("managed", true)
          |> Map.put("template_fingerprint", baseline_fp)
          |> Map.put("parameter_overrides", merged_overrides)

        %{
          key: res_key,
          kind: :vantage_pipeline,
          pipeline_id: active_doc["pipeline_id"],
          version: active_doc["version"],
          action:
            if(decision == :reset_to_upstream and diverged?,
              do: :reset_to_upstream,
              else: :update
            ),
          diverged?: diverged?,
          template_fingerprint: baseline_fp,
          parameter_overrides: merged_overrides,
          target: target,
          existing: existing
        }
    end
  end

  defp plan_dashboard_packages(
         packages,
         manifest,
         resolved_config,
         params,
         activate?,
         decisions,
         opts
       ) do
    source = stringify_flat_map(fetch_param(params, :source, %{}))
    source_type = coerce_source_type(Map.get(source, "source_type"))

    packages
    |> Enum.reduce_while({:ok, []}, fn pkg_item, {:ok, acc} ->
      dashboard_id = pkg_item.dashboard_id
      pkg_version = pkg_item.version
      slug = pkg_item.slug
      route_slug = pkg_item.entry["route_slug"] || slug
      res_key = "dashboard_package:#{dashboard_id}:#{pkg_version}"
      decision = Map.get(decisions, res_key, :keep_customized)
      existing_pkg = lookup_existing_dashboard_package(dashboard_id, pkg_version, opts)

      case check_dashboard_package_overwrite(existing_pkg, pkg_item) do
        {:error, _} = err ->
          {:halt, err}

        {:ok, overwrite_mode} ->
          existing_instance = lookup_existing_dashboard_instance(route_slug, opts)

          case check_dashboard_route_ownership(
                 existing_instance,
                 dashboard_id,
                 route_slug,
                 activate?
               ) do
            {:error, _} = err ->
              {:halt, err}

            :ok ->
              existing_status =
                existing_pkg && normalize_pkg_status(field_val(existing_pkg, :status))

              target_status =
                cond do
                  activate? -> :enabled
                  not is_nil(existing_status) -> existing_status
                  true -> :staged
                end

              instance_detached? =
                not is_nil(existing_instance) and field_val(existing_instance, :managed) != true and
                  decision != :reset_to_upstream

              bind_instance? = activate? and not instance_detached?

              fp =
                CanonicalJSON.template_fingerprint(%{
                  "dashboard_id" => dashboard_id,
                  "version" => pkg_version,
                  "renderer_sha256" => pkg_item.renderer_sha256,
                  "route_slug" => route_slug
                })

              pkg_action =
                cond do
                  overwrite_mode == :idempotent and existing_status == target_status and
                      not bind_instance? ->
                    :unchanged

                  is_nil(existing_pkg) ->
                    :create

                  true ->
                    :update
                end

              plan_item = %{
                key: res_key,
                kind: :dashboard_package,
                slug: slug,
                route_slug: route_slug,
                dashboard_id: dashboard_id,
                version: pkg_version,
                action: pkg_action,
                overwrite_mode: overwrite_mode,
                target_status: target_status,
                bind_instance?: bind_instance?,
                instance_detached?: instance_detached?,
                source_type: source_type,
                source: source,
                settings: resolved_config,
                pack_id: manifest["id"],
                pack_version: manifest["version"],
                template_fingerprint: fp,
                package_item: pkg_item,
                existing: existing_pkg,
                existing_instance: existing_instance
              }

              {:cont, {:ok, [plan_item | acc]}}
          end
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp check_dashboard_package_overwrite(nil, _pkg_item), do: {:ok, :fresh}

  defp check_dashboard_package_overwrite(existing, pkg_item) do
    existing_hash = String.downcase(to_string(field_val(existing, :content_hash) || ""))
    incoming_hash = String.downcase(to_string(pkg_item.renderer_sha256 || ""))
    status = normalize_pkg_status(field_val(existing, :status))
    ver_status = to_string(field_val(existing, :verification_status) || "")

    cond do
      existing_hash == incoming_hash ->
        {:ok, :idempotent}

      status in [:enabled, :revoked] or ver_status == "verified" ->
        {:error,
         {:version_already_published,
          %{
            dashboard_id: pkg_item.dashboard_id,
            version: pkg_item.version,
            existing_content_hash: existing_hash,
            incoming_content_hash: incoming_hash
          }}}

      true ->
        {:ok, :replace}
    end
  end

  defp check_dashboard_route_ownership(nil, _dashboard_id, _route_slug, _activate?), do: :ok
  defp check_dashboard_route_ownership(_instance, _dashboard_id, _route_slug, false), do: :ok

  defp check_dashboard_route_ownership(instance, dashboard_id, route_slug, true) do
    enabled? = field_val(instance, :enabled) == true
    owner_pkg = field_val(instance, :dashboard_package)
    owner_dash_id = owner_pkg && field_val(owner_pkg, :dashboard_id)

    cond do
      not enabled? ->
        :ok

      is_nil(owner_dash_id) ->
        :ok

      owner_dash_id == dashboard_id ->
        :ok

      true ->
        {:error, {:slug_in_use, %{route_slug: route_slug, owner_dashboard_id: owner_dash_id}}}
    end
  end

  defp plan_orphans(
         nil,
         _checks,
         _rules,
         _dashboards,
         _vantage_pipelines,
         _dashboard_packages,
         _decisions
       ), do: []

  defp plan_orphans(
         existing_pack,
         check_plans,
         rule_plans,
         dashboard_plans,
         vantage_pipeline_plans,
         dashboard_package_plans,
         decisions
       ) do
    prev = field_val(existing_pack, :resource_manifest) || %{}
    next_checks = MapSet.new(check_plans, & &1.slug)
    next_rules = MapSet.new(rule_plans, &{&1.rule_kind, &1.name})
    next_dashboards = MapSet.new(dashboard_plans, & &1.slug)
    next_pipelines = MapSet.new(vantage_pipeline_plans, &{&1.pipeline_id, &1.version})
    next_dash_pkgs = MapSet.new(dashboard_package_plans, &{&1.dashboard_id, &1.version})

    orphan_checks =
      prev
      |> Map.get("checks", [])
      |> Enum.reject(&MapSet.member?(next_checks, &1))
      |> Enum.map(fn slug ->
        key = "check:#{slug}"
        %{key: key, kind: :check, slug: slug, action: orphan_action(decisions, key)}
      end)

    orphan_rules =
      prev
      |> Map.get("rules", [])
      |> Enum.reject(fn r ->
        MapSet.member?(next_rules, {r["kind"], r["name"]})
      end)
      |> Enum.map(fn r ->
        key = "rule:#{r["kind"]}:#{r["name"]}"

        %{
          key: key,
          kind: :rule,
          rule_kind: r["kind"],
          name: r["name"],
          action: orphan_action(decisions, key)
        }
      end)

    orphan_dashboards =
      prev
      |> Map.get("dashboards", [])
      |> Enum.reject(&MapSet.member?(next_dashboards, &1))
      |> Enum.map(fn slug ->
        key = "dashboard:#{slug}"
        %{key: key, kind: :dashboard, slug: slug, action: orphan_action(decisions, key)}
      end)

    orphan_pipelines =
      prev
      |> Map.get("vantage_pipelines", [])
      |> Enum.reject(fn p ->
        MapSet.member?(next_pipelines, {p["pipeline_id"], p["version"]})
      end)
      |> Enum.map(fn p ->
        key = "vantage_pipeline:#{p["pipeline_id"]}:#{p["version"]}"

        %{
          key: key,
          kind: :vantage_pipeline,
          pipeline_id: p["pipeline_id"],
          version: p["version"],
          action: orphan_action(decisions, key)
        }
      end)

    orphan_dash_pkgs =
      prev
      |> Map.get("dashboard_packages", [])
      |> Enum.reject(fn p ->
        MapSet.member?(next_dash_pkgs, {p["dashboard_id"], p["version"]})
      end)
      |> Enum.map(fn p ->
        key = "dashboard_package:#{p["dashboard_id"]}:#{p["version"]}"

        %{
          key: key,
          kind: :dashboard_package,
          dashboard_id: p["dashboard_id"],
          version: p["version"],
          route_slug: p["route_slug"],
          action: orphan_action(decisions, key)
        }
      end)

    orphan_checks ++ orphan_rules ++ orphan_dashboards ++ orphan_pipelines ++ orphan_dash_pkgs
  end

  defp orphan_action(decisions, key) do
    case Map.get(decisions, key) do
      :delete -> :delete_orphan
      _ -> :detach_orphan
    end
  end

  ## Applying the Plan (CNPG Transaction or In-Memory Store)

  defp apply_plan(plan, validated, existing_pack, resolved_config, bindings, params, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) or is_function(store, 2) ->
        apply_plan_in_memory(
          plan,
          validated,
          existing_pack,
          resolved_config,
          bindings,
          params,
          store,
          opts
        )

      nil ->
        apply_plan_in_cnpg(
          plan,
          validated,
          existing_pack,
          resolved_config,
          bindings,
          params,
          opts
        )
    end
  end

  defp apply_plan_in_cnpg(plan, validated, existing_pack, resolved_config, bindings, params, opts) do
    caller_actor = extract_actor(opts) || @reconciler_actor
    source = stringify_flat_map(fetch_param(params, :source, %{}))

    tx_fun = fn ->
      with {:ok, check_results} <- apply_checks_cnpg(plan.checks, bindings, opts),
           {:ok, rule_results} <- apply_rules_cnpg(plan.rules),
           {:ok, dash_results} <- apply_dashboards_cnpg(plan.dashboards, caller_actor),
           {:ok, vp_results} <- apply_vantage_pipelines_cnpg(plan.vantage_pipelines),
           {:ok, dp_results} <-
             apply_dashboard_packages_cnpg(plan.dashboard_packages, caller_actor, opts),
           :ok <-
             apply_orphans_cnpg(
               plan.orphans,
               active_bound_dashboard_slugs(plan.dashboard_packages),
               opts
             ),
           {:ok, installed_pack} <-
             upsert_installed_pack_cnpg(
               validated.manifest,
               existing_pack,
               resolved_config,
               bindings,
               dp_results,
               source,
               caller_actor
             ) do
        {:ok,
         Map.merge(plan, %{
           dry_run: false,
           installed_pack: installed_pack,
           applied_checks: check_results,
           applied_rules: rule_results,
           applied_dashboards: dash_results,
           applied_vantage_pipelines: vp_results,
           applied_dashboard_packages: dp_results
         })}
      end
    end

    if is_pid(Process.whereis(Repo)) do
      # Ash.transact, not Repo.transaction: it delivers the resources'
      # notifications once the transaction commits. Without them an installed
      # check is never scheduled and its alert rule is never reconciled.
      Ash.transact(@transaction_resources, fn ->
        case tx_fun.() do
          {:ok, res} -> res
          {:error, err} -> {:error, err}
        end
      end)
    else
      tx_fun.()
    end
  end

  defp apply_checks_cnpg(check_plans, pack_bindings, opts) do
    ctx_base = if Keyword.get(opts, :skip_srql_nif?, true), do: %{skip_srql_nif?: true}, else: %{}

    check_plans
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      res =
        case item.action do
          :create ->
            attrs = check_doc_to_ash_attrs(item.target, true)

            with {:ok, created} <-
                   DeclarativeCheck
                   |> Ash.Changeset.for_create(:create, attrs,
                     actor: @reconciler_actor,
                     context: ctx_base
                   )
                   |> Ash.create(actor: @reconciler_actor),
                 :ok <- project_check_bindings_cnpg(created, pack_bindings) do
              {:ok, %{slug: item.slug, action: :created, record: created}}
            end

          act when act in [:update, :reset_to_upstream] ->
            attrs = check_doc_to_ash_attrs(item.target, false)
            ctx = Map.put(ctx_base, :reconcile_managed, true)

            with {:ok, updated} <-
                   item.existing
                   |> Ash.Changeset.for_update(:update, attrs,
                     actor: @reconciler_actor,
                     context: ctx
                   )
                   |> Ash.update(actor: @reconciler_actor),
                 :ok <- project_check_bindings_cnpg(updated, pack_bindings) do
              {:ok, %{slug: item.slug, action: act, record: updated}}
            end

          other ->
            if item.existing do
              _ = project_check_bindings_cnpg(item.existing, pack_bindings)
            end

            {:ok, %{slug: item.slug, action: other, record: item.existing}}
        end

      case res do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp project_check_bindings_cnpg(check, pack_bindings) do
    declared_slots =
      check.credential_slots
      |> List.wrap()
      |> MapSet.new(&to_string(&1["slot"] || &1[:slot] || ""))

    relevant =
      Enum.filter(pack_bindings, fn b ->
        MapSet.member?(declared_slots, b.slot)
      end)

    Enum.reduce_while(relevant, :ok, fn b, :ok ->
      attrs = %{
        check_id: check.id,
        slot: b.slot,
        credential_secret_id: b.credential_secret_id,
        credential_rule_id: b.credential_rule_id
      }

      case DeclarativeCheckCredentialBinding.upsert_binding(attrs, actor: @reconciler_actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp apply_rules_cnpg(rule_plans) do
    rule_plans
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      res =
        case item.action do
          :create ->
            create_rule_cnpg(item.rule_kind, item.target)

          act when act in [:update, :reset_to_upstream] ->
            update_rule_cnpg(item.rule_kind, item.existing, item.target, act)

          other ->
            {:ok, %{name: item.name, kind: item.rule_kind, action: other, record: item.existing}}
        end

      case res do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp create_rule_cnpg(kind, doc) do
    {mod, attrs} = rule_module_and_attrs(kind, doc)

    case mod
         |> Ash.Changeset.for_create(:create, attrs, actor: @reconciler_actor)
         |> Ash.create(actor: @reconciler_actor) do
      {:ok, created} -> {:ok, %{name: doc["name"], kind: kind, action: :created, record: created}}
      {:error, err} -> {:error, err}
    end
  end

  defp update_rule_cnpg(kind, existing, doc, act) do
    {_mod, attrs} = rule_module_and_attrs(kind, doc)

    case existing
         |> Ash.Changeset.for_update(:update, attrs, actor: @reconciler_actor)
         |> Ash.update(actor: @reconciler_actor) do
      {:ok, updated} -> {:ok, %{name: doc["name"], kind: kind, action: act, record: updated}}
      {:error, err} -> {:error, err}
    end
  end

  defp rule_module_and_attrs("stateful_alert_rule", doc) do
    attrs = %{
      name: doc["name"],
      description: doc["description"],
      enabled: doc["enabled"] != false,
      priority: doc["priority"] || 100,
      signal: String.to_existing_atom(to_string(doc["signal"] || "log")),
      match: doc["match"] || %{},
      group_by: doc["group_by"] || ["serviceradar.sync.integration_source_id"],
      threshold: doc["threshold"] || 5,
      window_seconds: doc["window_seconds"] || 600,
      bucket_seconds: doc["bucket_seconds"] || 60,
      cooldown_seconds: doc["cooldown_seconds"] || 300,
      renotify_seconds: doc["renotify_seconds"] || 21_600,
      event: doc["event"] || %{},
      alert: doc["alert"] || %{},
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: doc["managed"] == true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    {StatefulAlertRule, attrs}
  end

  defp rule_module_and_attrs("event_rule", doc) do
    attrs = %{
      name: doc["name"],
      enabled: doc["enabled"] != false,
      priority: doc["priority"] || 100,
      source_type: String.to_existing_atom(to_string(doc["source_type"] || "log")),
      source: doc["source"] || %{},
      match: doc["match"] || %{},
      event: doc["event"] || %{},
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: doc["managed"] == true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    {EventRule, attrs}
  end

  defp rule_module_and_attrs("zen_rule", doc) do
    attrs = %{
      name: doc["name"],
      description: doc["description"],
      enabled: doc["enabled"] != false,
      order: doc["order"] || 100,
      stream_name: doc["stream_name"] || "events",
      subject: doc["subject"],
      template: doc["template"],
      builder_config: doc["builder_config"] || %{},
      jdm_definition: doc["jdm_definition"],
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: doc["managed"] == true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    {ZenRule, attrs}
  end

  defp apply_dashboards_cnpg(dashboard_plans, _caller_actor) do
    dashboard_plans
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      res =
        case item.action do
          :create ->
            create_dashboard_cnpg(item.target)

          act when act in [:update, :reset_to_upstream] ->
            update_dashboard_cnpg(item.existing, item.target, act)

          other ->
            {:ok, %{slug: item.slug, action: other, record: item.existing}}
        end

      case res do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp create_dashboard_cnpg(doc, attempts \\ 0)

  defp create_dashboard_cnpg(_doc, attempts) when attempts >= 8 do
    {:error, :dashboard_ref_generation_failed}
  end

  defp create_dashboard_cnpg(doc, attempts) do
    ref = Enum.random(1_000_000..9_999_999)

    attrs = %{
      dashboard_ref: ref,
      slug: doc["slug"],
      title: doc["title"],
      description: doc["description"],
      visibility: :public,
      status: :active,
      default_time_range: doc["default_time_range"] || "last_1h",
      layout: %{},
      variables: doc["variables"] || %{},
      metadata: doc["metadata"] || %{},
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    case AuthoredDashboard
         |> Ash.Changeset.for_create(:create, attrs, actor: @reconciler_actor)
         |> Ash.create(actor: @reconciler_actor) do
      {:ok, dashboard} ->
        with :ok <- replace_dashboard_panels_cnpg(dashboard.id, doc["panels"] || []) do
          {:ok, %{slug: doc["slug"], action: :created, record: dashboard}}
        end

      {:error, err} ->
        if String.contains?(Exception.message(err), "dashboard_ref") do
          create_dashboard_cnpg(doc, attempts + 1)
        else
          {:error, err}
        end
    end
  end

  defp update_dashboard_cnpg(existing, doc, act) do
    attrs = %{
      title: doc["title"],
      description: doc["description"],
      default_time_range: doc["default_time_range"] || "last_1h",
      variables: doc["variables"] || %{},
      metadata: doc["metadata"] || %{},
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    with {:ok, updated} <-
           existing
           |> Ash.Changeset.for_update(:update, attrs, actor: @reconciler_actor)
           |> Ash.update(actor: @reconciler_actor),
         :ok <- replace_dashboard_panels_cnpg(updated.id, doc["panels"] || []) do
      {:ok, %{slug: doc["slug"], action: act, record: updated}}
    end
  end

  defp replace_dashboard_panels_cnpg(dashboard_id, panels) do
    with {:ok, existing_panels} <-
           DashboardPanel.list_for_dashboard(dashboard_id, actor: @reconciler_actor),
         :ok <- destroy_all_panels(existing_panels) do
      panels
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {panel, idx}, :ok ->
        p_attrs = %{
          dashboard_id: dashboard_id,
          title: panel["title"],
          srql_query: panel["srql_query"],
          visual_type: String.to_existing_atom(to_string(panel["visual_type"])),
          data_binding: panel["data_binding"] || %{},
          display_config: panel["display_config"] || %{},
          visual_config: panel["visual_config"] || %{},
          layout: panel["layout"],
          position: panel["position"] || idx
        }

        case DashboardPanel.create_panel(p_attrs, actor: @reconciler_actor) do
          {:ok, _} -> {:cont, :ok}
          {:error, err} -> {:halt, {:error, err}}
        end
      end)
    end
  end

  defp destroy_all_panels(panels) do
    Enum.reduce_while(panels, :ok, fn p, :ok ->
      case Ash.destroy(p, actor: @reconciler_actor) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp apply_vantage_pipelines_cnpg(vp_plans) do
    vp_plans
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      res =
        case item.action do
          :create ->
            upsert_vantage_pipeline_cnpg(item.target, :created)

          act when act in [:update, :reset_to_upstream] ->
            upsert_vantage_pipeline_cnpg(item.target, act)

          act ->
            {:ok, %{pipeline_id: item.pipeline_id, version: item.version, action: act}}
        end

      case res do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp upsert_vantage_pipeline_cnpg(doc, result_action) do
    attrs = %{
      pipeline_id: doc["pipeline_id"],
      version: doc["version"],
      name: doc["name"],
      description: doc["description"],
      enabled: doc["enabled"] != false,
      source_mode: String.to_existing_atom(to_string(doc["source_mode"] || "recorded_block")),
      trigger_kind:
        String.to_existing_atom(to_string(doc["trigger_kind"] || "on_stage1_detection")),
      camera_selector: doc["camera_selector"] || %{},
      object_classes: doc["object_classes"] || [],
      min_confidence: coerce_optional_float(doc["min_confidence"]),
      roi_polygons: doc["roi_polygons"] || [],
      input_mode: String.to_existing_atom(to_string(doc["input_mode"] || "detection_crop")),
      crop_policy:
        case doc["crop_policy"] do
          m when is_map(m) and map_size(m) > 0 -> m
          _ -> default_vantage_crop_policy()
        end,
      max_jobs_per_minute: doc["max_jobs_per_minute"] || 60,
      max_frames_per_track: doc["max_frames_per_track"] || 3,
      runner: String.to_existing_atom(to_string(doc["runner"] || "camera_vlm")),
      capability: doc["capability"],
      fallback_runner: doc["fallback_runner"],
      vlm_config: doc["vlm_config"] || %{},
      signal_schema_id: doc["signal_schema_id"],
      signal_schema_version: doc["signal_schema_version"],
      signal_schema: doc["signal_schema"] || %{},
      display_contract_id: doc["display_contract_id"],
      display_contract: doc["display_contract"] || %{},
      emit_ocsf_events: doc["emit_ocsf_events"] == true,
      live_observation_retention_days: doc["live_observation_retention_days"] || 30,
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: true,
      template_fingerprint: doc["template_fingerprint"],
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    case VantagePipeline
         |> Ash.Changeset.for_create(:upsert, attrs, actor: @reconciler_actor)
         |> Ash.create(actor: @reconciler_actor) do
      {:ok, record} ->
        {:ok,
         %{
           pipeline_id: record.pipeline_id,
           version: record.version,
           action: result_action,
           record: record
         }}

      {:error, err} ->
        {:error, err}
    end
  end

  defp default_vantage_crop_policy do
    %{
      "padding_ratio" => 0.15,
      "min_bbox_width_px" => 96,
      "max_dimension" => 640,
      "max_bytes" => 98_304
    }
  end

  defp coerce_optional_float(nil), do: nil
  defp coerce_optional_float(v) when is_float(v), do: v
  defp coerce_optional_float(v) when is_integer(v), do: v * 1.0
  defp coerce_optional_float(_), do: nil

  defp apply_dashboard_packages_cnpg(plans, caller_actor, opts) do
    plans
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case apply_one_dashboard_package_cnpg(item, caller_actor, opts) do
        {:ok, res} -> {:cont, {:ok, [res | acc]}}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp apply_one_dashboard_package_cnpg(item, _caller_actor, opts) do
    pkg_item = item.package_item
    dash_manifest = pkg_item.dashboard_manifest

    import_opts = [
      content_hash: pkg_item.renderer_sha256,
      source_type: item.source_type,
      source_repo_url: Map.get(item.source, "source_repo_url"),
      source_ref:
        Map.get(item.source, "source_ref") || Map.get(item.source, "source_branch") ||
          Map.get(item.source, "source_release_tag"),
      source_manifest_path: pkg_item.manifest_path,
      source_commit: Map.get(item.source, "source_commit_sha"),
      source_bundle_digest: Map.get(item.source, "content_hash"),
      source_metadata:
        Map.merge(dash_manifest.source || %{}, %{
          "pack_id" => item.pack_id,
          "pack_version" => item.pack_version
        }),
      verification_status: "verified",
      pack_id: item.pack_id,
      pack_version: item.pack_version,
      managed: true,
      template_fingerprint: item.template_fingerprint
    ]

    with {:ok, attrs} <- PackageImport.attrs_from_manifest(dash_manifest, import_opts),
         {:ok, pkg} <-
           upsert_and_store_dashboard_package_cnpg(
             item,
             Map.delete(attrs, :status),
             pkg_item,
             opts
           ),
         {:ok, pkg} <- maybe_enable_dashboard_package_cnpg(pkg, item.target_status),
         {:ok, instance} <- maybe_bind_dashboard_instance_cnpg(pkg, item) do
      {:ok,
       %{
         dashboard_id: pkg.dashboard_id,
         version: pkg.version,
         route_slug: item.route_slug,
         status: pkg.status,
         package: pkg,
         instance: instance,
         action:
           cond do
             item.bind_instance? and pkg.status == :enabled -> :enabled
             pkg.status == :enabled -> :enabled
             pkg.status in [:disabled, :revoked] -> pkg.status
             true -> :staged
           end
       }}
    end
  end

  defp upsert_and_store_dashboard_package_cnpg(
         %{overwrite_mode: :idempotent, existing: %DashboardPackage{wasm_object_key: key} = pkg},
         _attrs,
         _pkg_item,
         _opts
       )
       when is_binary(key) and key != "" do
    {:ok, pkg}
  end

  defp upsert_and_store_dashboard_package_cnpg(item, attrs, pkg_item, opts) do
    existing_key =
      case item.existing do
        %DashboardPackage{wasm_object_key: k} when is_binary(k) and k != "" -> k
        _ -> nil
      end

    with {:ok, pkg} <-
           DashboardPackage
           |> Ash.Changeset.for_create(:upsert, attrs, actor: @reconciler_actor)
           |> Ash.create(actor: @reconciler_actor),
         object_key = existing_key || dashboard_object_key(pkg, pkg_item),
         :ok <- dashboard_blob_store_put(object_key, pkg_item.renderer_bytes, opts),
         {:ok, pkg} <- update_dashboard_package_blob_key(pkg, object_key) do
      ensure_dashboard_package_verified(pkg)
    end
  end

  defp update_dashboard_package_blob_key(%DashboardPackage{wasm_object_key: key} = pkg, key),
    do: {:ok, pkg}

  defp update_dashboard_package_blob_key(%DashboardPackage{} = pkg, object_key) do
    pkg
    |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key}, actor: @reconciler_actor)
    |> Ash.update(actor: @reconciler_actor)
  end

  defp ensure_dashboard_package_verified(
         %DashboardPackage{verification_status: "verified"} = pkg
       ), do: {:ok, pkg}

  defp ensure_dashboard_package_verified(%DashboardPackage{} = pkg) do
    pkg
    |> Ash.Changeset.for_update(:mark_verified, %{}, actor: @reconciler_actor)
    |> Ash.update(actor: @reconciler_actor)
  end

  defp maybe_enable_dashboard_package_cnpg(%DashboardPackage{status: :enabled} = pkg, _target),
    do: {:ok, pkg}

  defp maybe_enable_dashboard_package_cnpg(%DashboardPackage{} = pkg, :enabled) do
    pkg
    |> Ash.Changeset.for_update(:enable, %{}, actor: @reconciler_actor)
    |> Ash.update(actor: @reconciler_actor)
  end

  defp maybe_enable_dashboard_package_cnpg(%DashboardPackage{} = pkg, _staged), do: {:ok, pkg}

  defp maybe_bind_dashboard_instance_cnpg(_pkg, %{bind_instance?: false}), do: {:ok, nil}

  defp maybe_bind_dashboard_instance_cnpg(%DashboardPackage{} = pkg, item) do
    attrs = %{
      dashboard_package_id: pkg.id,
      name: pkg.name || pkg.dashboard_id,
      route_slug: item.route_slug,
      placement: :dashboard,
      enabled: true,
      visibility:
        case item.existing_instance do
          %DashboardInstance{visibility: vis} -> vis
          _ -> :public
        end,
      settings: item.settings || %{},
      metadata: %{"pack_id" => item.pack_id, "pack_version" => item.pack_version},
      pack_id: item.pack_id,
      pack_version: item.pack_version,
      managed: true,
      template_fingerprint: item.template_fingerprint
    }

    DashboardInstance
    |> Ash.Changeset.for_create(:upsert, attrs, actor: @reconciler_actor)
    |> Ash.create(actor: @reconciler_actor)
  end

  defp active_bound_dashboard_slugs(dashboard_packages) do
    dashboard_packages
    |> List.wrap()
    |> Enum.filter(&(&1.bind_instance? == true))
    |> MapSet.new(& &1.route_slug)
  end

  defp apply_orphans_cnpg(orphans, active_bound_slugs, opts) do
    Enum.reduce_while(orphans, :ok, fn orphan, :ok ->
      res =
        case {orphan.kind, orphan.action} do
          {:check, :detach_orphan} ->
            detach_check_cnpg(orphan.slug)

          {:check, :delete_orphan} ->
            delete_check_cnpg(orphan.slug)

          {:rule, :detach_orphan} ->
            detach_rule_cnpg(orphan.rule_kind, orphan.name)

          {:rule, :delete_orphan} ->
            delete_rule_cnpg(orphan.rule_kind, orphan.name)

          {:dashboard, :detach_orphan} ->
            detach_dashboard_cnpg(orphan.slug)

          {:dashboard, :delete_orphan} ->
            delete_dashboard_cnpg(orphan.slug)

          {:vantage_pipeline, :detach_orphan} ->
            detach_vantage_pipeline_cnpg(orphan.pipeline_id, orphan.version)

          {:vantage_pipeline, :delete_orphan} ->
            delete_vantage_pipeline_cnpg(orphan.pipeline_id, orphan.version)

          {:dashboard_package, :detach_orphan} ->
            detach_dashboard_package_cnpg(
              orphan.dashboard_id,
              orphan.version,
              orphan.route_slug,
              active_bound_slugs
            )

          {:dashboard_package, :delete_orphan} ->
            delete_dashboard_package_cnpg(
              orphan.dashboard_id,
              orphan.version,
              orphan.route_slug,
              active_bound_slugs,
              opts
            )
        end

      case res do
        :ok -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp detach_check_cnpg(slug) do
    case DeclarativeCheck.get_by_slug(slug, actor: @reconciler_actor) do
      {:ok, %DeclarativeCheck{} = c} ->
        c
        |> Ash.Changeset.for_update(:update, %{managed: false},
          actor: @reconciler_actor,
          context: %{reconcile_managed: true}
        )
        |> Ash.update(actor: @reconciler_actor)
        |> case do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp delete_check_cnpg(slug) do
    case DeclarativeCheck.get_by_slug(slug, actor: @reconciler_actor) do
      {:ok, %DeclarativeCheck{} = c} ->
        case Ash.destroy(c, actor: @reconciler_actor) do
          :ok -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp detach_rule_cnpg(kind, name) do
    case lookup_existing_rule_cnpg(kind, name, nil) do
      nil ->
        :ok

      rule ->
        rule
        |> Ash.Changeset.for_update(:update, %{managed: false}, actor: @reconciler_actor)
        |> Ash.update(actor: @reconciler_actor)
        |> case do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end
    end
  end

  defp delete_rule_cnpg(kind, name) do
    case lookup_existing_rule_cnpg(kind, name, nil) do
      nil ->
        :ok

      rule ->
        case Ash.destroy(rule, actor: @reconciler_actor) do
          :ok -> :ok
          {:error, err} -> {:error, err}
        end
    end
  end

  defp detach_dashboard_cnpg(slug) do
    case AuthoredDashboard.get_by_slug(slug, actor: @reconciler_actor) do
      {:ok, %AuthoredDashboard{} = d} ->
        d
        |> Ash.Changeset.for_update(:update, %{managed: false}, actor: @reconciler_actor)
        |> Ash.update(actor: @reconciler_actor)
        |> case do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp delete_dashboard_cnpg(slug) do
    case AuthoredDashboard.get_by_slug(slug, actor: @reconciler_actor) do
      {:ok, %AuthoredDashboard{} = d} ->
        case Ash.destroy(d, actor: @reconciler_actor) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp detach_vantage_pipeline_cnpg(pipeline_id, version) do
    case VantagePipeline.get_by_pipeline_version(pipeline_id, version, actor: @reconciler_actor) do
      {:ok, %VantagePipeline{} = vp} ->
        vp
        |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
          actor: @reconciler_actor
        )
        |> Ash.update(actor: @reconciler_actor)
        |> case do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp delete_vantage_pipeline_cnpg(pipeline_id, version) do
    case VantagePipeline.get_by_pipeline_version(pipeline_id, version, actor: @reconciler_actor) do
      {:ok, %VantagePipeline{} = vp} ->
        case Ash.destroy(vp, actor: @reconciler_actor) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp detach_dashboard_package_cnpg(dashboard_id, version, route_slug, active_bound_slugs) do
    case lookup_existing_dashboard_package_cnpg(dashboard_id, version) do
      %DashboardPackage{} = pkg ->
        with :ok <-
               maybe_detach_orphan_dashboard_instance_cnpg(
                 route_slug,
                 pkg.id,
                 active_bound_slugs
               ) do
          pkg
          |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
            actor: @reconciler_actor
          )
          |> Ash.update(actor: @reconciler_actor)
          |> case do
            {:ok, _} -> :ok
            {:error, err} -> {:error, err}
          end
        end

      _ ->
        :ok
    end
  end

  defp delete_dashboard_package_cnpg(dashboard_id, version, route_slug, active_bound_slugs, opts) do
    case lookup_existing_dashboard_package_cnpg(dashboard_id, version) do
      %DashboardPackage{} = pkg ->
        with :ok <-
               maybe_destroy_orphan_dashboard_instance_cnpg(
                 route_slug,
                 pkg.id,
                 active_bound_slugs
               ) do
          if dashboard_package_referenced_by_instance_cnpg?(pkg.id) do
            pkg
            |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
              actor: @reconciler_actor
            )
            |> Ash.update(actor: @reconciler_actor)
            |> case do
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          else
            blob_key = pkg.wasm_object_key

            case Ash.destroy(pkg, actor: @reconciler_actor) do
              :ok -> maybe_delete_unreferenced_blob_cnpg(blob_key, opts)
              {:ok, _} -> maybe_delete_unreferenced_blob_cnpg(blob_key, opts)
              {:error, err} -> {:error, err}
            end
          end
        end

      _ ->
        :ok
    end
  end

  defp maybe_detach_orphan_dashboard_instance_cnpg(nil, _pkg_id, _active_bound_slugs), do: :ok

  defp maybe_detach_orphan_dashboard_instance_cnpg(route_slug, pkg_id, active_bound_slugs) do
    if MapSet.member?(active_bound_slugs, route_slug) do
      :ok
    else
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == ^route_slug and dashboard_package_id == ^pkg_id)
      |> Ash.read_one(actor: @reconciler_actor)
      |> case do
        {:ok, %DashboardInstance{managed: true} = inst} ->
          inst
          |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
            actor: @reconciler_actor
          )
          |> Ash.update(actor: @reconciler_actor)
          |> case do
            {:ok, _} -> :ok
            {:error, err} -> {:error, err}
          end

        _ ->
          :ok
      end
    end
  end

  defp maybe_destroy_orphan_dashboard_instance_cnpg(nil, _pkg_id, _active_bound_slugs), do: :ok

  defp maybe_destroy_orphan_dashboard_instance_cnpg(route_slug, pkg_id, active_bound_slugs) do
    if MapSet.member?(active_bound_slugs, route_slug) do
      :ok
    else
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == ^route_slug and dashboard_package_id == ^pkg_id)
      |> Ash.read_one(actor: @reconciler_actor)
      |> case do
        {:ok, %DashboardInstance{managed: true} = inst} ->
          case Ash.destroy(inst, actor: @reconciler_actor) do
            :ok -> :ok
            {:ok, _} -> :ok
            {:error, err} -> {:error, err}
          end

        _ ->
          :ok
      end
    end
  end

  defp upsert_installed_pack_cnpg(
         manifest,
         existing_pack,
         resolved_config,
         bindings,
         dp_results,
         source,
         caller_actor
       ) do
    now = DateTime.utc_now()
    resource_manifest = build_resource_manifest(manifest, dp_results)

    source_type = coerce_source_type(Map.get(source, "source_type"))

    base_attrs = %{
      slug: manifest["slug"],
      name: manifest["name"],
      pack_version: manifest["version"],
      description: manifest["description"],
      categories: manifest["categories"] || [],
      icon: manifest["icon"],
      source_type: source_type,
      catalog_repository_id: Map.get(source, "catalog_repository_id"),
      source_commit_sha: Map.get(source, "source_commit_sha"),
      source_release_tag: Map.get(source, "source_release_tag"),
      source_branch: Map.get(source, "source_branch"),
      source_pr_url: Map.get(source, "source_pr_url"),
      content_hash: Map.get(source, "content_hash"),
      config_values: resolved_config,
      resource_manifest: resource_manifest,
      manifest_snapshot: Map.delete(manifest, "files"),
      last_synced_at: now
    }

    pack_res =
      case existing_pack do
        nil ->
          create_attrs =
            base_attrs
            |> Map.put(:pack_id, manifest["id"])
            |> Map.put(:installed_at, now)

          InstalledSolutionPack
          |> Ash.Changeset.for_create(:create, create_attrs, actor: caller_actor)
          |> Ash.create(actor: @reconciler_actor)

        existing ->
          update_attrs = Map.put(base_attrs, :upgraded_at, now)

          existing
          |> Ash.Changeset.for_update(:update, update_attrs, actor: caller_actor)
          |> Ash.update(actor: @reconciler_actor)
      end

    with {:ok, pack_record} <- pack_res,
         :ok <- sync_pack_bindings_cnpg(pack_record.id, bindings) do
      {:ok, pack_record}
    end
  end

  defp build_resource_manifest(manifest, dp_results) do
    res = Map.get(manifest, "resources", %{})

    base = %{
      "checks" => Enum.map(res["checks"] || [], & &1["slug"]),
      "rules" =>
        Enum.map(res["rules"] || [], fn r ->
          %{"kind" => r["kind"], "name" => r["name"]}
        end),
      "dashboards" => Enum.map(res["dashboards"] || [], & &1["slug"])
    }

    if Map.get(manifest, "pack_format_version") == 2 do
      base
      |> Map.put(
        "vantage_pipelines",
        Enum.map(res["vantage_pipelines"] || [], fn p ->
          %{"pipeline_id" => p["pipeline_id"], "version" => p["version"]}
        end)
      )
      |> Map.put(
        "signal_schemas",
        Enum.map(res["signal_schemas"] || [], fn s ->
          %{
            "schema_id" => s["schema_id"] || s["id"],
            "version" => s["version"] || "1.0.0"
          }
        end)
      )
      |> Map.put(
        "dashboard_packages",
        Enum.map(List.wrap(dp_results), fn d ->
          %{
            "dashboard_id" => d.dashboard_id,
            "version" => d.version,
            "route_slug" => d.route_slug,
            "status" => to_string(d.status)
          }
        end)
      )
    else
      base
    end
  end

  defp sync_pack_bindings_cnpg(installed_pack_id, bindings) do
    Enum.reduce_while(bindings, :ok, fn b, :ok ->
      attrs = %{
        installed_pack_id: installed_pack_id,
        slot: b.slot,
        credential_secret_id: b.credential_secret_id,
        credential_rule_id: b.credential_rule_id
      }

      case InstalledSolutionPackCredentialBinding.upsert_binding(attrs, actor: @reconciler_actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  ## Uninstall / Detach (CNPG + In-Memory Store)

  defp uninstall_in_cnpg(existing_pack, opts) do
    mode = Keyword.get(opts, :mode, :delete)
    pack_id = existing_pack.pack_id

    tx_fun = fn ->
      with {:ok, protected_pkg_ids} <- uninstall_dashboard_instances_cnpg(pack_id, mode),
           :ok <- uninstall_dashboard_packages_cnpg(pack_id, protected_pkg_ids, mode, opts),
           :ok <- uninstall_vantage_pipelines_cnpg(pack_id, mode),
           :ok <- uninstall_checks_cnpg(pack_id, mode),
           :ok <- uninstall_rules_cnpg(pack_id, mode),
           :ok <- uninstall_authored_dashboards_cnpg(pack_id, mode),
           :ok <- destroy_installed_pack_cnpg(existing_pack) do
        {:ok, %{pack_id: pack_id, slug: existing_pack.slug, mode: mode}}
      end
    end

    if is_pid(Process.whereis(Repo)) do
      Ash.transact(@transaction_resources, fn ->
        case tx_fun.() do
          {:ok, res} -> res
          {:error, err} -> {:error, err}
        end
      end)
    else
      tx_fun.()
    end
  end

  defp uninstall_dashboard_instances_cnpg(pack_id, mode) do
    instances =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(pack_id == ^pack_id)
      |> Ash.read!(actor: @reconciler_actor)

    Enum.reduce_while(instances, {:ok, MapSet.new()}, fn inst, {:ok, protected} ->
      if inst.managed == true do
        res =
          if mode == :detach do
            inst
            |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
              actor: @reconciler_actor
            )
            |> Ash.update(actor: @reconciler_actor)
            |> case do
              {:ok, _} -> {:ok, MapSet.put(protected, inst.dashboard_package_id)}
              {:error, err} -> {:error, err}
            end
          else
            case Ash.destroy(inst, actor: @reconciler_actor) do
              :ok -> {:ok, protected}
              {:ok, _} -> {:ok, protected}
              {:error, err} -> {:error, err}
            end
          end

        case res do
          {:ok, next_protected} -> {:cont, {:ok, next_protected}}
          {:error, err} -> {:halt, {:error, err}}
        end
      else
        {:cont, {:ok, MapSet.put(protected, inst.dashboard_package_id)}}
      end
    end)
  end

  defp uninstall_dashboard_packages_cnpg(pack_id, protected_pkg_ids, mode, opts) do
    packages =
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(pack_id == ^pack_id)
      |> Ash.read!(actor: @reconciler_actor)

    Enum.reduce_while(packages, :ok, fn pkg, :ok ->
      cond do
        pkg.managed != true ->
          {:cont, :ok}

        mode == :detach or MapSet.member?(protected_pkg_ids, pkg.id) or
            dashboard_package_referenced_by_instance_cnpg?(pkg.id) ->
          pkg
          |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
            actor: @reconciler_actor
          )
          |> Ash.update(actor: @reconciler_actor)
          |> case do
            {:ok, _} -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, err}}
          end

        true ->
          blob_key = pkg.wasm_object_key

          case Ash.destroy(pkg, actor: @reconciler_actor) do
            res when res == :ok or elem(res, 0) == :ok ->
              case maybe_delete_unreferenced_blob_cnpg(blob_key, opts) do
                :ok -> {:cont, :ok}
                {:error, err} -> {:halt, {:error, err}}
              end

            {:error, err} ->
              {:halt, {:error, err}}
          end
      end
    end)
  end

  defp uninstall_vantage_pipelines_cnpg(pack_id, mode) do
    pipelines =
      VantagePipeline
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(pack_id == ^pack_id)
      |> Ash.read!(actor: @reconciler_actor)

    Enum.reduce_while(pipelines, :ok, fn vp, :ok ->
      if vp.managed == true do
        res =
          if mode == :detach do
            vp
            |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
              actor: @reconciler_actor
            )
            |> Ash.update(actor: @reconciler_actor)
            |> case do
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          else
            case Ash.destroy(vp, actor: @reconciler_actor) do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          end

        case res do
          :ok -> {:cont, :ok}
          {:error, err} -> {:halt, {:error, err}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp uninstall_checks_cnpg(pack_id, mode) do
    checks =
      DeclarativeCheck
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(pack_id == ^pack_id)
      |> Ash.read!(actor: @reconciler_actor)

    Enum.reduce_while(checks, :ok, fn chk, :ok ->
      if chk.managed == true do
        res =
          if mode == :detach do
            chk
            |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
              actor: @reconciler_actor,
              context: %{reconcile_managed: true}
            )
            |> Ash.update(actor: @reconciler_actor)
            |> case do
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          else
            case Ash.destroy(chk, actor: @reconciler_actor) do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          end

        case res do
          :ok -> {:cont, :ok}
          {:error, err} -> {:halt, {:error, err}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp uninstall_rules_cnpg(pack_id, mode) do
    Enum.reduce_while([StatefulAlertRule, EventRule, ZenRule], :ok, fn mod, :ok ->
      rows =
        mod
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(pack_id == ^pack_id)
        |> Ash.read!(actor: @reconciler_actor)

      rows
      |> Enum.reduce_while(:ok, fn rule, :ok ->
        if rule.managed == true do
          res =
            if mode == :detach do
              rule
              |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
                actor: @reconciler_actor
              )
              |> Ash.update(actor: @reconciler_actor)
              |> case do
                {:ok, _} -> :ok
                {:error, err} -> {:error, err}
              end
            else
              case Ash.destroy(rule, actor: @reconciler_actor) do
                :ok -> :ok
                {:ok, _} -> :ok
                {:error, err} -> {:error, err}
              end
            end

          case res do
            :ok -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, err}}
          end
        else
          {:cont, :ok}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp uninstall_authored_dashboards_cnpg(pack_id, mode) do
    rows =
      AuthoredDashboard
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(pack_id == ^pack_id)
      |> Ash.read!(actor: @reconciler_actor)

    Enum.reduce_while(rows, :ok, fn dash, :ok ->
      if dash.managed == true do
        res =
          if mode == :detach do
            dash
            |> Ash.Changeset.for_update(:update, %{managed: false, pack_id: nil},
              actor: @reconciler_actor
            )
            |> Ash.update(actor: @reconciler_actor)
            |> case do
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          else
            case Ash.destroy(dash, actor: @reconciler_actor) do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, err} -> {:error, err}
            end
          end

        case res do
          :ok -> {:cont, :ok}
          {:error, err} -> {:halt, {:error, err}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp destroy_installed_pack_cnpg(existing_pack) do
    with {:ok, bindings} <-
           InstalledSolutionPackCredentialBinding.list_by_pack(
             existing_pack.id,
             actor: @reconciler_actor
           ),
         :ok <- destroy_records(bindings) do
      case Ash.destroy(existing_pack, actor: @reconciler_actor) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, err} -> {:error, err}
      end
    end
  end

  defp destroy_records(records) do
    Enum.reduce_while(records, :ok, fn rec, :ok ->
      case Ash.destroy(rec, actor: @reconciler_actor) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp uninstall_in_memory(existing_pack, store, opts) do
    mode = Keyword.get(opts, :mode, :delete)
    pack_id = field_val(existing_pack, :pack_id)
    slug = field_val(existing_pack, :slug)

    deleted_keys =
      Agent.get_and_update(store, fn state ->
        {next_state, keys_to_delete} = do_uninstall_mem(state, pack_id, mode)
        {keys_to_delete, next_state}
      end)

    deleted_keys
    |> Enum.reduce_while(:ok, fn blob_key, :ok ->
      case dashboard_blob_store_delete(blob_key, opts) do
        :ok -> {:cont, :ok}
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      :ok -> {:ok, %{pack_id: pack_id, slug: slug, mode: mode}}
      {:error, err} -> {:error, err}
    end
  end

  defp do_uninstall_mem(state, pack_id, mode) do
    {instances, protected_pkg_ids} =
      Enum.reduce(Map.get(state, :dashboard_instances, %{}), {%{}, MapSet.new()}, fn {k, inst},
                                                                                     {acc, prot} ->
        if field_val(inst, :pack_id) == pack_id do
          if field_val(inst, :managed) == true do
            if mode == :detach do
              updated =
                inst |> Map.put(:managed, false) |> Map.put(:pack_id, nil)

              {Map.put(acc, k, updated), MapSet.put(prot, field_val(inst, :dashboard_package_id))}
            else
              {acc, prot}
            end
          else
            {Map.put(acc, k, inst), MapSet.put(prot, field_val(inst, :dashboard_package_id))}
          end
        else
          {Map.put(acc, k, inst), prot}
        end
      end)

    {dash_pkgs, keys_to_delete, blobs_map} =
      Enum.reduce(
        Map.get(state, :dashboard_packages, %{}),
        {%{}, [], Map.get(state, :dashboard_blobs, %{})},
        fn {k, pkg}, {acc, del_keys, b_acc} ->
          if field_val(pkg, :pack_id) == pack_id and field_val(pkg, :managed) == true do
            pkg_id = field_val(pkg, :id)

            referenced? =
              MapSet.member?(protected_pkg_ids, pkg_id) or
                Enum.any?(instances, fn {_, i} ->
                  field_val(i, :dashboard_package_id) == pkg_id
                end)

            if mode == :detach or referenced? do
              {Map.put(acc, k, pkg |> Map.put(:managed, false) |> Map.put(:pack_id, nil)),
               del_keys, b_acc}
            else
              obj_key = field_val(pkg, :wasm_object_key)

              next_del =
                if is_binary(obj_key) and obj_key != "", do: [obj_key | del_keys], else: del_keys

              next_blobs = if is_binary(obj_key), do: Map.delete(b_acc, obj_key), else: b_acc
              {acc, next_del, next_blobs}
            end
          else
            {Map.put(acc, k, pkg), del_keys, b_acc}
          end
        end
      )

    next_state =
      state
      |> Map.put(:dashboard_instances, instances)
      |> Map.put(:dashboard_packages, dash_pkgs)
      |> Map.put(:dashboard_blobs, blobs_map)
      |> update_in(
        [:vantage_pipelines],
        &uninstall_mem_collection(&1, pack_id, mode, :vantage_pipeline)
      )
      |> update_in([:checks], &uninstall_mem_collection(&1, pack_id, mode, :string_map))
      |> update_in([:rules], &uninstall_mem_collection(&1, pack_id, mode, :string_map))
      |> update_in([:dashboards], &uninstall_mem_collection(&1, pack_id, mode, :string_map))
      |> update_in([:packs], &Map.delete(&1 || %{}, pack_id))

    {next_state, Enum.uniq(keys_to_delete)}
  end

  defp uninstall_mem_collection(nil, _pack_id, _mode, _kind), do: %{}

  defp uninstall_mem_collection(collection, pack_id, mode, _kind) do
    Enum.reduce(collection, %{}, fn {k, item}, acc ->
      if field_val(item, :pack_id) == pack_id and field_val(item, :managed) == true do
        if mode == :detach do
          Map.put(acc, k, detach_mem_record(item))
        else
          acc
        end
      else
        Map.put(acc, k, item)
      end
    end)
  end

  defp detach_mem_record(item) when is_map(item) do
    cond do
      Map.has_key?(item, "managed") ->
        item |> Map.put("managed", false) |> Map.put("pack_id", nil)

      Map.has_key?(item, :managed) ->
        item |> Map.put(:managed, false) |> Map.put(:pack_id, nil)

      true ->
        item
    end
  end

  ## In-Memory Store Adapter (for fast hermetic unit tests)

  defp apply_plan_in_memory(
         plan,
         validated,
         existing_pack,
         resolved_config,
         bindings,
         params,
         store,
         opts
       )
       when is_pid(store) do
    manifest = validated.manifest
    source = stringify_flat_map(fetch_param(params, :source, %{}))
    now = DateTime.utc_now()

    with {:ok, dp_results, blob_ops} <-
           prepare_mem_dashboard_packages(plan.dashboard_packages, opts) do
      active_bound_slugs = active_bound_dashboard_slugs(plan.dashboard_packages)

      orphan_deleted_blobs =
        Agent.get_and_update(store, fn state ->
          {after_orphans, deleted_blobs} =
            state
            |> apply_mem_checks(plan.checks, bindings)
            |> apply_mem_rules(plan.rules)
            |> apply_mem_dashboards(plan.dashboards)
            |> apply_mem_vantage_pipelines(plan.vantage_pipelines)
            |> apply_mem_dashboard_packages(dp_results, blob_ops)
            |> apply_mem_orphans(plan.orphans, active_bound_slugs)

          next_state =
            apply_mem_installed_pack(
              after_orphans,
              manifest,
              existing_pack,
              resolved_config,
              bindings,
              dp_results,
              source,
              now
            )

          {deleted_blobs, next_state}
        end)

      if has_explicit_dashboard_blob_store?(opts) do
        Enum.each(orphan_deleted_blobs, &dashboard_blob_store_delete(&1, opts))
      end

      installed_pack = Agent.get(store, &get_in(&1, [:packs, manifest["id"]]))

      {:ok,
       Map.merge(plan, %{
         dry_run: false,
         installed_pack: installed_pack,
         applied_vantage_pipelines: plan.vantage_pipelines,
         applied_dashboard_packages: dp_results
       })}
    end
  end

  defp prepare_mem_dashboard_packages(plans, opts) do
    plans
    |> Enum.reduce_while({:ok, [], []}, fn item, {:ok, res_acc, blob_acc} ->
      pkg_item = item.package_item
      dash_manifest = pkg_item.dashboard_manifest
      existing_pkg = item.existing

      pkg_id = (existing_pkg && field_val(existing_pkg, :id)) || Ecto.UUID.generate()
      existing_key = existing_pkg && field_val(existing_pkg, :wasm_object_key)

      object_key =
        existing_key ||
          dashboard_object_key(
            %{id: pkg_id, dashboard_id: item.dashboard_id, version: item.version},
            pkg_item
          )

      import_opts = [
        wasm_object_key: object_key,
        content_hash: pkg_item.renderer_sha256,
        source_type: item.source_type,
        source_repo_url: Map.get(item.source, "source_repo_url"),
        source_ref:
          Map.get(item.source, "source_ref") || Map.get(item.source, "source_branch") ||
            Map.get(item.source, "source_release_tag"),
        source_manifest_path: pkg_item.manifest_path,
        source_commit: Map.get(item.source, "source_commit_sha"),
        source_bundle_digest: Map.get(item.source, "content_hash"),
        source_metadata:
          Map.merge(dash_manifest.source || %{}, %{
            "pack_id" => item.pack_id,
            "pack_version" => item.pack_version
          }),
        verification_status: "verified",
        pack_id: item.pack_id,
        pack_version: item.pack_version,
        managed: true,
        template_fingerprint: item.template_fingerprint,
        status: item.target_status
      ]

      blob_result =
        if item.overwrite_mode == :idempotent and is_binary(existing_key) and existing_key != "" do
          :ok
        else
          if has_explicit_dashboard_blob_store?(opts) do
            dashboard_blob_store_put(object_key, pkg_item.renderer_bytes, opts)
          else
            :ok
          end
        end

      with :ok <- blob_result,
           {:ok, attrs} <- PackageImport.attrs_from_manifest(dash_manifest, import_opts) do
        pkg_record =
          attrs
          |> Map.put(:id, pkg_id)
          |> Map.put(:status, item.target_status)

        inst_record =
          if item.bind_instance? do
            %{
              id:
                (item.existing_instance && field_val(item.existing_instance, :id)) ||
                  Ecto.UUID.generate(),
              dashboard_package_id: pkg_id,
              dashboard_package: pkg_record,
              name: pkg_record.name || pkg_record.dashboard_id,
              route_slug: item.route_slug,
              placement: :dashboard,
              enabled: true,
              visibility: :public,
              settings: item.settings || %{},
              metadata: %{"pack_id" => item.pack_id, "pack_version" => item.pack_version},
              pack_id: item.pack_id,
              pack_version: item.pack_version,
              managed: true,
              template_fingerprint: item.template_fingerprint
            }
          end

        res = %{
          dashboard_id: item.dashboard_id,
          version: item.version,
          route_slug: item.route_slug,
          status: item.target_status,
          package: pkg_record,
          instance: inst_record,
          action:
            cond do
              item.bind_instance? and item.target_status == :enabled -> :enabled
              item.target_status == :enabled -> :enabled
              item.target_status in [:disabled, :revoked] -> item.target_status
              true -> :staged
            end
        }

        {:cont, {:ok, [res | res_acc], [{object_key, pkg_item.renderer_bytes} | blob_acc]}}
      else
        {:error, err} -> {:halt, {:error, err}}
      end
    end)
    |> case do
      {:ok, res, blobs} -> {:ok, Enum.reverse(res), Enum.reverse(blobs)}
      err -> err
    end
  end

  defp apply_mem_vantage_pipelines(state, vp_plans) do
    Enum.reduce(vp_plans, state, fn item, acc ->
      case item.action do
        act when act in [:create, :update, :reset_to_upstream] ->
          put_mem(acc, :vantage_pipelines, {item.pipeline_id, item.version}, item.target)

        _ ->
          acc
      end
    end)
  end

  defp apply_mem_dashboard_packages(state, dp_results, blob_ops) do
    state =
      Enum.reduce(blob_ops, state, fn {key, bytes}, acc ->
        put_mem(acc, :dashboard_blobs, key, bytes)
      end)

    Enum.reduce(dp_results, state, fn res, acc ->
      acc = put_mem(acc, :dashboard_packages, {res.dashboard_id, res.version}, res.package)

      if res.instance do
        put_mem(acc, :dashboard_instances, res.route_slug, res.instance)
      else
        acc
      end
    end)
  end

  defp apply_mem_checks(state, check_plans, bindings) do
    Enum.reduce(check_plans, state, fn item, acc ->
      acc =
        case item.action do
          act when act in [:create, :update, :reset_to_upstream] ->
            put_mem(acc, :checks, item.slug, item.target)

          _ ->
            acc
        end

      target_check = get_in(acc, [:checks, item.slug])

      if is_map(target_check) do
        declared =
          target_check
          |> Map.get("credential_slots", [])
          |> MapSet.new(&to_string(&1["slot"] || ""))

        projected =
          bindings
          |> Enum.filter(&MapSet.member?(declared, &1.slot))
          |> Map.new(&{&1.slot, &1})

        put_mem(acc, :check_bindings, item.slug, projected)
      else
        acc
      end
    end)
  end

  defp apply_mem_rules(state, rule_plans) do
    Enum.reduce(rule_plans, state, fn item, acc ->
      case item.action do
        act when act in [:create, :update, :reset_to_upstream] ->
          put_mem(acc, :rules, {item.rule_kind, item.name}, item.target)

        _ ->
          acc
      end
    end)
  end

  defp apply_mem_dashboards(state, dash_plans) do
    Enum.reduce(dash_plans, state, fn item, acc ->
      case item.action do
        act when act in [:create, :update, :reset_to_upstream] ->
          put_mem(acc, :dashboards, item.slug, item.target)

        _ ->
          acc
      end
    end)
  end

  defp apply_mem_orphans(state, orphans, active_bound_slugs) do
    orphans
    |> Enum.reduce({state, []}, fn orphan, {acc, deleted_blobs} ->
      case {orphan.kind, orphan.action} do
        {:check, :detach_orphan} ->
          {update_mem(acc, :checks, orphan.slug, fn c -> c && Map.put(c, "managed", false) end),
           deleted_blobs}

        {:check, :delete_orphan} ->
          {update_in(acc, [:checks], &Map.delete(&1 || %{}, orphan.slug)), deleted_blobs}

        {:rule, :detach_orphan} ->
          {update_mem(acc, :rules, {orphan.rule_kind, orphan.name}, fn r ->
             r && Map.put(r, "managed", false)
           end), deleted_blobs}

        {:rule, :delete_orphan} ->
          {update_in(acc, [:rules], &Map.delete(&1 || %{}, {orphan.rule_kind, orphan.name})),
           deleted_blobs}

        {:dashboard, :detach_orphan} ->
          {update_mem(acc, :dashboards, orphan.slug, fn d ->
             d && Map.put(d, "managed", false)
           end), deleted_blobs}

        {:dashboard, :delete_orphan} ->
          {update_in(acc, [:dashboards], &Map.delete(&1 || %{}, orphan.slug)), deleted_blobs}

        {:vantage_pipeline, :detach_orphan} ->
          {update_mem(acc, :vantage_pipelines, {orphan.pipeline_id, orphan.version}, fn p ->
             p && p |> Map.put("managed", false) |> Map.put("pack_id", nil)
           end), deleted_blobs}

        {:vantage_pipeline, :delete_orphan} ->
          {update_in(
             acc,
             [:vantage_pipelines],
             &Map.delete(&1 || %{}, {orphan.pipeline_id, orphan.version})
           ), deleted_blobs}

        {:dashboard_package, :detach_orphan} ->
          {detach_mem_orphan_dashboard_package(acc, orphan, active_bound_slugs), deleted_blobs}

        {:dashboard_package, :delete_orphan} ->
          delete_mem_orphan_dashboard_package(acc, orphan, active_bound_slugs, deleted_blobs)
      end
    end)
    |> then(fn {next_state, deleted_blobs} -> {next_state, Enum.uniq(deleted_blobs)} end)
  end

  defp detach_mem_orphan_dashboard_package(acc, orphan, active_bound_slugs) do
    pkg_key = {orphan.dashboard_id, orphan.version}

    case get_in(acc, [:dashboard_packages, pkg_key]) do
      nil ->
        acc

      old_pkg ->
        old_pkg_id = field_val(old_pkg, :id)

        acc
        |> maybe_detach_mem_orphan_instance(orphan.route_slug, old_pkg_id, active_bound_slugs)
        |> update_mem(:dashboard_packages, pkg_key, fn p ->
          p && p |> Map.put(:managed, false) |> Map.put(:pack_id, nil)
        end)
    end
  end

  defp delete_mem_orphan_dashboard_package(acc, orphan, active_bound_slugs, deleted_blobs) do
    pkg_key = {orphan.dashboard_id, orphan.version}

    case get_in(acc, [:dashboard_packages, pkg_key]) do
      nil ->
        {acc, deleted_blobs}

      old_pkg ->
        old_pkg_id = field_val(old_pkg, :id)

        next_acc =
          maybe_delete_mem_orphan_instance(acc, orphan.route_slug, old_pkg_id, active_bound_slugs)

        referenced? =
          not is_nil(old_pkg_id) and
            Enum.any?(Map.get(next_acc, :dashboard_instances, %{}), fn {_slug, inst} ->
              field_val(inst, :dashboard_package_id) == old_pkg_id
            end)

        if referenced? do
          {update_mem(next_acc, :dashboard_packages, pkg_key, fn p ->
             p && p |> Map.put(:managed, false) |> Map.put(:pack_id, nil)
           end), deleted_blobs}
        else
          blob_key = field_val(old_pkg, :wasm_object_key)
          next_pkgs = Map.delete(Map.get(next_acc, :dashboard_packages, %{}), pkg_key)

          still_used_blob? =
            is_binary(blob_key) and blob_key != "" and
              Enum.any?(next_pkgs, fn {_k, p} ->
                field_val(p, :wasm_object_key) == blob_key
              end)

          {final_blobs_map, next_deleted} =
            if is_binary(blob_key) and blob_key != "" and not still_used_blob? do
              {Map.delete(Map.get(next_acc, :dashboard_blobs, %{}), blob_key),
               [blob_key | deleted_blobs]}
            else
              {Map.get(next_acc, :dashboard_blobs, %{}), deleted_blobs}
            end

          {next_acc
           |> Map.put(:dashboard_packages, next_pkgs)
           |> Map.put(:dashboard_blobs, final_blobs_map), next_deleted}
        end
    end
  end

  defp maybe_detach_mem_orphan_instance(acc, nil, _old_pkg_id, _active_bound_slugs), do: acc
  defp maybe_detach_mem_orphan_instance(acc, _slug, nil, _active_bound_slugs), do: acc

  defp maybe_detach_mem_orphan_instance(acc, route_slug, old_pkg_id, active_bound_slugs) do
    if MapSet.member?(active_bound_slugs, route_slug) do
      acc
    else
      update_mem(acc, :dashboard_instances, route_slug, fn inst ->
        if inst && field_val(inst, :dashboard_package_id) == old_pkg_id &&
             field_val(inst, :managed) == true do
          inst |> Map.put(:managed, false) |> Map.put(:pack_id, nil)
        else
          inst
        end
      end)
    end
  end

  defp maybe_delete_mem_orphan_instance(acc, nil, _old_pkg_id, _active_bound_slugs), do: acc
  defp maybe_delete_mem_orphan_instance(acc, _slug, nil, _active_bound_slugs), do: acc

  defp maybe_delete_mem_orphan_instance(acc, route_slug, old_pkg_id, active_bound_slugs) do
    if MapSet.member?(active_bound_slugs, route_slug) do
      acc
    else
      update_in(acc, [:dashboard_instances], fn insts ->
        inst = Map.get(insts || %{}, route_slug)

        if inst && field_val(inst, :dashboard_package_id) == old_pkg_id &&
             field_val(inst, :managed) == true do
          Map.delete(insts || %{}, route_slug)
        else
          insts || %{}
        end
      end)
    end
  end

  defp apply_mem_installed_pack(
         state,
         manifest,
         existing_pack,
         resolved_config,
         bindings,
         dp_results,
         source,
         now
       ) do
    resource_manifest = build_resource_manifest(manifest, dp_results)

    pack_rec = %{
      id: (existing_pack && field_val(existing_pack, :id)) || Ecto.UUID.generate(),
      pack_id: manifest["id"],
      slug: manifest["slug"],
      name: manifest["name"],
      pack_version: manifest["version"],
      source_type: coerce_source_type(Map.get(source, "source_type")),
      catalog_repository_id: Map.get(source, "catalog_repository_id"),
      source_commit_sha: Map.get(source, "source_commit_sha"),
      source_release_tag: Map.get(source, "source_release_tag"),
      config_values: resolved_config,
      resource_manifest: resource_manifest,
      credential_bindings: bindings,
      installed_at: (existing_pack && field_val(existing_pack, :installed_at)) || now,
      upgraded_at: if(existing_pack, do: now)
    }

    put_mem(state, :packs, manifest["id"], pack_rec)
  end

  defp put_mem(state, bucket, key, value) do
    Map.update(state, bucket, %{key => value}, fn existing ->
      Map.put(existing || %{}, key, value)
    end)
  end

  defp update_mem(state, bucket, key, fun) when is_function(fun, 1) do
    Map.update(state, bucket, %{}, fn existing ->
      map = existing || %{}

      case Map.fetch(map, key) do
        {:ok, current} -> Map.put(map, key, fun.(current))
        :error -> map
      end
    end)
  end

  ## Lookups

  defp load_existing_pack(pack_id, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:packs, pack_id]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          case InstalledSolutionPack.get_by_pack_id(pack_id, actor: @reconciler_actor) do
            {:ok, %InstalledSolutionPack{} = p} -> p
            _ -> nil
          end
        end
    end
  end

  defp load_existing_pack_by_id_or_slug(id_or_slug, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, fn state ->
          packs = Map.get(state, :packs, %{})

          Map.get(packs, id_or_slug) ||
            Enum.find_value(packs, fn {_k, p} ->
              if field_val(p, :slug) == id_or_slug, do: p
            end)
        end)

      _ ->
        if is_pid(Process.whereis(Repo)) do
          case InstalledSolutionPack.get_by_pack_id(id_or_slug, actor: @reconciler_actor) do
            {:ok, %InstalledSolutionPack{} = p} ->
              p

            _ ->
              case InstalledSolutionPack.get_by_slug(id_or_slug, actor: @reconciler_actor) do
                {:ok, %InstalledSolutionPack{} = p} -> p
                _ -> nil
              end
          end
        end
    end
  end

  defp lookup_existing_vantage_pipeline(pipeline_id, version, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:vantage_pipelines, {pipeline_id, version}]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          case VantagePipeline.get_by_pipeline_version(pipeline_id, version,
                 actor: @reconciler_actor
               ) do
            {:ok, %VantagePipeline{} = vp} -> vp
            _ -> nil
          end
        end
    end
  end

  defp lookup_existing_dashboard_package(dashboard_id, version, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:dashboard_packages, {dashboard_id, version}]))

      _ ->
        lookup_existing_dashboard_package_cnpg(dashboard_id, version)
    end
  end

  defp lookup_existing_dashboard_package_cnpg(dashboard_id, version) do
    if is_pid(Process.whereis(Repo)) do
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(dashboard_id == ^dashboard_id and version == ^version)
      |> Ash.read_one(actor: @reconciler_actor)
      |> case do
        {:ok, %DashboardPackage{} = pkg} -> pkg
        _ -> nil
      end
    end
  end

  defp lookup_existing_dashboard_instance(route_slug, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:dashboard_instances, route_slug]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          DashboardInstance
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(route_slug == ^route_slug)
          |> Ash.Query.load(:dashboard_package)
          |> Ash.read_one(actor: @reconciler_actor)
          |> case do
            {:ok, %DashboardInstance{} = inst} -> inst
            _ -> nil
          end
        end
    end
  end

  defp dashboard_package_referenced_by_instance_cnpg?(package_id) do
    if is_pid(Process.whereis(Repo)) do
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(dashboard_package_id == ^package_id)
      |> Ash.Query.limit(1)
      |> Ash.read(actor: @reconciler_actor)
      |> case do
        {:ok, [_ | _]} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp maybe_delete_unreferenced_blob_cnpg(nil, _opts), do: :ok
  defp maybe_delete_unreferenced_blob_cnpg("", _opts), do: :ok

  defp maybe_delete_unreferenced_blob_cnpg(blob_key, opts) do
    still_used? =
      if is_pid(Process.whereis(Repo)) do
        DashboardPackage
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(wasm_object_key == ^blob_key)
        |> Ash.Query.limit(1)
        |> Ash.read(actor: @reconciler_actor)
        |> case do
          {:ok, [_ | _]} -> true
          _ -> false
        end
      else
        false
      end

    if still_used? do
      :ok
    else
      if has_explicit_dashboard_blob_store?(opts) do
        dashboard_blob_store_delete(blob_key, opts)
      else
        :ok
      end
    end
  end

  defp lookup_existing_check(slug, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:checks, slug]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          case DeclarativeCheck.get_by_slug(slug, actor: @reconciler_actor) do
            {:ok, %DeclarativeCheck{} = c} -> c
            _ -> nil
          end
        end
    end
  end

  defp lookup_existing_rule(kind, name, subject, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:rules, {kind, name}]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          lookup_existing_rule_cnpg(kind, name, subject)
        end
    end
  end

  defp lookup_existing_rule_cnpg("stateful_alert_rule", name, _subject) do
    StatefulAlertRule
    |> Ash.Query.for_read(:read, %{}, actor: @reconciler_actor)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @reconciler_actor)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp lookup_existing_rule_cnpg("event_rule", name, _subject) do
    EventRule
    |> Ash.Query.for_read(:read, %{}, actor: @reconciler_actor)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @reconciler_actor)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp lookup_existing_rule_cnpg("zen_rule", name, subject) do
    query =
      ZenRule
      |> Ash.Query.for_read(:read, %{}, actor: @reconciler_actor)
      |> Ash.Query.filter(name == ^name)

    query = if is_binary(subject), do: Ash.Query.filter(query, subject == ^subject), else: query

    query
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @reconciler_actor)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp lookup_existing_dashboard(slug, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        Agent.get(store, &get_in(&1, [:dashboards, slug]))

      _ ->
        if is_pid(Process.whereis(Repo)) do
          case AuthoredDashboard.get_by_slug(slug, actor: @reconciler_actor) do
            {:ok, %AuthoredDashboard{} = dash} ->
              panels =
                case DashboardPanel.list_for_dashboard(dash.id, actor: @reconciler_actor) do
                  {:ok, list} -> list
                  _ -> []
                end

              Map.put(dash, :panels, panels)

            _ ->
              nil
          end
        end
    end
  end

  ## Helpers & Validation

  defp ensure_validated_pack(
         %{manifest: %{}, files: %{}, checks: _, rules: _, dashboards: _} = v,
         _opts
       ), do: {:ok, v}

  defp ensure_validated_pack(file_map, opts), do: PackManifest.validate_pack_tree(file_map, opts)

  defp authorize_reconcile(opts, true) do
    authorize_any(opts, ["catalog.view", "catalog.packs.install", "catalog.gitops.sync"])
  end

  defp authorize_reconcile(opts, false) do
    authorize_any(opts, ["catalog.packs.install", "catalog.gitops.sync"])
  end

  defp authorize_any(opts, perms) do
    case extract_actor(opts) do
      nil ->
        {:error, Forbidden.exception([])}

      %{role: :system} ->
        :ok

      actor ->
        if Enum.any?(perms, &ActorHasPermission.match?(actor, [permission: &1], %{})) do
          :ok
        else
          {:error, Forbidden.exception([])}
        end
    end
  end

  defp authorize_dashboard_activation(validated, params, dry_run?, opts) do
    has_bundled_dashboards? = Map.get(validated, :dashboard_packages, []) != []
    activate_requested? = activate_dashboard_packages_requested?(params, opts)

    cond do
      dry_run? ->
        :ok

      not has_bundled_dashboards? ->
        :ok

      not activate_requested? ->
        :ok

      has_dashboard_activation_permission?(opts) ->
        :ok

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp activate_dashboard_packages_requested?(params, opts) do
    opt_val = Keyword.get(opts, :activate_dashboard_packages)
    param_val = fetch_param(params, :activate_dashboard_packages, nil)
    truthy?(opt_val) or truthy?(param_val)
  end

  defp has_dashboard_activation_permission?(opts) do
    case extract_actor(opts) do
      nil ->
        false

      %{role: :system} ->
        true

      actor ->
        ActorHasPermission.match?(actor, [permission: "dashboards.packages.manage"], %{}) or
          ((ActorHasPermission.match?(actor, [permission: "dashboards.packages.publish"], %{}) or
              ActorHasPermission.match?(actor, [permission: "cli.dashboard.publish"], %{})) and
             (ActorHasPermission.match?(actor, [permission: "dashboards.packages.enable"], %{}) or
                ActorHasPermission.match?(actor, [permission: "cli.dashboard.enable"], %{})))
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp normalize_pkg_status(s) when s in [:staged, "staged"], do: :staged
  defp normalize_pkg_status(s) when s in [:enabled, "enabled"], do: :enabled
  defp normalize_pkg_status(s) when s in [:disabled, "disabled"], do: :disabled
  defp normalize_pkg_status(s) when s in [:revoked, "revoked"], do: :revoked
  defp normalize_pkg_status(_), do: :staged

  defp dashboard_object_key(pkg, pkg_item) do
    dash_id = sanitize_segment(field_val(pkg, :dashboard_id) || "unknown")
    ver = sanitize_segment(field_val(pkg, :version) || "unknown")
    id = field_val(pkg, :id) || Ecto.UUID.generate()
    ext = renderer_ext(pkg_item)
    "dashboards/#{dash_id}/#{ver}/#{id}#{ext}"
  end

  defp renderer_ext(pkg_item) do
    case Path.extname(pkg_item.renderer_path || "") do
      "" -> ".js"
      ext -> ext
    end
  end

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp resolved_dashboard_blob_store(opts) do
    Keyword.get(opts, :dashboard_blob_store) ||
      Application.get_env(:serviceradar_core, :catalog_dashboard_blob_store)
  end

  defp has_explicit_dashboard_blob_store?(opts) do
    not is_nil(resolved_dashboard_blob_store(opts))
  end

  defp dashboard_blob_store_put(object_key, bytes, opts) do
    case resolved_dashboard_blob_store(opts) do
      %{put: put_fun} when is_function(put_fun, 2) ->
        put_fun.(object_key, bytes)

      mod when is_atom(mod) and not is_nil(mod) ->
        mod.put_blob(object_key, bytes)

      _ ->
        {:error, :dashboard_blob_store_unavailable}
    end
  end

  defp dashboard_blob_store_delete(object_key, opts) do
    case resolved_dashboard_blob_store(opts) do
      %{delete: del_fun} when is_function(del_fun, 1) ->
        del_fun.(object_key)

      %{put: _} ->
        :ok

      mod when is_atom(mod) and not is_nil(mod) ->
        mod.delete_blob(object_key)

      _ ->
        :ok
    end
  end

  defp enforce_dependencies(%{ready?: true}, _dry_run?, _opts), do: :ok
  defp enforce_dependencies(_dep_report, true, _opts), do: :ok

  defp enforce_dependencies(dep_report, false, opts) do
    if Keyword.get(opts, :install_paused, false) == true do
      :ok
    else
      unsatisfied_plugins =
        dep_report
        |> Map.get(:dependencies, [])
        |> Enum.filter(fn d -> d.required and d.status != :satisfied end)

      blocking_workers =
        dep_report
        |> Map.get(:worker_dependencies, [])
        |> Enum.filter(fn d -> d.blocking? end)

      blocking_dashboards =
        dep_report
        |> Map.get(:dashboard_package_dependencies, [])
        |> Enum.filter(fn d -> d.required and d.status != :satisfied end)

      cond do
        unsatisfied_plugins != [] and blocking_workers == [] and blocking_dashboards == [] ->
          {:error, {:unsatisfied_plugin_dependencies, unsatisfied_plugins}}

        blocking_workers != [] and unsatisfied_plugins == [] and blocking_dashboards == [] ->
          {:error, {:unsatisfied_worker_dependencies, blocking_workers}}

        blocking_dashboards != [] and unsatisfied_plugins == [] and blocking_workers == [] ->
          {:error, {:unsatisfied_dashboard_package_dependencies, blocking_dashboards}}

        true ->
          {:error,
           {:unsatisfied_dependencies,
            %{
              plugins: unsatisfied_plugins,
              workers: blocking_workers,
              dashboard_packages: blocking_dashboards
            }}}
      end
    end
  end

  defp merge_config_inputs(existing_pack, params) do
    prev =
      case existing_pack do
        nil -> %{}
        p -> stringify_flat_map(field_val(p, :config_values) || %{})
      end

    supplied = stringify_flat_map(fetch_param(params, :config, %{}))
    Map.merge(prev, supplied)
  end

  defp compute_config_overrides(defaults, resolved) do
    resolved
    |> Enum.reject(fn {k, v} -> Map.get(defaults, k) == v end)
    |> Map.new()
  end

  defp normalize_and_validate_bindings(declared_slots, existing_pack, params, dry_run?, opts) do
    declared_by_slot = Map.new(declared_slots, &{&1["slot"], &1})
    existing_bindings = load_existing_pack_bindings(existing_pack, opts)
    supplied_bindings = coerce_binding_input(fetch_param(params, :credential_bindings, nil))

    merged_map =
      existing_bindings
      |> Map.new(&{&1.slot, &1})
      |> Map.merge(Map.new(supplied_bindings, &{&1.slot, &1}))
      |> Enum.filter(fn {slot, _} -> Map.has_key?(declared_by_slot, slot) end)
      |> Map.new()

    xor_err =
      Enum.find_value(merged_map, fn {slot, b} ->
        cond do
          not is_nil(b.credential_secret_id) and not is_nil(b.credential_rule_id) ->
            {:invalid_credential_binding, slot,
             "cannot bind both credential_secret_id and credential_rule_id"}

          is_nil(b.credential_secret_id) and is_nil(b.credential_rule_id) ->
            {:invalid_credential_binding, slot,
             "must bind either credential_secret_id or credential_rule_id"}

          true ->
            nil
        end
      end)

    missing_required =
      declared_slots
      |> Enum.filter(fn s ->
        Map.get(s, "required", true) != false and not Map.has_key?(merged_map, s["slot"])
      end)
      |> Enum.map(& &1["slot"])

    cond do
      not is_nil(xor_err) ->
        {:error, xor_err}

      missing_required != [] and not dry_run? and
          Keyword.get(opts, :install_paused, false) != true ->
        {:error, {:missing_required_credential_slots, missing_required}}

      true ->
        sorted =
          merged_map
          |> Map.values()
          |> Enum.sort_by(& &1.slot)

        {:ok, sorted}
    end
  end

  defp load_existing_pack_bindings(nil, _opts), do: []

  defp load_existing_pack_bindings(existing_pack, opts) do
    case Keyword.get(opts, :state_store) do
      store when is_pid(store) ->
        _ = store
        List.wrap(field_val(existing_pack, :credential_bindings))

      _ ->
        if is_pid(Process.whereis(Repo)) and not is_nil(field_val(existing_pack, :id)) do
          case InstalledSolutionPackCredentialBinding.list_by_pack(
                 field_val(existing_pack, :id),
                 actor: @reconciler_actor
               ) do
            {:ok, rows} ->
              Enum.map(rows, fn r ->
                %{
                  slot: r.slot,
                  credential_secret_id: r.credential_secret_id,
                  credential_rule_id: r.credential_rule_id
                }
              end)

            _ ->
              []
          end
        else
          []
        end
    end
  end

  defp coerce_binding_input(nil), do: []

  defp coerce_binding_input(list) when is_list(list) do
    Enum.map(list, fn raw ->
      %{
        slot: to_string(field_val(raw, :slot) || ""),
        credential_secret_id: field_val(raw, :credential_secret_id),
        credential_rule_id: field_val(raw, :credential_rule_id)
      }
    end)
  end

  defp coerce_binding_input(map) when is_map(map) do
    Enum.map(map, fn {slot, target} ->
      %{
        slot: to_string(slot),
        credential_secret_id: field_val(target, :credential_secret_id),
        credential_rule_id: field_val(target, :credential_rule_id)
      }
    end)
  end

  defp check_doc_to_ash_attrs(doc, include_slug?) do
    base = %{
      name: doc["name"],
      description: doc["description"],
      state: String.to_existing_atom(to_string(doc["state"] || "enabled")),
      schedule: doc["schedule"] || %{},
      target_binding: doc["target_binding"] || %{},
      inputs: doc["inputs"] || [],
      credential_slots: doc["credential_slots"] || [],
      nodes: doc["nodes"] || [],
      edges: doc["edges"] || [],
      alert_policy: doc["alert_policy"] || %{},
      ui_layout: doc["ui_layout"],
      pack_id: doc["pack_id"],
      pack_version: doc["pack_version"],
      managed: doc["managed"] == true,
      parameter_overrides: doc["parameter_overrides"] || %{}
    }

    # The update action accepts neither: a check keeps its slug and schema version.
    if include_slug?,
      do: Map.merge(base, %{schema_version: 1, slug: doc["slug"]}),
      else: base
  end

  defp normalize_decisions(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), coerce_decision(v)} end)
  end

  defp normalize_decisions(_), do: %{}

  defp coerce_decision(d) when d in [:reset_to_upstream, "reset_to_upstream"],
    do: :reset_to_upstream

  defp coerce_decision(d) when d in [:delete, "delete"], do: :delete
  defp coerce_decision(_), do: :keep_customized

  defp coerce_source_type(s) when s in [:builtin, "builtin"], do: :builtin
  defp coerce_source_type(s) when s in [:release_catalog, "release_catalog"], do: :release_catalog
  defp coerce_source_type(s) when s in [:gitops_tree, "gitops_tree"], do: :gitops_tree
  defp coerce_source_type(s) when s in [:upload, "upload"], do: :upload
  defp coerce_source_type(_), do: :builtin

  defp maybe_put_map(acc, _key, empty) when empty == %{}, do: acc
  defp maybe_put_map(acc, key, map), do: Map.put(acc, key, map)

  defp maybe_put_paused_override(acc, "paused"), do: Map.put(acc, "enabled", false)
  defp maybe_put_paused_override(acc, _), do: acc

  defp maybe_merge_nested_config(existing_overrides, empty) when empty == %{},
    do: existing_overrides

  defp maybe_merge_nested_config(existing_overrides, config_overrides) do
    prev_cfg = Map.get(existing_overrides, "config") || %{}
    Map.put(existing_overrides, "config", Map.merge(prev_cfg, config_overrides))
  end

  defp extract_actor(opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        case Keyword.get(opts, :scope) do
          %{user: user, permissions: %MapSet{} = perms} when is_map(user) ->
            Map.put(user, :permissions, perms)

          %{actor: actor, permissions: %MapSet{} = perms} when is_map(actor) ->
            Map.put(actor, :permissions, perms)

          %{user: user} when not is_nil(user) ->
            user

          %{actor: actor} when not is_nil(actor) ->
            actor

          _ ->
            nil
        end

      actor ->
        actor
    end
  end

  defp fetch_param(map, atom_key, default) do
    str_key = Atom.to_string(atom_key)

    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      true -> default
    end
  end

  defp field_val(map, atom_key) when is_map(map) do
    str_key = Atom.to_string(atom_key)

    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      true -> nil
    end
  end

  defp stringify_flat_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp to_plain_string_map(%{__struct__: _} = s) do
    s
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__lateral_join_source__, :calculations, :aggregates])
    |> to_plain_string_map()
  end

  defp to_plain_string_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_plain_val(v)} end)
  end

  defp normalize_plain_val(%{__struct__: _} = s), do: to_plain_string_map(s)
  defp normalize_plain_val(m) when is_map(m), do: to_plain_string_map(m)
  defp normalize_plain_val(l) when is_list(l), do: Enum.map(l, &normalize_plain_val/1)

  defp normalize_plain_val(a) when is_atom(a) and not is_boolean(a) and not is_nil(a),
    do: Atom.to_string(a)

  defp normalize_plain_val(other), do: other
end
