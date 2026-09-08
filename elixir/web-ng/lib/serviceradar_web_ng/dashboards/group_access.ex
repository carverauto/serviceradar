defmodule ServiceRadarWebNG.Dashboards.GroupAccess do
  @moduledoc """
  Serialized boundary for authored and package dashboard group grants.

  The boundary reconstructs the initiating human's authority, owns the
  transaction, and locks one `(source, target, group)` key before it rereads
  canonical target and grant state.
  """

  alias Ash.Page.Keyset
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Identity.CurrentUserAuthority
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query
  require Logger

  @page_size 50
  @boundary_context %{dashboard_group_access_boundary_owned: true}

  @type source :: :authored | :package
  @type entrypoint :: :policy_editor | :local
  @type cursor_selector :: :first | {:after, String.t()} | {:before, String.t()}

  @spec page(map(), {:policy_editor, source()}, String.t(), cursor_selector()) ::
          {:ok, Keyset.t()} | {:error, term()}
  def page(scope, {:policy_editor, source}, group_id, selector)
      when source in [:authored, :package] and is_binary(group_id) and
             (selector == :first or
                (is_tuple(selector) and tuple_size(selector) == 2 and elem(selector, 0) in [:after, :before] and
                   is_binary(elem(selector, 1)))) do
    with {:ok, actor} <- current_actor(scope, {:policy_editor, source}, []),
         {:ok, page} <- read_page(actor, source, group_id, selector) do
      normalize_page_cursors({:ok, page}, selector)
    end
  end

  def page(_scope, _entrypoint_source, _group_id, _selector), do: {:error, :invalid_attributes}

  @spec ensure_group_view(map(), {entrypoint(), source()}, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_group_view(scope, entrypoint_source, target_id, group_id, opts \\ []) do
    set_group_access(scope, entrypoint_source, target_id, group_id, :view, opts)
  end

  @spec revoke_group_view(map(), {entrypoint(), source()}, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def revoke_group_view(scope, entrypoint_source, target_id, group_id, opts \\ []) do
    run_mutation(scope, entrypoint_source, target_id, group_id, :revoke_view, opts)
  end

  @spec set_group_access(
          map(),
          {entrypoint(), source()},
          String.t(),
          String.t(),
          :view | :edit,
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def set_group_access(scope, entrypoint_source, target_id, group_id, access, opts \\ [])

  def set_group_access(scope, entrypoint_source, target_id, group_id, access, opts) when access in [:view, :edit] do
    run_mutation(scope, entrypoint_source, target_id, group_id, {:set, access}, opts)
  end

  def set_group_access(_scope, _entrypoint_source, _target_id, _group_id, _access, _opts),
    do: {:error, :invalid_attributes}

  @doc false
  @spec revoke_group_access(map(), {:local, source()}, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def revoke_group_access(scope, {:local, source}, target_id, group_id, opts \\ []) do
    run_mutation(scope, {:local, source}, target_id, group_id, :revoke_access, opts)
  end

  defp read_page(actor, source, group_id, selector) do
    source
    |> target_resource()
    |> Ash.Query.for_read(:policy_editor_audience, %{group_id: group_id}, actor: actor)
    |> Ash.read(actor: actor, page: page_options(selector))
  end

  defp run_mutation(scope, {entrypoint, source} = entrypoint_source, target_id, group_id, operation, opts)
       when entrypoint in [:policy_editor, :local] and source in [:authored, :package] and is_binary(target_id) and
              is_binary(group_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_not_supported}
    else
      with {:ok, actor} <- current_actor(scope, entrypoint_source, opts),
           {:ok, {result, audit_opts}} <-
             owned_transaction(actor, entrypoint_source, target_id, group_id, operation, opts) do
        if audit_opts, do: safe_audit(audit_opts, opts)
        {:ok, result}
      end
    end
  end

  defp run_mutation(_scope, _entrypoint_source, _target_id, _group_id, _operation, _opts),
    do: {:error, :invalid_attributes}

  defp current_actor(scope, entrypoint_source, _opts) do
    case CurrentUserAuthority.authorize(scope, required_permissions(entrypoint_source)) do
      {:ok, %{user: user, permissions: %MapSet{} = permissions}} ->
        {:ok, Map.put(user, :permissions, permissions)}

      {:error, _reason} = error ->
        error
    end
  end

  defp required_permissions({:policy_editor, :authored}), do: ["settings.rbac.manage", "analytics.dashboards.share"]

  defp required_permissions({:policy_editor, :package}), do: ["settings.rbac.manage", "dashboards.packages.share"]

  defp required_permissions({:local, _source}), do: []

  defp owned_transaction(actor, entrypoint_source, target_id, group_id, operation, opts) do
    Repo.transaction(fn ->
      lock_key = lock_key(entrypoint_source, target_id, group_id)

      _ =
        SQL.query!(
          Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          [lock_key]
        )

      case mutate_locked(actor, entrypoint_source, target_id, group_id, operation, opts) do
        {:ok, result, audit_opts} -> {result, audit_opts}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp mutate_locked(actor, {entrypoint, source}, target_id, group_id, operation, opts) do
    with {:ok, target} <- locked_target(actor, entrypoint, source, target_id, group_id),
         :ok <- fingerprint_matches(target, Keyword.get(opts, :expected_fingerprint)) do
      mutate_visible_target(actor, entrypoint, source, target, group_id, operation, opts)
    end
  end

  defp mutate_visible_target(_actor, entrypoint, _source, %{visibility: :public} = target, _group_id, operation, _opts)
       when entrypoint == :policy_editor or operation == {:set, :view} do
    result = %{
      target: target,
      grant: selected_grant(target),
      changed?: false,
      visibility_changed?: false
    }

    {:ok, result, nil}
  end

  defp mutate_visible_target(actor, entrypoint, source, target, group_id, operation, opts) do
    with {:ok, target, visibility_changed?} <-
           maybe_share_package(actor, entrypoint, source, target, operation),
         :ok <- run_hook(Keyword.get(opts, :before_grant)),
         {:ok, grant, changed?} <-
           mutate_grant(actor, entrypoint, source, target, group_id, operation, opts) do
      result = %{
        target: target,
        grant: grant,
        changed?: changed?,
        visibility_changed?: visibility_changed?
      }

      audit_opts =
        if changed? or visibility_changed?,
          do: audit_opts(actor, source, target, group_id, operation, visibility_changed?)

      {:ok, result, audit_opts}
    end
  end

  defp locked_target(actor, entrypoint, source, target_id, group_id) do
    action =
      case entrypoint do
        :policy_editor -> :policy_editor_group_access_target
        :local -> :local_group_access_target
      end

    source
    |> target_resource()
    |> Ash.Query.for_read(action, %{id: target_id, group_id: group_id}, actor: actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
    |> require_record(:target_not_found)
  end

  defp fingerprint_matches(_target, nil), do: :ok

  defp fingerprint_matches(target, expected) do
    if fingerprint(target) == expected, do: :ok, else: {:error, :stale}
  end

  defp maybe_share_package(_actor, _entrypoint, :authored, target, _operation), do: {:ok, target, false}

  defp maybe_share_package(_actor, _entrypoint, :package, target, operation)
       when operation in [:revoke_view, :revoke_access], do: {:ok, target, false}

  defp maybe_share_package(_actor, _entrypoint, :package, %{visibility: visibility} = target, _operation)
       when visibility != :private, do: {:ok, target, false}

  defp maybe_share_package(actor, entrypoint, :package, target, _operation) do
    action =
      case entrypoint do
        :policy_editor -> :set_shared_for_policy_editor
        :local -> :set_shared_for_local_group_access
      end

    target
    |> Ash.Changeset.for_update(action, %{}, actor: actor, context: @boundary_context)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, updated} -> {:ok, updated, true}
      {:error, _reason} = error -> error
    end
  end

  defp mutate_grant(actor, entrypoint, source, target, group_id, {:set, :view}, _opts) do
    attrs = ensure_grant_attrs(source, target.id, group_id, actor.id)
    action = ensure_group_view_action(entrypoint, source)

    source
    |> grant_resource()
    |> Ash.Changeset.for_create(action, attrs, actor: actor, context: @boundary_context)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, grant} -> {:ok, grant, Ash.Resource.get_metadata(grant, :upsert_skipped) != true}
      {:error, _reason} = error -> error
    end
  end

  defp mutate_grant(actor, entrypoint, source, target, group_id, {:set, :edit}, opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    attrs = grant_attrs(source, target.id, group_id, actor.id, :edit, metadata)
    action = set_group_access_action(entrypoint, source)

    source
    |> grant_resource()
    |> Ash.Changeset.for_create(action, attrs, actor: actor, context: @boundary_context)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, grant} -> {:ok, grant, true}
      {:error, _reason} = error -> error
    end
  end

  defp mutate_grant(actor, entrypoint, source, target, _group_id, revoke, _opts)
       when revoke in [:revoke_view, :revoke_access] do
    case selected_grant(target) do
      nil ->
        {:ok, nil, false}

      %{access: access} = grant when revoke == :revoke_view and access != :view ->
        {:ok, grant, false}

      grant ->
        action = revoke_action(entrypoint, source, revoke)

        changeset =
          grant
          |> Ash.Changeset.for_destroy(action, %{}, actor: actor, context: @boundary_context)
          |> maybe_filter_exact_view(revoke)

        case Ash.destroy(changeset, actor: actor, return_destroyed?: true) do
          {:ok, destroyed} -> {:ok, destroyed, true}
          :ok -> {:ok, grant, true}
          {:error, _reason} = error -> error
        end
    end
  end

  defp maybe_filter_exact_view(changeset, :revoke_view),
    do: Ash.Changeset.filter(changeset, Ash.Expr.expr(access == :view))

  defp maybe_filter_exact_view(changeset, :revoke_access), do: changeset

  defp grant_attrs(:authored, target_id, group_id, actor_id, access, metadata) do
    %{
      dashboard_id: target_id,
      subject_group_id: group_id,
      granted_by_id: actor_id,
      access: access,
      metadata: metadata
    }
  end

  defp grant_attrs(:package, target_id, group_id, actor_id, access, metadata) do
    %{
      dashboard_instance_id: target_id,
      subject_group_id: group_id,
      granted_by_id: actor_id,
      access: access,
      metadata: metadata
    }
  end

  defp ensure_grant_attrs(:authored, target_id, group_id, actor_id) do
    %{dashboard_id: target_id, subject_group_id: group_id, granted_by_id: actor_id}
  end

  defp ensure_grant_attrs(:package, target_id, group_id, actor_id) do
    %{dashboard_instance_id: target_id, subject_group_id: group_id, granted_by_id: actor_id}
  end

  defp ensure_group_view_action(:policy_editor, :authored), do: :policy_editor_ensure_group_view

  defp ensure_group_view_action(_entrypoint, _source), do: :ensure_group_view

  defp set_group_access_action(:policy_editor, :authored), do: :policy_editor_set_group_access

  defp set_group_access_action(_entrypoint, _source), do: :set_group_access

  defp revoke_action(:policy_editor, :authored, :revoke_view), do: :policy_editor_revoke_group_view

  defp revoke_action(_entrypoint, _source, :revoke_view), do: :revoke_group_view
  defp revoke_action(_entrypoint, _source, :revoke_access), do: :revoke_group_access

  defp fingerprint(target) do
    grant = selected_grant(target)

    {
      target.visibility,
      target.updated_at,
      grant && grant.id,
      grant && grant.access,
      grant && grant.updated_at
    }
  end

  defp selected_grant(%{access_grants: [grant]}), do: grant
  defp selected_grant(_target), do: nil

  defp lock_key({_entrypoint, source}, target_id, group_id),
    do: "dashboard-group-access:#{source}:#{target_id}:#{group_id}"

  defp audit_opts(actor, source, target, group_id, operation, visibility_changed?) do
    [
      action: audit_action(operation),
      resource_type: "dashboard_group_access",
      resource_id: target.id,
      resource_name: target_name(target),
      actor: actor,
      details: %{
        source: source,
        group_id: group_id,
        visibility_changed: visibility_changed?
      }
    ]
  end

  defp audit_action({:set, :view}), do: :ensure_group_view
  defp audit_action({:set, :edit}), do: :set_group_edit
  defp audit_action(:revoke_view), do: :revoke_group_view
  defp audit_action(:revoke_access), do: :revoke_group_access

  defp target_name(%{title: title}), do: title
  defp target_name(%{name: name}), do: name

  defp safe_audit(audit_opts, opts) do
    case invoke_audit(Keyword.get(opts, :audit_writer, AuditWriter), audit_opts) do
      :ok ->
        :ok

      {:ok, _value} ->
        :ok

      {:error, reason} ->
        Logger.warning("Dashboard group access audit failed: #{inspect(reason)}")

      other ->
        Logger.warning("Dashboard group access audit returned: #{inspect(other)}")
    end
  rescue
    error -> Logger.warning("Dashboard group access audit raised: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("Dashboard group access audit #{kind}: #{inspect(reason)}")
  end

  defp invoke_audit(fun, value) when is_function(fun, 1), do: fun.(value)
  defp invoke_audit(module, value) when is_atom(module), do: module.write(value)

  defp run_hook(nil), do: :ok
  defp run_hook(fun) when is_function(fun, 0), do: fun.()

  defp require_record({:ok, nil}, reason), do: {:error, reason}
  defp require_record(result, _reason), do: result

  defp target_resource(:authored), do: AuthoredDashboard
  defp target_resource(:package), do: DashboardInstance
  defp grant_resource(:authored), do: DashboardAccessGrant
  defp grant_resource(:package), do: DashboardInstanceAccessGrant

  defp page_options(:first), do: [limit: @page_size]

  defp page_options({:after, cursor}) when is_binary(cursor), do: [limit: @page_size, after: cursor]

  defp page_options({:before, cursor}) when is_binary(cursor), do: [limit: @page_size, before: cursor]

  defp normalize_page_cursors({:ok, %Keyset{results: []} = page}, _selector), do: {:ok, %{page | before: nil, after: nil}}

  defp normalize_page_cursors({:ok, %Keyset{results: results, more?: more?} = page}, :first) do
    {:ok, %{page | before: nil, after: cursor_if(more?, List.last(results))}}
  end

  defp normalize_page_cursors({:ok, %Keyset{results: results, more?: more?} = page}, {:after, _cursor}) do
    {:ok, %{page | before: keyset(List.first(results)), after: cursor_if(more?, List.last(results))}}
  end

  defp normalize_page_cursors({:ok, %Keyset{results: results, more?: more?} = page}, {:before, _cursor}) do
    {:ok, %{page | before: cursor_if(more?, List.first(results)), after: keyset(List.last(results))}}
  end

  defp normalize_page_cursors(other, _selector), do: other
  defp cursor_if(true, record), do: keyset(record)
  defp cursor_if(false, _record), do: nil
  defp keyset(nil), do: nil
  defp keyset(record), do: record |> Map.get(:__metadata__, %{}) |> Map.get(:keyset)
end
