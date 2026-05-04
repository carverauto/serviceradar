defmodule ServiceRadarWebNG.Dashboards.Packages do
  @moduledoc """
  Context module for browser dashboard package import and enablement.
  """

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Dashboards.PackageImport
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadarWebNG.Plugins.GitHubImporter
  alias ServiceRadarWebNG.Plugins.Storage

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [DashboardPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    query =
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> maybe_filter_dashboard_id(filters)
      |> maybe_filter_status(filters)
      |> maybe_filter_source_type(filters)
      |> Ash.Query.limit(limit)
      |> Ash.Query.sort(inserted_at: :desc)

    read(query, scope)
  end

  @spec get(String.t(), keyword()) ::
          {:ok, DashboardPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_package(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec import_json(binary(), binary(), keyword()) :: {:ok, DashboardPackage.t()} | {:error, term()}
  def import_json(manifest_json, wasm, opts \\ [])

  def import_json(manifest_json, wasm, opts) when is_binary(manifest_json) and is_binary(wasm) do
    ash_opts = ash_opts(Keyword.get(opts, :scope), Keyword.get(opts, :actor))

    with {:ok, manifest} <- ServiceRadar.Dashboards.Manifest.from_json(manifest_json),
         :ok <- PackageImport.verify_artifact_digest(wasm, manifest),
         {:ok, attrs} <- PackageImport.attrs_from_manifest(manifest, import_options(opts)),
         {:ok, package} <- upsert_package(attrs, ash_opts) do
      store_wasm_blob(package, wasm, attrs.content_hash, ash_opts)
    end
  end

  def import_json(_manifest_json, _wasm, _opts), do: {:error, :invalid_attributes}

  @spec import_github(map(), keyword()) :: {:ok, DashboardPackage.t()} | {:error, term()}
  def import_github(attrs, opts \\ [])

  def import_github(attrs, opts) when is_map(attrs) do
    ash_opts = ash_opts(Keyword.get(opts, :scope), Keyword.get(opts, :actor))

    with {:ok, import} <- GitHubImporter.fetch_dashboard(attrs),
         :ok <- PackageImport.verify_artifact_digest(import.renderer_artifact, import.manifest_struct),
         {:ok, package_attrs} <-
           PackageImport.attrs_from_manifest(import.manifest_struct, import_github_options(import, attrs, opts)),
         {:ok, package} <- upsert_package(package_attrs, ash_opts) do
      store_wasm_blob(package, import.renderer_artifact, package_attrs.content_hash, ash_opts)
    end
  end

  def import_github(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec enable(String.t(), keyword()) :: {:ok, DashboardPackage.t()} | {:error, term()}
  def enable(id, opts \\ [])

  def enable(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope),
         :ok <- require_verified(package) do
      package
      |> Ash.Changeset.for_update(:enable, %{})
      |> update_resource(scope)
    end
  end

  def enable(_id, _opts), do: {:error, :invalid_attributes}

  @spec disable(String.t(), keyword()) :: {:ok, DashboardPackage.t()} | {:error, term()}
  def disable(id, opts \\ [])

  def disable(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:disable, %{})
      |> update_resource(scope)
    end
  end

  def disable(_id, _opts), do: {:error, :invalid_attributes}

  @spec create_instance(DashboardPackage.t(), map(), keyword()) ::
          {:ok, DashboardInstance.t()} | {:error, term()}
  def create_instance(package, attrs, opts \\ [])

  def create_instance(%DashboardPackage{} = package, attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, settings} <- validate_instance_settings(package, attrs) do
      attrs =
        attrs
        |> stringify_or_atom_map()
        |> Map.put(:settings, settings)
        |> Map.put_new(:dashboard_package_id, package.id)
        |> Map.put_new(:name, package.name)
        |> Map.put_new(:route_slug, default_route_slug(package))

      DashboardInstance
      |> Ash.Changeset.for_create(:upsert, attrs)
      |> create_resource(scope)
    end
  end

  def create_instance(_package, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec get_instance(String.t(), keyword()) ::
          {:ok, DashboardInstance.t()} | {:error, :not_found} | {:error, term()}
  def get_instance(id, opts \\ [])

  def get_instance(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    query =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.load(:dashboard_package)

    case read_one(query, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, instance} -> {:ok, instance}
      {:error, error} -> {:error, error}
    end
  end

  def get_instance(_id, _opts), do: {:error, :not_found}

  @spec update_instance(String.t(), map(), keyword()) ::
          {:ok, DashboardInstance.t()} | {:error, term()}
  def update_instance(id, attrs, opts \\ [])

  def update_instance(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, instance} <- get_instance(id, scope: scope),
         {:ok, attrs} <- normalize_instance_update_attrs(instance, attrs) do
      instance
      |> Ash.Changeset.for_update(:update, attrs)
      |> update_resource(scope)
    end
  end

  def update_instance(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec set_default_instance(String.t(), keyword()) ::
          {:ok, DashboardInstance.t()} | {:error, term()}
  def set_default_instance(id, opts \\ [])

  def set_default_instance(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, instance} <- get_instance(id, scope: scope),
         :ok <- unset_other_default_instances(instance, scope) do
      instance
      |> Ash.Changeset.for_update(:update, %{enabled: true, is_default: true})
      |> update_resource(scope)
    end
  end

  def set_default_instance(_id, _opts), do: {:error, :invalid_attributes}

  @spec enabled_instances(keyword()) :: [DashboardInstance.t()]
  def enabled_instances(opts \\ []) do
    scope = Keyword.get(opts, :scope)

    DashboardInstance
    |> Ash.Query.for_read(:enabled)
    |> Ash.Query.sort(is_default: :desc, inserted_at: :desc)
    |> read(scope)
  end

  @spec get_enabled_instance_by_slug(String.t(), keyword()) ::
          {:ok, DashboardInstance.t()} | {:error, :not_found} | {:error, term()}
  def get_enabled_instance_by_slug(slug, opts \\ [])

  def get_enabled_instance_by_slug(slug, opts) when is_binary(slug) do
    scope = Keyword.get(opts, :scope)

    query =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == ^slug and enabled == true)
      |> Ash.Query.load(:dashboard_package)

    case read_one(query, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, instance} -> {:ok, instance}
      {:error, error} -> {:error, error}
    end
  end

  def get_enabled_instance_by_slug(_slug, _opts), do: {:error, :not_found}

  defp upsert_package(attrs, ash_opts) do
    DashboardPackage
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> create_resource_with_opts(ash_opts)
  end

  defp store_wasm_blob(%DashboardPackage{} = package, payload, content_hash, opts) do
    object_key = Storage.object_key_for(package)

    with :ok <- Storage.put_blob(object_key, payload) do
      package
      |> Ash.Changeset.for_update(:update, %{
        wasm_object_key: object_key,
        content_hash: content_hash
      })
      |> update_resource_with_opts(opts)
    end
  end

  defp require_verified(%DashboardPackage{verification_status: "verified"}), do: :ok
  defp require_verified(_package), do: {:error, :verification_required}

  defp validate_instance_settings(%DashboardPackage{} = package, attrs) do
    settings_schema = package.settings_schema || %{}
    settings = Map.get(attrs, :settings) || Map.get(attrs, "settings") || %{}
    normalized = ConfigSchema.normalize_params(settings_schema, settings)

    case ConfigSchema.validate_params(settings_schema, normalized) do
      :ok -> {:ok, normalized}
      {:error, errors} -> {:error, {:invalid_settings, errors}}
    end
  end

  defp normalize_instance_update_attrs(%DashboardInstance{} = instance, attrs) do
    attrs = stringify_or_atom_map(attrs)

    with {:ok, settings} <- maybe_validate_instance_settings(instance, attrs) do
      attrs =
        if Map.has_key?(attrs, :settings) or Map.has_key?(attrs, "settings") do
          Map.put(attrs, :settings, settings)
        else
          attrs
        end

      {:ok, attrs}
    end
  end

  defp maybe_validate_instance_settings(%DashboardInstance{dashboard_package: %DashboardPackage{} = package}, attrs) do
    if Map.has_key?(attrs, :settings) or Map.has_key?(attrs, "settings") do
      validate_instance_settings(package, attrs)
    else
      {:ok, instance_settings(attrs)}
    end
  end

  defp maybe_validate_instance_settings(_instance, _attrs), do: {:error, :not_found}

  defp instance_settings(attrs), do: Map.get(attrs, :settings) || Map.get(attrs, "settings") || %{}

  defp unset_other_default_instances(%DashboardInstance{} = instance, scope) do
    query =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(placement == ^instance.placement and is_default == true and id != ^instance.id)

    query
    |> read(scope)
    |> Enum.reduce_while(:ok, fn other, :ok ->
      case other
           |> Ash.Changeset.for_update(:update, %{is_default: false})
           |> update_resource(scope) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp maybe_filter_dashboard_id(query, filters) do
    dashboard_id = Map.get(filters, :dashboard_id) || Map.get(filters, "dashboard_id")

    if is_binary(dashboard_id) and String.trim(dashboard_id) != "" do
      Ash.Query.filter(query, dashboard_id == ^dashboard_id)
    else
      query
    end
  end

  defp maybe_filter_status(query, filters) do
    case normalize_list(Map.get(filters, :status) || Map.get(filters, "status")) do
      [] -> query
      list -> Ash.Query.filter(query, status in ^list)
    end
  end

  defp maybe_filter_source_type(query, filters) do
    case normalize_list(Map.get(filters, :source_type) || Map.get(filters, "source_type")) do
      [] -> query
      list -> Ash.Query.filter(query, source_type in ^list)
    end
  end

  defp import_options(opts) do
    [
      wasm_object_key: Keyword.get(opts, :wasm_object_key),
      signature: Keyword.get(opts, :signature, %{}),
      source_type: Keyword.get(opts, :source_type, :upload),
      source_repo_url: Keyword.get(opts, :source_repo_url),
      source_ref: Keyword.get(opts, :source_ref),
      source_manifest_path: Keyword.get(opts, :source_manifest_path),
      source_commit: Keyword.get(opts, :source_commit),
      source_bundle_digest: Keyword.get(opts, :source_bundle_digest),
      source_metadata: Keyword.get(opts, :source_metadata, %{}),
      imported_at: Keyword.get(opts, :imported_at) || DateTime.utc_now(),
      verification_status: Keyword.get(opts, :verification_status, "verified"),
      verification_error: Keyword.get(opts, :verification_error)
    ]
  end

  defp import_github_options(import, attrs, opts) do
    source_metadata =
      Map.merge(import.manifest_struct.source, %{
        "source" => "github",
        "manifest_path" => import.source_manifest_path,
        "renderer_path" => import.source_renderer_path
      })

    opts
    |> Keyword.put(:signature, import.signature)
    |> Keyword.put(:source_type, :git)
    |> Keyword.put(:source_repo_url, fetch_value(attrs, [:source_repo_url, "source_repo_url"]))
    |> Keyword.put(:source_ref, fetch_value(attrs, [:source_commit, "source_commit"]))
    |> Keyword.put(:source_manifest_path, import.source_manifest_path)
    |> Keyword.put(:source_commit, import.source_commit)
    |> Keyword.put(:source_bundle_digest, Storage.sha256(import.manifest_json <> import.renderer_artifact))
    |> Keyword.put(:source_metadata, source_metadata)
    |> Keyword.put(:verification_status, "verified")
    |> Keyword.put(:verification_error, nil)
    |> import_options()
  end

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, scope: scope)

  defp read_one_package(id, nil) do
    DashboardPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one()
  end

  defp read_one_package(id, scope) do
    DashboardPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
  end

  defp read_one(query, nil), do: Ash.read_one(query)
  defp read_one(query, scope), do: Ash.read_one(query, scope: scope)

  defp create_resource(changeset, nil), do: Ash.create(changeset)
  defp create_resource(changeset, scope), do: Ash.create(changeset, scope: scope)

  defp create_resource_with_opts(changeset, []), do: Ash.create(changeset)
  defp create_resource_with_opts(changeset, ash_opts), do: Ash.create(changeset, ash_opts)

  defp update_resource(changeset, nil), do: Ash.update(changeset)
  defp update_resource(changeset, scope), do: Ash.update(changeset, scope: scope)

  defp update_resource_with_opts(changeset, opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    cond do
      not is_nil(scope) -> Ash.update(changeset, scope: scope)
      not is_nil(actor) -> Ash.update(changeset, actor: actor)
      true -> Ash.update(changeset)
    end
  end

  defp ash_opts(scope, _actor) when not is_nil(scope), do: [scope: scope]
  defp ash_opts(_scope, actor) when not is_nil(actor), do: [actor: actor]
  defp ash_opts(_scope, _actor), do: []

  defp normalize_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_list(nil), do: []

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_atom/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_list(value), do: normalize_list([value])

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> String.to_existing_atom(string)
    end
  rescue
    ArgumentError -> nil
  end

  defp normalize_atom(_), do: nil

  defp stringify_or_atom_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), value}
        rescue
          ArgumentError -> {key, value}
        end

      pair ->
        pair
    end)
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp default_route_slug(%DashboardPackage{} = package) do
    [package.dashboard_id, package.version]
    |> Enum.join("-")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dashboard-package"
      slug -> slug
    end
  end
end
