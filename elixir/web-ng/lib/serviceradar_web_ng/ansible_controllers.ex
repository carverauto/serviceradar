defmodule ServiceRadarWebNG.AnsibleControllers do
  @moduledoc """
  Web-facing operations for AWX/AAP controller registration.
  """

  alias ServiceRadar.Automation.Ansible.Controller

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
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
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
      Controller.update_controller(controller, attrs, scope: scope)
    end
  end

  @spec set_enabled(String.t(), boolean(), keyword()) ::
          {:ok, struct()} | {:error, :not_found} | {:error, term()}
  def set_enabled(id, enabled, opts \\ []) when is_binary(id) and is_boolean(enabled) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, controller} <- get(id, scope: scope) do
      if enabled do
        Controller.enable_controller(controller, scope: scope)
      else
        Controller.disable_controller(controller, scope: scope)
      end
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
