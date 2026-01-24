defmodule ServiceRadarWebNG.Plugins.Packages do
  @moduledoc """
  Context module for plugin packages and review workflow.
  """

  require Ash.Query

  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.GitHubImporter
  alias ServiceRadarWebNG.Plugins.Storage

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

  @spec get(String.t(), keyword()) ::
          {:ok, PluginPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one_by_id(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  @spec create(map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def create(attrs, opts \\ [])

  def create(attrs, opts) when is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    attrs = drop_nil_values(attrs)
    source_type = normalize_source_type(Map.get(attrs, :source_type))

    case source_type do
      :github ->
        create_from_github(attrs, scope)

      :invalid ->
        {:error, :invalid_source_type}

      _ ->
        create_from_upload(attrs, scope)
    end
  end

  def create(_attrs, _opts), do: {:error, :invalid_attributes}

  @spec approve(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def approve(id, attrs, opts \\ [])

  def approve(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope),
         :ok <- enforce_verification_policy(package) do
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
  def deny(id, attrs, opts \\ [])

  def deny(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:deny, attrs)
      |> update_resource(scope)
    end
  end

  def deny(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec revoke(String.t(), map(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def revoke(id, attrs, opts \\ [])

  def revoke(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:revoke, attrs)
      |> update_resource(scope)
    end
  end

  def revoke(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec restage(String.t(), keyword()) :: {:ok, PluginPackage.t()} | {:error, term()}
  def restage(id, opts \\ [])

  def restage(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:restage, %{})
      |> update_resource(scope)
    end
  end

  def restage(_id, _opts), do: {:error, :invalid_attributes}

  @spec upload_blob(PluginPackage.t(), binary(), keyword()) ::
          {:ok, PluginPackage.t()} | {:error, term()}
  def upload_blob(%PluginPackage{} = package, payload, opts \\ []) when is_binary(payload) do
    scope = Keyword.get(opts, :scope)
    content_hash = Storage.sha256(payload)

    store_wasm_blob(package, payload, content_hash, scope)
  end

  def upload_blob(_package, _payload, _opts), do: {:error, :invalid_attributes}

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

  defp create_from_upload(attrs, scope) do
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

  defp create_from_github(attrs, scope) do
    with {:ok, import} <- GitHubImporter.fetch(attrs),
         {:ok, _plugin} <- ensure_plugin(import.manifest_struct, attrs, scope),
         {:ok, package} <- create_github_package(import, attrs, scope) do
      store_wasm_blob(package, import.wasm, import.content_hash, scope)
    end
  end

  defp create_github_package(import, attrs, scope) do
    attrs =
      attrs
      |> Map.put(:manifest, import.manifest)
      |> Map.put_new(:config_schema, import.config_schema || %{})
      |> Map.put(:source_type, :github)
      |> Map.put(:source_commit, import.source_commit)
      |> Map.put(:signature, import.signature || %{})
      |> Map.put(:gpg_verified_at, import.gpg_verified_at)
      |> Map.put(:gpg_key_id, import.gpg_key_id)
      |> Map.put(:content_hash, import.content_hash)

    attrs =
      attrs
      |> Map.put_new(:plugin_id, import.manifest_struct.id)
      |> Map.put_new(:name, import.manifest_struct.name)
      |> Map.put_new(:version, import.manifest_struct.version)
      |> Map.put_new(:description, import.manifest_struct.description)
      |> Map.put_new(:entrypoint, import.manifest_struct.entrypoint)
      |> Map.put_new(:runtime, import.manifest_struct.runtime)
      |> Map.put_new(:outputs, import.manifest_struct.outputs)

    PluginPackage
    |> Ash.Changeset.for_create(:create, attrs)
    |> create_resource(scope)
  end

  defp store_wasm_blob(package, payload, content_hash, scope) do
    object_key = package.wasm_object_key || Storage.object_key_for(package)

    with :ok <- Storage.put_blob(object_key, payload) do
      package
      |> Ash.Changeset.for_update(:update, %{
        wasm_object_key: object_key,
        content_hash: content_hash
      })
      |> update_resource(scope)
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
    |> maybe_put(
      :approved_capabilities,
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities)
    )
    |> maybe_put(
      :approved_permissions,
      Map.get(manifest, "permissions") || Map.get(manifest, :permissions)
    )
    |> maybe_put(
      :approved_resources,
      Map.get(manifest, "resources") || Map.get(manifest, :resources)
    )
  end

  defp enforce_verification_policy(%PluginPackage{} = package) do
    policy = plugin_verification_policy()

    case package.source_type do
      :github -> enforce_github_policy(package, policy)
      :upload -> enforce_upload_policy(package, policy)
      _ -> :ok
    end
  end

  defp enforce_github_policy(package, policy) do
    if policy.require_gpg_for_github and is_nil(package.gpg_verified_at) do
      {:error, :verification_required}
    else
      :ok
    end
  end

  defp enforce_upload_policy(package, policy) do
    if policy.allow_unsigned_uploads do
      :ok
    else
      if signature_present?(package.signature) do
        :ok
      else
        {:error, :signature_required}
      end
    end
  end

  defp signature_present?(%{} = sig), do: map_size(sig) > 0
  defp signature_present?(_), do: false

  defp plugin_verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      allow_unsigned_uploads: Keyword.get(config, :allow_unsigned_uploads, true)
    }
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, value) when value == [], do: attrs
  defp maybe_put(attrs, _key, value) when value == %{}, do: attrs

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

  defp normalize_source_type(nil), do: :upload
  defp normalize_source_type(""), do: :upload
  defp normalize_source_type(:upload), do: :upload
  defp normalize_source_type(:github), do: :github

  defp normalize_source_type(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "github" -> :github
      "upload" -> :upload
      "" -> :upload
      _ -> :invalid
    end
  end

  defp normalize_source_type(_), do: :invalid
end
