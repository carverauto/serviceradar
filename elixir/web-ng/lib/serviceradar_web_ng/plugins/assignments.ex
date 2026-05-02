defmodule ServiceRadarWebNG.Plugins.Assignments do
  @moduledoc """
  Context module for agent plugin assignments.
  """

  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadarWebNG.Plugins.Packages

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [PluginAssignment.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    query =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> maybe_filter_agent_uid(filters)
      |> maybe_filter_package_id(filters)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(inserted_at: :desc)

    read(query, scope)
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

    with {:ok, assignment} <- get_raw(id, scope: scope) do
      schema = fetch_config_schema(%{plugin_package_id: assignment.plugin_package_id}, scope)
      attrs = prepare_secret_params(attrs, schema, assignment.params || %{})

      assignment
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.Changeset.set_context(%{config_schema: schema})
      |> update_resource_with_opts(ash_opts)
      |> maybe_sync_assignment_service_state()
      |> maybe_redact_assignment()
    end
  end

  def update(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec delete(String.t(), keyword()) :: {:ok, PluginAssignment.t()} | {:error, term()}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)
    ash_opts = ash_opts(scope, actor)

    with {:ok, assignment} <- get(id, scope: scope) do
      result =
        assignment
        |> Ash.Changeset.for_destroy(:destroy)
        |> destroy_resource_with_opts(ash_opts)

      case result do
        :ok ->
          ServiceStateRegistry.deactivate_for_assignment(assignment)
          :ok

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

  defp redact_assignment(%PluginAssignment{} = assignment) do
    %{assignment | params: SecretRefs.public_params(assignment.params || %{})}
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
