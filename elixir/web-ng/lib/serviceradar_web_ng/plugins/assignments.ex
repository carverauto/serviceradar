defmodule ServiceRadarWebNG.Plugins.Assignments do
  @moduledoc """
  Context module for agent plugin assignments.
  """

  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginAssignmentRecovery
  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadarWebNG.Plugins.Packages

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [PluginAssignment.t() | map()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    query =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> maybe_filter_agent_uid(filters)
      |> maybe_filter_package_id(filters)
      |> maybe_filter_plugin_id(filters)
      |> exclude_legacy_history()
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(inserted_at: :desc)

    query
    |> read(scope)
    |> decorate_legacy_recovery(opts)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, PluginAssignment.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @doc """
  Returns the selected agent's current partition proof for assignment UI.

  This is informational only. Creation and recovery resolve the mTLS control
  session again at commit time, and no caller-supplied partition is accepted.
  """
  @spec authenticated_partition_preview(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authenticated_partition_preview(agent_uid, opts \\ [])

  def authenticated_partition_preview(agent_uid, opts) when is_binary(agent_uid) do
    PluginAssignmentRecovery.authenticated_partition_preview(agent_uid, recovery_context_opts(opts))
  end

  def authenticated_partition_preview(_agent_uid, _opts), do: {:error, :invalid_agent_uid}

  @doc """
  Lists the current scope's disabled, partition-unbound assignments that need
  an explicit recovery decision. The core query is tenant-scoped and returns
  identifiers and recovery kind only; package UI code may decorate a row with
  the already-authorized secret-free legacy detail when it needs more context.
  """
  @spec list_legacy(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_legacy(opts \\ []) do
    recovery_opts = recovery_context_opts(opts)
    pagination_opts = Keyword.take(opts, [:limit, :after_id])

    PluginAssignmentRecovery.list_legacy(Keyword.merge(recovery_opts, pagination_opts))
  end

  @doc """
  Reapproves one disabled, partition-unbound manual assignment.

  The core recovery boundary owns authorization, re-resolves the authenticated
  control session, and returns only redacted identifiers and state.
  """
  @spec reapprove_legacy_manual(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reapprove_legacy_manual(legacy_assignment_id, attrs, opts \\ [])

  def reapprove_legacy_manual(legacy_assignment_id, attrs, opts) when is_binary(legacy_assignment_id) and is_map(attrs) do
    with true <- confirmation?(attrs),
         {:ok, recovery} <-
           PluginAssignmentRecovery.recover_manual(
             legacy_assignment_id,
             Keyword.put(recovery_context_opts(opts), :confirm, true)
           ) do
      {:ok, Map.put(recovery, :state, if(recovery[:idempotent?], do: :already_reapproved, else: :reapproved))}
    else
      false -> {:error, :recovery_confirmation_required}
      {:error, _reason} = error -> error
    end
  end

  def reapprove_legacy_manual(_legacy_assignment_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @doc """
  Requests current-policy reconciliation for one disabled, partition-unbound
  policy assignment.

  The request contains only immutable identifiers from the legacy row. A
  restricted core worker later rebuilds the initiating principal's current
  authority, validates live mTLS identity, and delegates to the authoritative
  policy or credential-rule reconciler.
  """
  @spec reconcile_legacy_policy(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_legacy_policy(legacy_assignment_id, attrs, opts \\ [])

  def reconcile_legacy_policy(legacy_assignment_id, attrs, opts) when is_binary(legacy_assignment_id) and is_map(attrs) do
    with true <- confirmation?(attrs),
         {:ok, request} <-
           PolicyOwnedAssignmentRecovery.request(
             legacy_assignment_id,
             Keyword.put(recovery_context_opts(opts), :confirm, true)
           ) do
      {:ok,
       %{
         state: policy_recovery_state(request.status)
       }}
    else
      false -> {:error, :recovery_confirmation_required}
      {:error, _reason} = error -> error
    end
  end

  def reconcile_legacy_policy(_legacy_assignment_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @doc """
  Returns the secret-free recovery detail for a single legacy row.

  This is intentionally an explicit read rather than a caller-supplied detail
  map: core reloads the row within the current scope before it reports owner,
  typed compatibility, or current authenticated partition state.
  """
  @spec legacy_detail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def legacy_detail(legacy_assignment_id, opts \\ [])

  def legacy_detail(legacy_assignment_id, opts) when is_binary(legacy_assignment_id) do
    PluginAssignmentRecovery.legacy_detail(legacy_assignment_id, recovery_context_opts(opts))
  end

  def legacy_detail(_legacy_assignment_id, _opts), do: {:error, :not_found}

  defp get_raw(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id_raw(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, assignment} -> {:ok, assignment}
      {:error, error} -> {:error, error}
    end
  end

  @spec create(map(), keyword()) :: {:ok, PluginAssignment.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)
    attrs = drop_nil_values(attrs)

    schema = fetch_config_schema(attrs, scope)
    attrs = prepare_secret_params(attrs, schema, %{})

    PluginAssignment
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.Changeset.set_context(%{config_schema: schema})
    |> create_resource_with_opts(ash_opts)
    |> maybe_sync_assignment_service_state()
    |> maybe_redact_assignment()
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec update(String.t(), map(), keyword()) :: {:ok, PluginAssignment.t()} | {:error, term()}
  def update(id, attrs, opts \\ [])

  def update(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)
    attrs = drop_nil_values(attrs)

    with {:ok, assignment} <- get_raw(id, scope: scope),
         :ok <- ensure_not_legacy_unbound(assignment) do
      schema =
        fetch_config_schema(
          %{plugin_package_id: Map.get(attrs, :plugin_package_id, assignment.plugin_package_id)},
          scope
        )

      attrs = prepare_secret_params(attrs, schema, assignment.params || %{})

      assignment
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.Changeset.set_context(%{config_schema: schema})
      |> update_resource_with_opts(ash_opts)
      |> maybe_deactivate_replaced_assignment(assignment)
      |> maybe_sync_assignment_service_state()
      |> maybe_redact_assignment()
    end
  end

  def update(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec upgrade(String.t(), String.t(), keyword()) :: {:ok, PluginAssignment.t()} | {:error, term()}
  def upgrade(id, target_package_id, opts \\ [])

  def upgrade(id, target_package_id, opts) when is_binary(id) and is_binary(target_package_id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    upgrade_attrs = opts |> Keyword.get(:attrs, %{}) |> drop_nil_values()

    with {:ok, assignment} <- get_raw(id, scope: scope),
         :ok <- ensure_not_legacy_unbound(assignment),
         :ok <- ensure_manual_assignment(assignment),
         {:ok, target_package} <- Packages.get(target_package_id, scope: scope),
         :ok <- ensure_assignable_package(assignment, target_package) do
      schema = target_package.config_schema || %{}

      attrs = upgrade_attributes(assignment, target_package.id, schema, upgrade_attrs)

      assignment
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.Changeset.set_context(%{config_schema: schema})
      |> update_resource_with_opts(ash_opts)
      |> maybe_sync_assignment_service_state()
      |> maybe_redact_assignment()
    end
  end

  def upgrade(_id, _target_package_id, _opts), do: {:error, :invalid_attributes}

  @spec delete(String.t(), keyword()) :: {:ok, PluginAssignment.t()} | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, assignment} <- get(id, scope: scope),
         :ok <- ensure_not_legacy_unbound(assignment) do
      result =
        assignment
        |> Ash.Changeset.for_destroy(:destroy)
        |> destroy_resource_with_opts(ash_opts)

      case result do
        :ok ->
          ServiceStateRegistry.deactivate_for_assignment(assignment)
          {:ok, assignment}

        {:ok, _assignment} = ok ->
          ServiceStateRegistry.deactivate_for_assignment(assignment)
          ok

        other ->
          other
      end
    end
  end

  def delete(_id, _opts), do: {:error, :invalid_attributes}

  defp read(query, nil), do: query |> Ash.read!() |> Enum.map(&redact_assignment/1)
  defp read(query, scope), do: query |> Ash.read!(scope: scope) |> Enum.map(&redact_assignment/1)

  # Disabled partition-unbound rows are immutable migration history, not
  # current assignments. Keep them out of every normal list and lookup flow;
  # the restricted recovery context remains the only way to enumerate them.
  defp exclude_legacy_history(query) do
    Ash.Query.filter(query, enabled == true or (not is_nil(partition_id) and partition_id != ""))
  end

  defp read_one_by_id(id, nil) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
    |> maybe_redact_assignment()
  end

  defp read_one_by_id(id, scope) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
    |> maybe_redact_assignment()
  end

  defp read_one_by_id_raw(id, nil) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  defp read_one_by_id_raw(id, scope) do
    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp create_resource_with_opts(changeset, opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    cond do
      not is_nil(scope) -> Ash.create(changeset, scope: scope)
      not is_nil(actor) -> Ash.create(changeset, actor: actor)
      true -> Ash.create(changeset)
    end
  end

  defp update_resource_with_opts(changeset, opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    cond do
      not is_nil(scope) -> Ash.update(changeset, scope: scope)
      not is_nil(actor) -> Ash.update(changeset, actor: actor)
      true -> Ash.update(changeset)
    end
  end

  defp destroy_resource_with_opts(changeset, opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    cond do
      not is_nil(scope) -> Ash.destroy(changeset, scope: scope)
      not is_nil(actor) -> Ash.destroy(changeset, actor: actor)
      true -> Ash.destroy(changeset)
    end
  end

  defp ash_opts(scope, _actor) when not is_nil(scope), do: [scope: scope]
  defp ash_opts(_scope, actor) when not is_nil(actor), do: [actor: actor]
  defp ash_opts(_scope, _actor), do: []

  defp maybe_filter_agent_uid(query, filters) do
    agent_uid = Map.get(filters, :agent_uid) || Map.get(filters, "agent_uid")

    if is_binary(agent_uid) and agent_uid != "" do
      Ash.Query.filter(query, agent_uid == ^agent_uid)
    else
      query
    end
  end

  defp maybe_filter_package_id(query, filters) do
    package_id = Map.get(filters, :plugin_package_id) || Map.get(filters, "plugin_package_id")

    if is_binary(package_id) and package_id != "" do
      Ash.Query.filter(query, plugin_package_id == ^package_id)
    else
      query
    end
  end

  defp maybe_filter_plugin_id(query, filters) do
    plugin_id = Map.get(filters, :plugin_id) || Map.get(filters, "plugin_id")

    if is_binary(plugin_id) and plugin_id != "" do
      Ash.Query.filter(query, plugin_id == ^plugin_id)
    else
      query
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp prepare_secret_params(attrs, schema, existing_params) do
    params = Map.get(attrs, :params) || Map.get(attrs, "params")

    if is_map(params) do
      Map.put(attrs, :params, SecretRefs.prepare_params_for_storage(schema, params, existing_params))
    else
      attrs
    end
  end

  defp upgrade_attributes(assignment, target_package_id, schema, attrs) do
    params = Map.get(attrs, :params) || Map.get(attrs, "params") || assignment.params || %{}

    params =
      schema
      |> SecretRefs.prepare_params_for_storage(params, assignment.params || %{})
      |> clamp_numeric_params_to_schema(schema)

    %{
      plugin_package_id: target_package_id,
      params: params
    }
    |> maybe_copy_upgrade_attr(attrs, :enabled)
    |> maybe_copy_upgrade_attr(attrs, :interval_seconds)
    |> maybe_copy_upgrade_attr(attrs, :timeout_seconds)
    |> maybe_copy_upgrade_attr(attrs, :permissions_override)
    |> maybe_copy_upgrade_attr(attrs, :resources_override)
  end

  # Package upgrades retain the existing assignment params, but a newer package
  # may narrow a numeric bound. Clamp only schema-declared numeric properties so
  # target validation can succeed without resetting cursors, secrets, or unknown keys.
  defp clamp_numeric_params_to_schema(params, %{"properties" => properties}) when is_map(params) and is_map(properties) do
    Enum.reduce(properties, params, fn
      {key, %{"type" => type} = property}, acc when type in ["integer", "number"] ->
        clamp_numeric_param(acc, key, type, property)

      _property, acc ->
        acc
    end)
  end

  defp clamp_numeric_params_to_schema(params, _schema), do: params

  defp clamp_numeric_param(params, key, type, property) do
    case Map.fetch(params, key) do
      {:ok, value} when is_number(value) and (type == "number" or is_integer(value)) ->
        Map.put(params, key, clamp_numeric_value(value, type, property))

      _ ->
        params
    end
  end

  defp clamp_numeric_value(value, "integer", property) do
    value
    |> clamp_minimum(integer_bound(Map.get(property, "minimum"), :minimum))
    |> clamp_maximum(integer_bound(Map.get(property, "maximum"), :maximum))
  end

  defp clamp_numeric_value(value, "number", property) do
    value
    |> clamp_minimum(Map.get(property, "minimum"))
    |> clamp_maximum(Map.get(property, "maximum"))
  end

  defp integer_bound(value, _direction) when is_integer(value), do: value
  defp integer_bound(value, :minimum) when is_float(value), do: value |> Float.ceil() |> trunc()
  defp integer_bound(value, :maximum) when is_float(value), do: value |> Float.floor() |> trunc()
  defp integer_bound(_value, _direction), do: nil

  defp clamp_minimum(value, minimum) when is_number(minimum) and value < minimum, do: minimum
  defp clamp_minimum(value, _minimum), do: value

  defp clamp_maximum(value, maximum) when is_number(maximum) and value > maximum, do: maximum
  defp clamp_maximum(value, _maximum), do: value

  defp maybe_copy_upgrade_attr(update_attrs, source_attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(source_attrs, field) -> Map.put(update_attrs, field, Map.fetch!(source_attrs, field))
      Map.has_key?(source_attrs, string_field) -> Map.put(update_attrs, field, Map.fetch!(source_attrs, string_field))
      true -> update_attrs
    end
  end

  defp maybe_redact_assignment({:ok, %PluginAssignment{} = assignment}), do: {:ok, redact_assignment(assignment)}

  defp maybe_redact_assignment({:ok, nil}), do: {:ok, nil}
  defp maybe_redact_assignment(other), do: other

  defp maybe_sync_assignment_service_state({:ok, %PluginAssignment{} = assignment} = ok) do
    if assignment.enabled do
      ServiceStateRegistry.upsert_for_assignment(assignment)
    else
      ServiceStateRegistry.deactivate_for_assignment(assignment)
    end

    ok
  end

  defp maybe_sync_assignment_service_state(other), do: other

  defp maybe_deactivate_replaced_assignment(
         {:ok, %PluginAssignment{plugin_package_id: package_id}} = ok,
         %PluginAssignment{plugin_package_id: old_package_id} = old_assignment
       )
       when package_id != old_package_id do
    ServiceStateRegistry.deactivate_for_assignment(old_assignment)
    ok
  end

  defp maybe_deactivate_replaced_assignment(result, _old_assignment), do: result

  defp redact_assignment(%PluginAssignment{} = assignment) do
    %{assignment | params: SecretRefs.public_params(assignment.params || %{})}
  end

  defp ensure_manual_assignment(%PluginAssignment{source: :policy}), do: {:error, :policy_owned_assignment}
  defp ensure_manual_assignment(%PluginAssignment{}), do: :ok

  defp ensure_not_legacy_unbound(%PluginAssignment{enabled: false, partition_id: partition_id}) do
    if is_binary(partition_id) and String.trim(partition_id) != "" do
      :ok
    else
      {:error, :legacy_partition_reapproval_required}
    end
  end

  defp ensure_not_legacy_unbound(%PluginAssignment{}), do: :ok

  defp confirmation?(attrs) when is_map(attrs) do
    Map.get(attrs, :confirm) == true or Map.get(attrs, "confirm") == true
  end

  defp confirmation?(_attrs), do: false

  defp decorate_legacy_recovery(assignments, opts) when is_list(assignments) do
    Enum.map(assignments, &decorate_legacy_recovery_row(&1, opts))
  end

  defp decorate_legacy_recovery(assignments, _opts), do: assignments

  defp decorate_legacy_recovery_row(%PluginAssignment{enabled: false, partition_id: partition_id} = assignment, opts)
       when partition_id in [nil, ""] do
    case legacy_detail(assignment.id, opts) do
      {:ok, detail} -> Map.put(assignment, :recovery, detail)
      {:error, _reason} -> assignment
    end
  end

  defp decorate_legacy_recovery_row(%PluginAssignment{enabled: false, partition_id: partition_id} = assignment, opts)
       when is_binary(partition_id) do
    if String.trim(partition_id) == "" do
      case legacy_detail(assignment.id, opts) do
        {:ok, detail} -> Map.put(assignment, :recovery, detail)
        {:error, _reason} -> assignment
      end
    else
      assignment
    end
  end

  defp decorate_legacy_recovery_row(assignment, _opts), do: assignment

  # Keep the web context scope-first. Core supports direct `:actor` only for
  # non-web callers and focused tests; a LiveView scope wins if both are
  # supplied so a stale reconstructed actor can never broaden the request.
  defp recovery_context_opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} when not is_nil(scope) -> [scope: scope]
      _ -> Keyword.take(opts, [:actor])
    end
  end

  defp recovery_context_opts(_opts), do: []

  defp policy_recovery_state(:requested), do: :queued
  defp policy_recovery_state(:executing), do: :pending
  defp policy_recovery_state(:reconciled), do: :already_reconciled
  defp policy_recovery_state(status), do: status

  defp ensure_assignable_package(%PluginAssignment{} = assignment, target_package) do
    cond do
      target_package.status != :approved ->
        {:error, :target_package_not_approved}

      target_package.plugin_id != assignment.plugin_id ->
        {:error, :plugin_id_mismatch}

      target_package.id == assignment.plugin_package_id ->
        {:error, :already_on_target_version}

      true ->
        :ok
    end
  end

  defp fetch_config_schema(attrs, scope) do
    package_id = Map.get(attrs, :plugin_package_id) || Map.get(attrs, "plugin_package_id")

    if is_binary(package_id) and package_id != "" do
      case Packages.get(package_id, scope: scope) do
        {:ok, package} -> package.config_schema || %{}
        _ -> %{}
      end
    else
      %{}
    end
  end
end
