defmodule ServiceRadar.DeclarativeChecks.Importer do
  @moduledoc """
  Validated REST/Solution-Pack importer for `schema_version: 1` `DeclarativeCheck`
  documents (`1.4`, `4.1`).

  Runs strict secret-free preflight checks (`SchemaValidator.validate_secret_free/1`),
  full v1 schema + acyclic DAG + port-type validation, supports `dry_run: true`,
  and reconciles `managed: true` Solution Pack upgrades while preserving operator
  `parameter_overrides`, `ui_layout`, and `state`.
  """

  alias Ash.Error.Forbidden
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @doc """
  Validates and imports (or dry-runs) a canonical `schema_version: 1` check JSON
  string or decoded map.
  """
  @spec import_document(String.t() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_document(raw_payload, opts \\ []) when is_list(opts) do
    with :ok <- authorize_manage(opts),
         {:ok, doc_map, wrapper_opts} <- decode_and_unwrap(raw_payload),
         merged_opts = Keyword.merge(wrapper_opts, opts),
         {:ok, normalized} <- SchemaValidator.validate_document(doc_map, merged_opts) do
      dry_run? = Keyword.get(merged_opts, :dry_run, false) == true

      if dry_run? do
        run_dry_import(normalized, merged_opts)
      else
        apply_import(normalized, merged_opts)
      end
    end
  end

  defp decode_and_unwrap(json_str) when is_binary(json_str) do
    case Jason.decode(json_str) do
      {:ok, decoded} when is_map(decoded) ->
        decode_and_unwrap(decoded)

      {:ok, _other} ->
        {:error,
         %{
           kind: :schema_validation,
           errors: [
             %{path: "$", code: "invalid_type", message: "root JSON value must be an object"}
           ]
         }}

      {:error, err} ->
        {:error,
         %{
           kind: :invalid_json,
           errors: [%{path: "$", code: "invalid_json", message: Exception.message(err)}]
         }}
    end
  end

  defp decode_and_unwrap(%{"document" => inner} = wrapper) when is_map(inner) do
    extra =
      []
      |> maybe_kw(:dry_run, Map.get(wrapper, "dry_run"))
      |> maybe_kw(:force_overwrite, Map.get(wrapper, "force_overwrite"))
      |> maybe_kw(
        :allow_detach,
        Map.get(wrapper, "allow_detach") || Map.get(wrapper, "confirm_detach")
      )

    {:ok, inner, extra}
  end

  defp decode_and_unwrap(map) when is_map(map), do: {:ok, map, []}

  defp decode_and_unwrap(_other) do
    {:error,
     %{
       kind: :schema_validation,
       errors: [
         %{path: "$", code: "invalid_type", message: "import payload must be a JSON object"}
       ]
     }}
  end

  defp run_dry_import(normalized, opts) do
    existing = lookup_existing(normalized["slug"], opts)
    preserved = compute_preserved_overrides(existing, normalized)

    {:ok,
     %{
       action: :dry_run,
       dry_run: true,
       check: nil,
       document: CanonicalJSON.to_canonical_export_map(normalized),
       template_fingerprint: normalized["template_fingerprint"],
       preserved_parameter_overrides: preserved,
       warnings: []
     }}
  end

  defp apply_import(normalized, opts) do
    actor = extract_actor(opts)
    slug = normalized["slug"]

    case lookup_existing(slug, opts) do
      nil ->
        attrs = normalized_to_ash_attrs(normalized)
        ctx = if Keyword.get(opts, :skip_srql_nif?, false), do: %{skip_srql_nif?: true}, else: %{}

        case DeclarativeCheck
             |> Ash.Changeset.for_create(:create, attrs, actor: actor, context: ctx)
             |> Ash.create(actor: actor) do
          {:ok, created} ->
            {:ok,
             %{
               action: :created,
               dry_run: false,
               check: created,
               document: CanonicalJSON.to_canonical_export_map(created),
               template_fingerprint: created.template_fingerprint,
               preserved_parameter_overrides: created.parameter_overrides,
               warnings: []
             }}

          {:error, err} ->
            {:error, format_ash_error(err)}
        end

      existing ->
        reconcile_existing(existing, normalized, actor, opts)
    end
  end

  defp reconcile_existing(existing, normalized, actor, opts) do
    force? = Keyword.get(opts, :force_overwrite, false) == true

    allow_detach? =
      Keyword.get(opts, :allow_detach, false) == true or
        Keyword.get(opts, :confirm_detach, false) == true

    incoming_managed? = normalized["managed"] == true

    cond do
      existing.managed and incoming_managed? ->
        reconcile_managed_upgrade(existing, normalized, actor, force?, opts)

      existing.managed and not incoming_managed? and not (force? or allow_detach?) ->
        {:error,
         %{
           kind: :managed_conflict,
           errors: [
             %{
               path: "$.managed",
               code: "managed_detach_confirmation_required",
               message:
                 "check '#{existing.slug}' is managed by pack #{inspect(existing.pack_id)}; pass allow_detach: true to overwrite"
             }
           ]
         }}

      true ->
        update_attrs =
          normalized
          |> normalized_to_ash_attrs()
          |> Map.delete(:slug)

        ctx =
          Map.merge(
            %{confirm_detach: allow_detach? or force?},
            if(Keyword.get(opts, :skip_srql_nif?, false), do: %{skip_srql_nif?: true}, else: %{})
          )

        case existing
             |> Ash.Changeset.for_update(:update, update_attrs, actor: actor, context: ctx)
             |> Ash.update(actor: actor) do
          {:ok, updated} ->
            {:ok,
             %{
               action: :updated,
               dry_run: false,
               check: updated,
               document: CanonicalJSON.to_canonical_export_map(updated),
               template_fingerprint: updated.template_fingerprint,
               preserved_parameter_overrides: updated.parameter_overrides,
               warnings: []
             }}

          {:error, err} ->
            {:error, format_ash_error(err)}
        end
    end
  end

  defp reconcile_managed_upgrade(existing, normalized, actor, force?, opts) do
    current_semantic_fp = CanonicalJSON.template_fingerprint(existing)
    diverged? = current_semantic_fp != existing.template_fingerprint
    new_fp = normalized["template_fingerprint"]

    cond do
      diverged? and not force? ->
        {:ok,
         %{
           action: :skipped_diverged,
           dry_run: false,
           check: existing,
           document: CanonicalJSON.to_canonical_export_map(existing),
           template_fingerprint: existing.template_fingerprint,
           preserved_parameter_overrides: existing.parameter_overrides,
           warnings: [
             "Managed check '#{existing.slug}' diverged from stored template_fingerprint; skipped"
           ]
         }}

      not diverged? and new_fp == existing.template_fingerprint and
          normalized["pack_version"] == existing.pack_version ->
        {:ok,
         %{
           action: :unchanged,
           dry_run: false,
           check: existing,
           document: CanonicalJSON.to_canonical_export_map(existing),
           template_fingerprint: existing.template_fingerprint,
           preserved_parameter_overrides: existing.parameter_overrides,
           warnings: []
         }}

      true ->
        kept_overrides = compute_preserved_overrides(existing, normalized)
        merged_layout = merge_ui_layout(existing.ui_layout, normalized["ui_layout"])

        update_attrs =
          normalized
          |> normalized_to_ash_attrs()
          |> Map.delete(:slug)
          |> Map.put(:parameter_overrides, kept_overrides)
          |> Map.put(:ui_layout, merged_layout)
          |> Map.put(:state, existing.state)
          |> Map.put(:managed, true)

        ctx =
          Map.merge(
            %{reconcile_managed: true},
            if(Keyword.get(opts, :skip_srql_nif?, false), do: %{skip_srql_nif?: true}, else: %{})
          )

        case existing
             |> Ash.Changeset.for_update(:update, update_attrs, actor: actor, context: ctx)
             |> Ash.update(actor: actor) do
          {:ok, updated} ->
            {:ok,
             %{
               action: :updated,
               dry_run: false,
               check: updated,
               document: CanonicalJSON.to_canonical_export_map(updated),
               template_fingerprint: updated.template_fingerprint,
               preserved_parameter_overrides: updated.parameter_overrides,
               warnings: []
             }}

          {:error, err} ->
            {:error, format_ash_error(err)}
        end
    end
  end

  defp compute_preserved_overrides(nil, normalized), do: normalized["parameter_overrides"] || %{}

  defp compute_preserved_overrides(existing, normalized) do
    valid_keys =
      normalized
      |> Map.get("inputs", [])
      |> MapSet.new(&Map.get(&1, "key"))

    existing_overrides = Map.get(existing, :parameter_overrides) || %{}

    existing_overrides
    |> Enum.filter(fn {k, _v} -> MapSet.member?(valid_keys, to_string(k)) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp merge_ui_layout(nil, new_layout), do: new_layout
  defp merge_ui_layout(existing_layout, nil), do: existing_layout

  defp merge_ui_layout(%{"nodes" => old_nodes} = old_l, %{"nodes" => new_nodes})
       when is_map(old_nodes) and is_map(new_nodes) do
    Map.put(old_l, "nodes", Map.merge(new_nodes, old_nodes))
  end

  defp merge_ui_layout(existing_layout, _new_layout), do: existing_layout

  defp lookup_existing(slug, opts) do
    case Keyword.get(opts, :existing_loader) do
      fun when is_function(fun, 1) ->
        fun.(slug)

      _ ->
        if Keyword.get(opts, :dry_run_offline?, false) do
          nil
        else
          actor = extract_actor(opts)

          case DeclarativeCheck.get_by_slug(slug, actor: actor) do
            {:ok, %DeclarativeCheck{} = row} -> row
            _ -> nil
          end
        end
    end
  rescue
    _ -> nil
  end

  defp normalized_to_ash_attrs(normalized) do
    %{
      schema_version: 1,
      slug: normalized["slug"],
      name: normalized["name"],
      description: normalized["description"],
      state: String.to_existing_atom(normalized["state"]),
      pack_id: normalized["pack_id"],
      pack_version: normalized["pack_version"],
      managed: normalized["managed"],
      parameter_overrides: normalized["parameter_overrides"],
      schedule: normalized["schedule"],
      target_binding: normalized["target_binding"],
      inputs: normalized["inputs"],
      credential_slots: normalized["credential_slots"],
      nodes: normalized["nodes"],
      edges: normalized["edges"],
      alert_policy: normalized["alert_policy"],
      ui_layout: normalized["ui_layout"]
    }
  end

  defp format_ash_error(%Forbidden{} = err), do: err

  defp format_ash_error(err) do
    %{
      kind: :schema_validation,
      errors: [%{path: "$", code: "persistence_error", message: Exception.message(err)}]
    }
  end

  defp authorize_manage(opts) do
    case extract_actor(opts) do
      nil ->
        {:error, Forbidden.exception([])}

      %{role: :system} ->
        :ok

      actor ->
        if ActorHasPermission.match?(actor, [permission: "declarative_checks.manage"], %{}) do
          :ok
        else
          {:error, Forbidden.exception([])}
        end
    end
  end

  defp extract_actor(opts) do
    ServiceRadar.DeclarativeChecks.extract_actor(opts)
  end

  defp maybe_kw(kw, _k, nil), do: kw
  defp maybe_kw(kw, k, v), do: Keyword.put(kw, k, v)
end
