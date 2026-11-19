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
  alias ServiceRadar.Catalog.DependencyChecker
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel
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

  @stateful_rule_structural_fields ~w(signal match group_by event alert)
  @event_rule_structural_fields ~w(source_type source match event)
  @zen_rule_structural_fields ~w(stream_name subject format template builder_config jdm_definition)

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
           ) do
      orphan_plans =
        plan_orphans(existing_pack, check_plans, rule_plans, dashboard_plans, decisions)

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
         orphans: orphan_plans,
         has_diverged?:
           Enum.any?(check_plans ++ rule_plans ++ dashboard_plans, &(&1.diverged? == true))
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

  defp plan_orphans(nil, _checks, _rules, _dashboards, _decisions), do: []

  defp plan_orphans(existing_pack, check_plans, rule_plans, dashboard_plans, decisions) do
    prev = field_val(existing_pack, :resource_manifest) || %{}
    next_checks = MapSet.new(check_plans, & &1.slug)
    next_rules = MapSet.new(rule_plans, &{&1.rule_kind, &1.name})
    next_dashboards = MapSet.new(dashboard_plans, & &1.slug)

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

    orphan_checks ++ orphan_rules ++ orphan_dashboards
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
          store
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
           :ok <- apply_orphans_cnpg(plan.orphans),
           {:ok, installed_pack} <-
             upsert_installed_pack_cnpg(
               validated.manifest,
               existing_pack,
               resolved_config,
               bindings,
               source,
               caller_actor
             ) do
        {:ok,
         Map.merge(plan, %{
           dry_run: false,
           installed_pack: installed_pack,
           applied_checks: check_results,
           applied_rules: rule_results,
           applied_dashboards: dash_results
         })}
      end
    end

    if is_pid(Process.whereis(Repo)) do
      case Repo.transaction(fn ->
             case tx_fun.() do
               {:ok, res} -> res
               {:error, err} -> Repo.rollback(err)
             end
           end) do
        {:ok, res} -> {:ok, res}
        {:error, err} -> {:error, err}
      end
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

  defp apply_orphans_cnpg(orphans) do
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
          {:error, err} -> {:error, err}
        end

      _ ->
        :ok
    end
  end

  defp upsert_installed_pack_cnpg(
         manifest,
         existing_pack,
         resolved_config,
         bindings,
         source,
         caller_actor
       ) do
    now = DateTime.utc_now()

    resource_manifest = %{
      "checks" => Enum.map(manifest["resources"]["checks"] || [], & &1["slug"]),
      "rules" =>
        Enum.map(manifest["resources"]["rules"] || [], fn r ->
          %{"kind" => r["kind"], "name" => r["name"]}
        end),
      "dashboards" => Enum.map(manifest["resources"]["dashboards"] || [], & &1["slug"])
    }

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

  ## In-Memory Store Adapter (for fast hermetic unit tests)

  defp apply_plan_in_memory(
         plan,
         validated,
         existing_pack,
         resolved_config,
         bindings,
         params,
         store
       )
       when is_pid(store) do
    manifest = validated.manifest
    source = stringify_flat_map(fetch_param(params, :source, %{}))
    now = DateTime.utc_now()

    Agent.update(store, fn state ->
      state
      |> apply_mem_checks(plan.checks, bindings)
      |> apply_mem_rules(plan.rules)
      |> apply_mem_dashboards(plan.dashboards)
      |> apply_mem_orphans(plan.orphans)
      |> apply_mem_installed_pack(manifest, existing_pack, resolved_config, bindings, source, now)
    end)

    installed_pack = Agent.get(store, &get_in(&1, [:packs, manifest["id"]]))

    {:ok,
     Map.merge(plan, %{
       dry_run: false,
       installed_pack: installed_pack
     })}
  end

  defp apply_mem_checks(state, check_plans, bindings) do
    Enum.reduce(check_plans, state, fn item, acc ->
      acc =
        case item.action do
          act when act in [:create, :update, :reset_to_upstream] ->
            put_in(acc, [:checks, item.slug], item.target)

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

        put_in(acc, [:check_bindings, item.slug], projected)
      else
        acc
      end
    end)
  end

  defp apply_mem_rules(state, rule_plans) do
    Enum.reduce(rule_plans, state, fn item, acc ->
      case item.action do
        act when act in [:create, :update, :reset_to_upstream] ->
          put_in(acc, [:rules, {item.rule_kind, item.name}], item.target)

        _ ->
          acc
      end
    end)
  end

  defp apply_mem_dashboards(state, dash_plans) do
    Enum.reduce(dash_plans, state, fn item, acc ->
      case item.action do
        act when act in [:create, :update, :reset_to_upstream] ->
          put_in(acc, [:dashboards, item.slug], item.target)

        _ ->
          acc
      end
    end)
  end

  defp apply_mem_orphans(state, orphans) do
    Enum.reduce(orphans, state, fn orphan, acc ->
      case {orphan.kind, orphan.action} do
        {:check, :detach_orphan} ->
          update_in(acc, [:checks, orphan.slug], fn c -> c && Map.put(c, "managed", false) end)

        {:check, :delete_orphan} ->
          update_in(acc, [:checks], &Map.delete(&1 || %{}, orphan.slug))

        {:rule, :detach_orphan} ->
          update_in(acc, [:rules, {orphan.rule_kind, orphan.name}], fn r ->
            r && Map.put(r, "managed", false)
          end)

        {:rule, :delete_orphan} ->
          update_in(acc, [:rules], &Map.delete(&1 || %{}, {orphan.rule_kind, orphan.name}))

        {:dashboard, :detach_orphan} ->
          update_in(acc, [:dashboards, orphan.slug], fn d ->
            d && Map.put(d, "managed", false)
          end)

        {:dashboard, :delete_orphan} ->
          update_in(acc, [:dashboards], &Map.delete(&1 || %{}, orphan.slug))
      end
    end)
  end

  defp apply_mem_installed_pack(
         state,
         manifest,
         existing_pack,
         resolved_config,
         bindings,
         source,
         now
       ) do
    resource_manifest = %{
      "checks" => Enum.map(manifest["resources"]["checks"] || [], & &1["slug"]),
      "rules" =>
        Enum.map(manifest["resources"]["rules"] || [], fn r ->
          %{"kind" => r["kind"], "name" => r["name"]}
        end),
      "dashboards" => Enum.map(manifest["resources"]["dashboards"] || [], & &1["slug"])
    }

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

    put_in(state, [:packs, manifest["id"]], pack_rec)
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

  defp enforce_dependencies(%{ready?: true}, _dry_run?, _opts), do: :ok
  defp enforce_dependencies(_dep_report, true, _opts), do: :ok

  defp enforce_dependencies(dep_report, false, opts) do
    if Keyword.get(opts, :install_paused, false) == true do
      :ok
    else
      unsatisfied =
        Enum.filter(dep_report.dependencies, fn d ->
          d.required and d.status != :satisfied
        end)

      {:error, {:unsatisfied_plugin_dependencies, unsatisfied}}
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
      schema_version: 1,
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

    if include_slug?, do: Map.put(base, :slug, doc["slug"]), else: base
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

          %{user: user} when not is_nil(user) ->
            user

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
