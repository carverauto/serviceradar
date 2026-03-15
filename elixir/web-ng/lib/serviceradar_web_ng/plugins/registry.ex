defmodule ServiceRadarWebNG.Plugins.Registry do
  @moduledoc """
  Context module for plugin root records.
  """

  alias ServiceRadar.Plugins.Plugin

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(keyword()) :: [Plugin.t()]
  def list(opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))

    query =
      Plugin
      |> Ash.Query.for_read(:read)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(name: :asc)

    read(query, scope)
  end

  @spec get(String.t(), keyword()) :: {:ok, Plugin.t()} | {:error, :not_found} | {:error, term()}
  def get(plugin_id, opts \\ [])

  def get(plugin_id, opts) when is_binary(plugin_id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id(plugin_id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, plugin} -> {:ok, plugin}
      {:error, error} -> {:error, error}
    end
  end

  def get(_plugin_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, Plugin.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    Plugin
    |> Ash.Changeset.for_create(:create, attrs)
    |> create_resource(scope)
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec update(String.t(), map(), keyword()) :: {:ok, Plugin.t()} | {:error, term()}
  def update(plugin_id, attrs, opts \\ [])

  def update(plugin_id, attrs, opts) when is_binary(plugin_id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, plugin} <- get(plugin_id, scope: scope) do
      plugin
      |> Ash.Changeset.for_update(:update, attrs)
      |> update_resource(scope)
    end
  end

  def update(_plugin_id, _attrs, _opts), do: {:error, :invalid_attributes}

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one_by_id(plugin_id, nil) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one()
  end

  defp read_one_by_id(plugin_id, scope) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one(scope: scope)
  end

  defp create_resource(changeset, nil), do: Ash.create(changeset)
  defp create_resource(changeset, scope), do: Ash.create(changeset, scope: scope)

  defp update_resource(changeset, nil), do: Ash.update(changeset)
  defp update_resource(changeset, scope), do: Ash.update(changeset, scope: scope)

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
