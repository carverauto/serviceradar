defmodule ServiceRadar.DeclarativeChecks do
  @moduledoc """
  Ash domain and top-level public facade for Declarative Service & Posture Checks
  (`schema_version: 1`, `1.1`-`1.5`, `2.1`-`2.5`, `3.5`).

  Uses plain `Ash.Domain` / `Ash.Resource` (no `AshJsonApi` router wiring) so
  `/api/v2/declarative-checks*` is owned exclusively by `ServiceRadarWebNG`.
  """

  use Ash.Domain, validate_config_inclusion?: false

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckEdgeObservation
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance
  alias ServiceRadar.Repo

  require Ash.Query

  resources do
    resource DeclarativeCheck
    resource DeclarativeCheckCredentialBinding
    resource DeclarativeCheckInstance
    resource DeclarativeCheckEdgeObservation
  end

  @create_key_map %{
    "schema_version" => :schema_version,
    "slug" => :slug,
    "name" => :name,
    "description" => :description,
    "state" => :state,
    "schedule" => :schedule,
    "target_binding" => :target_binding,
    "inputs" => :inputs,
    "credential_slots" => :credential_slots,
    "nodes" => :nodes,
    "edges" => :edges,
    "alert_policy" => :alert_policy,
    "ui_layout" => :ui_layout,
    "pack_id" => :pack_id,
    "pack_version" => :pack_version,
    "managed" => :managed,
    "parameter_overrides" => :parameter_overrides
  }

  @update_key_map Map.delete(@create_key_map, "slug")

  @doc """
  Lists `DeclarativeCheck` definitions ordered by `slug`, optionally filtered by
  `:state`, `:pack_id`, or `:managed`.
  """
  @spec list_checks(keyword()) :: {:ok, [DeclarativeCheck.t()]} | {:error, term()}
  def list_checks(opts \\ []) when is_list(opts) do
    actor = extract_actor(opts)

    query =
      DeclarativeCheck
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> maybe_filter_state(Keyword.get(opts, :state))
      |> maybe_filter_pack_id(Keyword.get(opts, :pack_id))
      |> maybe_filter_managed(Keyword.get(opts, :managed))

    Ash.read(query, actor: actor)
  end

  @doc """
  Fetches a single `DeclarativeCheck` by `slug`.

  Returns `{:error, :not_found}` when no check with `slug` exists, or
  `{:error, %Ash.Error.Forbidden{}}` when the caller lacks `declarative_checks.view`.
  """
  @spec get_check_by_slug(String.t(), keyword()) ::
          {:ok, DeclarativeCheck.t()} | {:error, :not_found | term()}
  def get_check_by_slug(slug, opts \\ []) when is_binary(slug) and is_list(opts) do
    actor = extract_actor(opts)

    query =
      DeclarativeCheck
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, %DeclarativeCheck{} = check} -> {:ok, check}
      {:ok, nil} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetches a `DeclarativeCheck` by `slug` along with its redacted
  `credential_bindings` and materialized `instance_rollup`.
  """
  @spec get_check_with_bindings(String.t(), keyword()) ::
          {:ok,
           %{
             check: DeclarativeCheck.t(),
             credential_bindings: [DeclarativeCheckCredentialBinding.t()],
             instance_rollup: map()
           }}
          | {:error, :not_found | term()}
  def get_check_with_bindings(slug, opts \\ []) when is_binary(slug) and is_list(opts) do
    actor = extract_actor(opts)

    with {:ok, check} <- get_check_by_slug(slug, opts),
         {:ok, bindings} <-
           DeclarativeCheckCredentialBinding.list_by_check(check.id, actor: actor),
         {:ok, instances} <- DeclarativeCheckInstance.list_by_check(check.id, actor: actor) do
      {:ok,
       %{
         check: check,
         credential_bindings: bindings,
         instance_rollup: build_instance_rollup(instances)
       }}
    end
  end

  @doc """
  Creates a `DeclarativeCheck` (and optional `credential_bindings` atomically).
  """
  @spec create_check(map(), keyword()) :: {:ok, DeclarativeCheck.t()} | {:error, term()}
  def create_check(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    actor = extract_actor(opts)
    {bindings, check_attrs} = pop_bindings(attrs)
    normalized_attrs = coerce_check_attrs(check_attrs, @create_key_map)
    ctx = build_changeset_context(opts, false)

    run_in_tx(fn ->
      with {:ok, created} <-
             DeclarativeCheck
             |> Ash.Changeset.for_create(:create, normalized_attrs, actor: actor, context: ctx)
             |> Ash.create(actor: actor),
           {:ok, _bound} <- maybe_upsert_bindings(created, bindings, opts) do
        {:ok, created}
      end
    end)
  end

  @doc """
  Updates a `DeclarativeCheck` (resolved by `slug` or `%DeclarativeCheck{}`).

  Structural edits to a `managed: true` check return
  `{:error, :managed_detach_confirmation_required}` unless `confirm_detach: true`
  or `allow_detach: true` is passed in `attrs` or `opts`.
  """
  @spec update_check(String.t() | DeclarativeCheck.t(), map(), keyword()) ::
          {:ok, DeclarativeCheck.t()} | {:error, term()}
  def update_check(slug_or_check, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    actor = extract_actor(opts)
    confirm_detach? = detach_confirmed?(attrs, opts)
    {bindings, check_attrs} = pop_bindings(attrs)
    normalized_attrs = coerce_check_attrs(check_attrs, @update_key_map)
    ctx = build_changeset_context(opts, confirm_detach?)

    with {:ok, %DeclarativeCheck{} = existing} <- resolve_check(slug_or_check, opts) do
      run_in_tx(fn ->
        changeset =
          existing
          |> Ash.Changeset.for_update(:update, normalized_attrs, actor: actor, context: ctx)
          |> Ash.Changeset.set_argument(:confirm_detach, confirm_detach?)

        case Ash.update(changeset, actor: actor) do
          {:ok, updated} ->
            with {:ok, _bound} <- maybe_upsert_bindings(updated, bindings, opts) do
              {:ok, updated}
            end

          {:error, err} ->
            {:error, normalize_update_error(err)}
        end
      end)
    end
  end

  @doc """
  Deletes a `DeclarativeCheck` (and cascades its bindings, instances, and edge
  observations while cleaning up its schedule, `StatefulAlertRule`, and
  `ServiceState` rows).
  """
  @spec delete_check(String.t() | DeclarativeCheck.t(), keyword()) ::
          :ok | {:error, :not_found | term()}
  def delete_check(slug_or_check, opts \\ []) when is_list(opts) do
    actor = extract_actor(opts)

    with {:ok, %DeclarativeCheck{} = check} <- resolve_check(slug_or_check, opts) do
      Ash.destroy(check, actor: actor)
    end
  end

  @doc """
  Atomically upserts deployment-local `DeclarativeCheckCredentialBinding` rows
  for a check's declared `credential_slots`.
  """
  @spec upsert_credential_bindings(
          DeclarativeCheck.t() | String.t(),
          [map()],
          keyword()
        ) :: {:ok, [DeclarativeCheckCredentialBinding.t()]} | {:error, term()}
  def upsert_credential_bindings(check_or_ref, bindings_list, opts \\ [])
      when is_list(bindings_list) and is_list(opts) do
    actor = extract_actor(opts)

    with {:ok, %DeclarativeCheck{} = check} <- resolve_check_or_id(check_or_ref, opts),
         :ok <- validate_binding_slots(check, bindings_list) do
      run_in_tx(fn ->
        apply_binding_upserts(check, bindings_list, actor, opts)
      end)
    end
  end

  @doc """
  Serializes a `%DeclarativeCheck{}` into a canonical string-keyed REST JSON map
  without any secret values.
  """
  @spec serialize_check(DeclarativeCheck.t() | map(), keyword()) :: map()
  def serialize_check(check, opts \\ []) when is_map(check) and is_list(opts) do
    canonical = CanonicalJSON.to_canonical_export_map(check)

    base =
      Map.merge(canonical, %{
        "id" => field_str(check, :id),
        "template_fingerprint" => field_str(check, :template_fingerprint),
        "last_evaluated_at" => format_dt(field_val(check, :last_evaluated_at)),
        "inserted_at" => format_dt(field_val(check, :inserted_at)),
        "updated_at" => format_dt(field_val(check, :updated_at))
      })

    base
    |> maybe_put_serialized_bindings(Keyword.get(opts, :credential_bindings))
    |> maybe_put_rollup(Keyword.get(opts, :instance_rollup))
  end

  defp maybe_put_serialized_bindings(map, nil), do: map

  defp maybe_put_serialized_bindings(map, bindings) when is_list(bindings) do
    serialized =
      Enum.map(bindings, fn b ->
        secret_id = field_val(b, :credential_secret_id)
        rule_id = field_val(b, :credential_rule_id)

        %{
          "id" => field_str(b, :id),
          "slot" => field_str(b, :slot),
          "binding_kind" => if(is_nil(secret_id), do: "rule", else: "secret"),
          "credential_secret_id" => secret_id && to_string(secret_id),
          "credential_rule_id" => rule_id && to_string(rule_id),
          "inserted_at" => format_dt(field_val(b, :inserted_at)),
          "updated_at" => format_dt(field_val(b, :updated_at))
        }
      end)

    Map.put(map, "credential_bindings", serialized)
  end

  defp maybe_put_rollup(map, nil), do: map

  defp maybe_put_rollup(map, rollup) when is_map(rollup),
    do: Map.put(map, "instance_rollup", rollup)

  defp build_instance_rollup(instances) when is_list(instances) do
    counts =
      Enum.reduce(
        instances,
        %{"total" => 0, "healthy" => 0, "degraded" => 0, "down" => 0, "unknown" => 0},
        fn inst, acc ->
          st = to_string(inst.status)

          acc
          |> Map.update!("total", &(&1 + 1))
          |> Map.update(st, 1, &(&1 + 1))
        end
      )

    preview =
      instances
      |> Enum.take(100)
      |> Enum.map(fn inst ->
        %{
          "target_key" => inst.target_key,
          "target_kind" => to_string(inst.target_kind),
          "device_uid" => inst.device_uid,
          "service_target_id" => inst.service_target_id,
          "verdict" => inst.verdict,
          "status" => to_string(inst.status),
          "summary" => inst.summary,
          "evaluated_at" => format_dt(inst.evaluated_at),
          "changed_at" => format_dt(inst.changed_at)
        }
      end)

    Map.put(counts, "instances", preview)
  end

  defp maybe_upsert_bindings(_check, nil, _opts), do: {:ok, []}

  defp maybe_upsert_bindings(check, bindings, opts) when is_list(bindings) do
    actor = extract_actor(opts)

    with :ok <- validate_binding_slots(check, bindings) do
      apply_binding_upserts(check, bindings, actor, opts)
    end
  end

  defp validate_binding_slots(%DeclarativeCheck{credential_slots: slots}, bindings) do
    declared =
      slots
      |> List.wrap()
      |> MapSet.new(fn s -> to_string(s["slot"] || s[:slot] || "") end)

    invalid =
      Enum.find(bindings, fn b ->
        slot = to_string(field_val(b, :slot) || "")
        slot == "" or not MapSet.member?(declared, slot)
      end)

    case invalid do
      nil ->
        :ok

      bad ->
        {:error,
         Invalid.exception(
           errors: [
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :credential_bindings,
               message:
                 "undeclared_credential_slot: slot #{inspect(field_val(bad, :slot))} is not declared in credential_slots"
             )
           ]
         )}
    end
  end

  defp apply_binding_upserts(check, bindings, actor, opts) do
    upserted_res =
      Enum.reduce_while(bindings, {:ok, []}, fn raw, {:ok, acc} ->
        attrs = %{
          check_id: check.id,
          slot: to_string(field_val(raw, :slot)),
          credential_secret_id: field_val(raw, :credential_secret_id),
          credential_rule_id: field_val(raw, :credential_rule_id)
        }

        case DeclarativeCheckCredentialBinding.upsert_binding(attrs, actor: actor) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
          {:error, err} -> {:halt, {:error, err}}
        end
      end)

    with {:ok, rows} <- upserted_res,
         :ok <- maybe_prune_unlisted_bindings(check.id, rows, actor, opts) do
      {:ok, Enum.reverse(rows)}
    end
  end

  defp maybe_prune_unlisted_bindings(check_id, kept_rows, actor, opts) do
    if Keyword.get(opts, :replace, false) == true do
      kept_slots = MapSet.new(kept_rows, & &1.slot)

      case DeclarativeCheckCredentialBinding.list_by_check(check_id, actor: actor) do
        {:ok, existing} ->
          existing
          |> Enum.reject(&MapSet.member?(kept_slots, &1.slot))
          |> Enum.reduce_while(:ok, fn stale, :ok ->
            case Ash.destroy(stale, actor: actor) do
              :ok -> {:cont, :ok}
              {:error, err} -> {:halt, {:error, err}}
            end
          end)

        {:error, err} ->
          {:error, err}
      end
    else
      :ok
    end
  end

  defp resolve_check(%DeclarativeCheck{} = check, _opts), do: {:ok, check}
  defp resolve_check(slug, opts) when is_binary(slug), do: get_check_by_slug(slug, opts)

  defp resolve_check_or_id(%DeclarativeCheck{} = check, _opts), do: {:ok, check}

  defp resolve_check_or_id(ref, opts) when is_binary(ref) do
    actor = extract_actor(opts)

    case Ecto.UUID.cast(ref) do
      {:ok, uuid} ->
        query =
          DeclarativeCheck
          |> Ash.Query.for_read(:read, %{}, actor: actor)
          |> Ash.Query.filter(id == ^uuid)
          |> Ash.Query.limit(1)

        case Ash.read_one(query, actor: actor) do
          {:ok, %DeclarativeCheck{} = check} -> {:ok, check}
          {:ok, nil} -> get_check_by_slug(ref, opts)
          {:error, _} = err -> err
        end

      :error ->
        get_check_by_slug(ref, opts)
    end
  end

  defp maybe_filter_state(query, nil), do: query

  defp maybe_filter_state(query, state) when state in [:draft, :enabled, :disabled] do
    Ash.Query.filter(query, state == ^state)
  end

  defp maybe_filter_state(query, state) when is_binary(state) do
    case state do
      "draft" -> Ash.Query.filter(query, state == :draft)
      "enabled" -> Ash.Query.filter(query, state == :enabled)
      "disabled" -> Ash.Query.filter(query, state == :disabled)
      _ -> query
    end
  end

  defp maybe_filter_pack_id(query, nil), do: query
  defp maybe_filter_pack_id(query, ""), do: query

  defp maybe_filter_pack_id(query, pack_id) when is_binary(pack_id) do
    Ash.Query.filter(query, pack_id == ^pack_id)
  end

  defp maybe_filter_managed(query, nil), do: query

  defp maybe_filter_managed(query, managed) when is_boolean(managed) do
    Ash.Query.filter(query, managed == ^managed)
  end

  defp pop_bindings(attrs) do
    cond do
      Map.has_key?(attrs, :credential_bindings) ->
        Map.pop(attrs, :credential_bindings)

      Map.has_key?(attrs, "credential_bindings") ->
        Map.pop(attrs, "credential_bindings")

      true ->
        {nil, attrs}
    end
  end

  defp coerce_check_attrs(attrs, key_map) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      str_key = to_string(k)

      case Map.fetch(key_map, str_key) do
        {:ok, :state} -> Map.put(acc, :state, coerce_state_val(v))
        {:ok, atom_key} -> Map.put(acc, atom_key, v)
        :error -> acc
      end
    end)
  end

  defp coerce_state_val("draft"), do: :draft
  defp coerce_state_val("enabled"), do: :enabled
  defp coerce_state_val("disabled"), do: :disabled
  defp coerce_state_val(other), do: other

  defp detach_confirmed?(attrs, opts) do
    Keyword.get(opts, :confirm_detach, false) == true or
      Keyword.get(opts, :allow_detach, false) == true or
      Map.get(attrs, :confirm_detach) == true or
      Map.get(attrs, "confirm_detach") == true or
      Map.get(attrs, :allow_detach) == true or
      Map.get(attrs, "allow_detach") == true
  end

  defp build_changeset_context(opts, confirm_detach?) do
    %{}
    |> maybe_put_ctx(:skip_srql_nif?, Keyword.get(opts, :skip_srql_nif?, false) == true)
    |> maybe_put_ctx(:confirm_detach, confirm_detach?)
  end

  defp maybe_put_ctx(ctx, _k, false), do: ctx
  defp maybe_put_ctx(ctx, k, true), do: Map.put(ctx, k, true)

  defp normalize_update_error(%Forbidden{} = err), do: err

  defp normalize_update_error(err) do
    msg = Exception.message(err)

    if String.contains?(msg, "managed_detach_confirmation_required") do
      :managed_detach_confirmation_required
    else
      err
    end
  end

  defp run_in_tx(fun) when is_function(fun, 0) do
    if is_pid(Process.whereis(Repo)) do
      case Repo.transaction(fn ->
             case fun.() do
               {:ok, res} -> res
               {:error, err} -> Repo.rollback(err)
             end
           end) do
        {:ok, res} -> {:ok, res}
        {:error, err} -> {:error, err}
      end
    else
      fun.()
    end
  end

  @doc false
  @spec extract_actor(keyword()) :: map() | nil
  def extract_actor(opts) when is_list(opts) do
    case Keyword.get(opts, :actor) do
      nil -> opts |> Keyword.get(:scope) |> actor_from_scope()
      actor -> actor
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = permissions}) when is_map(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{actor: actor, permissions: %MapSet{} = permissions})
       when is_map(actor) do
    actor
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp actor_from_scope(%{user: user}) when not is_nil(user), do: user
  defp actor_from_scope(%{actor: actor}) when not is_nil(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp field_val(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field_str(map, key) do
    case field_val(map, key) do
      nil -> nil
      v -> to_string(v)
    end
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_dt(str) when is_binary(str), do: str
  defp format_dt(_), do: nil
end
