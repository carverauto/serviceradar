defmodule ServiceRadarWebNG.Plugins.Packages do
  @moduledoc """
  Context module for plugin packages and review workflow.
  """

  require Ash.Query

  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [PluginPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    query =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> maybe_filter_plugin_id(filters)
      |> maybe_filter_status(filters)
      |> maybe_filter_source_type(filters)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(inserted_at: :desc)

    read(query, scope)
  end

  @spec get(String.t(), keyword()) :: {:ok, PluginPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ []) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    attrs = drop_nil_values(attrs)
    manifest = Map.get(attrs, :manifest) || %{}

    with {:ok, manifest_struct} <- Manifest.from_map(manifest),
         {:ok, _plugin} <- ensure_plugin(manifest_struct, attrs, scope) do
      attrs =
        attrs
        |> Map.put_new(:plugin_id, manifest_struct.id)
        |> Map.put_new(:name, manifest_struct.name)
        |> Map.put_new(:version, manifest_struct.version)
        |> Map.put_new(:description, manifest_struct.description)
        |> Map.put_new(:entrypoint, manifest_struct.entrypoint)
        |> Map.put_new(:runtime, manifest_struct.runtime)
        |> Map.put_new(:outputs, manifest_struct.outputs)

      PluginPackage
      |> Ash.Changeset.for_create(:create, attrs)
      |> create_resource(scope)
    else
      {:error, errors} when is_list(errors) ->
        {:error, {:invalid_manifest, errors}}

      {:error, error} ->
        {:error, error}
    end
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec approve(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def approve(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      attrs =
        attrs
        |> apply_manifest_defaults(package.manifest || %{})
        |> maybe_put(:approved_by, Keyword.get(opts, :approved_by))

      package
      |> Ash.Changeset.for_update(:approve, attrs)
      |> update_resource(scope)
    end
  end

  def approve(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec deny(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def deny(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:deny, attrs)
      |> update_resource(scope)
    end
  end

  def deny(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec revoke(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def revoke(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:revoke, attrs)
      |> update_resource(scope)
    end
  end

  def revoke(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec restage(String.t(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def restage(id, opts \\ []) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:restage, %{})
      |> update_resource(scope)
    end
  end

  def restage(_id, _opts), do: {:error, :invalid_attributes}

  defp ensure_plugin(%Manifest{} = manifest, attrs, scope) do
    plugin_id = manifest.id
    source = Map.get(manifest, :source) || %{}

    plugin_attrs = %{
      plugin_id: plugin_id,
      name: Map.get(attrs, :plugin_name) || manifest.name,
      description: Map.get(attrs, :plugin_description) || manifest.description,
      source_repo_url:
        Map.get(attrs, :source_repo_url) ||
          Map.get(source, :repo_url) ||
          Map.get(source, "repo_url"),
      homepage_url:
        Map.get(attrs, :homepage_url) ||
          Map.get(source, :homepage) ||
          Map.get(source, "homepage")
    }

    case read_plugin(plugin_id, scope) do
      {:ok, nil} ->
        Plugin
        |> Ash.Changeset.for_create(:create, plugin_attrs)
        |> create_resource(scope)

      {:ok, plugin} ->
        {:ok, plugin}

      {:error, error} ->
        {:error, error}
    end
  end

  defp read_plugin(plugin_id, nil) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one()
  end

  defp read_plugin(plugin_id, scope) do
    Plugin
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(plugin_id == ^plugin_id)
    |> Ash.read_one(scope: scope)
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one_by_id(id, nil) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  defp read_one_by_id(id, scope) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp create_resource(changeset, nil), do: Ash.create(changeset)
  defp create_resource(changeset, scope), do: Ash.create(changeset, scope: scope)

  defp update_resource(changeset, nil), do: Ash.update(changeset)
  defp update_resource(changeset, scope), do: Ash.update(changeset, scope: scope)

  defp maybe_filter_plugin_id(query, filters) do
    plugin_id = Map.get(filters, :plugin_id) || Map.get(filters, "plugin_id")

    if is_binary(plugin_id) and plugin_id != "" do
      Ash.Query.filter(query, plugin_id == ^plugin_id)
    else
      query
    end
  end

  defp maybe_filter_status(query, filters) do
    statuses = Map.get(filters, :status) || Map.get(filters, "status")

    case normalize_list(statuses) do
      [] -> query
      list -> Ash.Query.filter(query, status in ^list)
    end
  end

  defp maybe_filter_source_type(query, filters) do
    source = Map.get(filters, :source_type) || Map.get(filters, "source_type")

    case normalize_list(source) do
      [] -> query
      list -> Ash.Query.filter(query, source_type in ^list)
    end
  end

  defp apply_manifest_defaults(attrs, manifest) do
    attrs
    |> maybe_put(:approved_capabilities, Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities))
    |> maybe_put(:approved_permissions, Map.get(manifest, "permissions") || Map.get(manifest, :permissions))
    |> maybe_put(:approved_resources, Map.get(manifest, "resources") || Map.get(manifest, :resources))
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value) when value == [], do: attrs
  defp maybe_put(attrs, key, value) when value == %{}, do: attrs

  defp maybe_put(attrs, key, value) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, value)
      [] -> Map.put(attrs, key, value)
      %{} = current when map_size(current) == 0 -> Map.put(attrs, key, value)
      _ -> attrs
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

  defp normalize_list(nil), do: []
  defp normalize_list(""), do: []

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_status_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_list()
  end

  defp normalize_list(_), do: []

  defp normalize_status_value(value) when is_atom(value), do: value
  defp normalize_status_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      try do
        String.to_existing_atom(trimmed)
      rescue
        ArgumentError -> nil
      end
    end
  end

  defp normalize_status_value(_), do: nil

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
