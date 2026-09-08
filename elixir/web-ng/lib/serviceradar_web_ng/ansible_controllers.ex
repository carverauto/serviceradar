defmodule ServiceRadarWebNG.AnsibleControllers do
  @moduledoc """
  Web-facing operations for AWX/AAP controller registration.
  """

  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.ConfigurationRequest

  require Ash.Query

  @default_limit 200
  @max_limit 500

  @spec list(keyword()) :: {:ok, [struct()]} | {:error, term()}
  def list(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    filters = Keyword.get(opts, :filters, %{})

    query =
      Controller
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> maybe_filter_name(filters)
      |> maybe_filter_agent_id(filters)
      |> maybe_filter_enabled(filters)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(normalize_limit(Map.get(filters, "limit") || Map.get(filters, :limit)))

    Ash.read(query, scope: scope)
  end

  @spec get(String.t(), keyword()) :: {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ []) when is_binary(id) do
    scope = Keyword.fetch!(opts, :scope)

    case Controller.get_by_id(id, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, controller} -> {:ok, controller}
      {:error, %NotFound{}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @spec create(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)
    Controller.create_controller(attrs, scope: scope)
  end

  @spec update(String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def update(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, controller} <- get(id, scope: scope) do
      controller
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> ConfigurationRequest.constrain(opts)
      |> Ash.update(scope: scope)
      |> ConfigurationRequest.normalize_result()
    end
  end

  @spec set_enabled(String.t(), boolean(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def set_enabled(id, enabled, opts \\ []) when is_binary(id) and is_boolean(enabled) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, controller} <- get(id, scope: scope) do
      action = if enabled, do: :enable, else: :disable

      controller
      |> Ash.Changeset.for_update(action, %{}, scope: scope)
      |> ConfigurationRequest.constrain(opts)
      |> Ash.update(scope: scope)
      |> ConfigurationRequest.normalize_result()
    end
  end

  @doc "Deletes a disabled controller only when its catalog and membership records are absent."
  def delete(id, opts) do
    scope = Keyword.fetch!(opts, :scope)

    Repo.transaction(fn ->
      with {:ok, controller} <- locked_controller(id, scope),
           :ok <- require_disabled(controller),
           :ok <- require_no_cascading_dependents(Playbook, id, scope),
           :ok <- require_no_cascading_dependents(AwxHostMembership, id, scope),
           :ok <- destroy_controller(controller, scope, opts) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp locked_controller(id, scope) do
    result =
      Controller
      |> Ash.Query.for_read(:by_id, %{id: id}, scope: scope)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(scope: scope)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      other -> other
    end
  end

  defp require_disabled(%{enabled: false}), do: :ok
  defp require_disabled(_controller), do: {:error, :controller_must_be_disabled}

  defp require_no_cascading_dependents(resource, id, scope) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(controller_id == ^id)
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    case Ash.read(query, scope: scope) do
      {:ok, []} -> :ok
      {:ok, [_]} -> {:error, :controller_in_use}
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_controller(controller, scope, opts) do
    result =
      controller
      |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope)
      |> ConfigurationRequest.constrain(opts)
      |> Ash.destroy(scope: scope)
      |> ConfigurationRequest.normalize_result()

    case result do
      {:error, %Ash.Error.Invalid{}} -> {:error, :controller_in_use}
      other -> other
    end
  end

  defp maybe_filter_name(query, filters) do
    case filter_string(filters, "name") do
      nil -> query
      value -> Ash.Query.filter(query, name == ^value)
    end
  end

  defp maybe_filter_agent_id(query, filters) do
    case filter_string(filters, "agent_id") do
      nil -> query
      value -> Ash.Query.filter(query, agent_id == ^value)
    end
  end

  defp maybe_filter_enabled(query, filters) do
    case Map.get(filters, "enabled") || Map.get(filters, :enabled) do
      true -> Ash.Query.filter(query, enabled == true)
      false -> Ash.Query.filter(query, enabled == false)
      "true" -> Ash.Query.filter(query, enabled == true)
      "false" -> Ash.Query.filter(query, enabled == false)
      _ -> query
    end
  end

  defp filter_string(filters, key) do
    value = Map.get(filters, key) || Map.get(filters, String.to_atom(key))

    if is_binary(value) and String.trim(value) != "" do
      String.trim(value)
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
end
