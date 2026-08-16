defmodule ServiceRadarWebNG.Plugins.AddonPackages do
  @moduledoc """
  Context module for native add-on (feature set) packages (issue 3425).

  Thin wrapper over the serviceradar_core ServiceRadar.Plugins.AddonPackage Ash
  resource, threading the authenticated scope into Ash for authorization. Add-ons
  have no Wasm blob / upload / import flow, so this is much smaller than the
  Wasm Packages context.
  """

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.Plugins.NativeAddonSync

  require Ash.Query

  @default_limit 100
  @max_limit 500

  @spec list(map(), keyword()) :: [AddonPackage.t()]
  def list(filters \\ %{}, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    limit = normalize_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    AddonPackage
    |> Ash.Query.for_read(:read)
    |> maybe_filter_status(filters)
    |> Ash.Query.limit(limit)
    |> Ash.Query.sort(inserted_at: :desc)
    |> read(scope)
  end

  @spec list_approved(keyword()) :: [AddonPackage.t()]
  def list_approved(opts \\ []), do: list(%{status: :approved}, opts)

  @spec list_approved_latest(keyword()) :: [AddonPackage.t()]
  def list_approved_latest(opts \\ []), do: list_latest_versions(%{status: :approved}, opts)

  @spec list_latest_versions(map(), keyword()) :: [AddonPackage.t()]
  def list_latest_versions(filters \\ %{}, opts \\ []) do
    filters
    |> Map.put_new(:limit, @max_limit)
    |> list(opts)
    |> latest_package_per_addon()
    |> Enum.sort_by(&package_sort_key/1)
  end

  @spec sync_first_party_addons(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_first_party_addons(opts \\ []) do
    repo_url = Keyword.get(opts, :repo_url)
    limit = Keyword.get(opts, :limit, 10)
    release_tag = Keyword.get(opts, :release_tag)

    discovery_attrs = maybe_put(%{}, :repo_url, repo_url)

    with {:ok, addons} <- NativeAddonImporter.list_recent_addons(discovery_attrs, limit) do
      candidates =
        NativeAddonSync.candidates(addons, release_tag: release_tag)

      decision_opts = Keyword.take(opts, [:scope, :actor])

      results =
        Enum.map(candidates, fn addon ->
          {addon, NativeAddonSync.import_or_reuse(addon, decision_opts)}
        end)

      {:ok, NativeAddonSync.summary(addons, results)}
    end
  end

  @spec import_first_party_addon(map(), keyword()) ::
          {:ok, AddonPackage.t(), :imported | :skipped} | {:error, term()}
  def import_first_party_addon(addon, opts \\ [])

  def import_first_party_addon(addon, opts) when is_map(addon) do
    case NativeAddonSync.candidates([addon]) do
      [candidate] ->
        case NativeAddonSync.import_or_reuse(
               candidate,
               Keyword.take(opts, [:scope, :actor, :auto_approve_addon_ids, :replace])
             ) do
          {:imported, package} -> {:ok, package, :imported}
          {:skipped, package} -> {:ok, package, :skipped}
          {:error, _reason} = error -> error
        end

      [] ->
        {:error, :native_addon_not_import_ready}
    end
  end

  def import_first_party_addon(_addon, _opts), do: {:error, :invalid_attributes}

  @spec approve(String.t(), map(), keyword()) :: {:ok, AddonPackage.t()} | {:error, term()}
  def approve(id, attrs, opts \\ [])

  def approve(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    with {:ok, package} <- get(id, scope: scope) do
      attrs =
        attrs
        |> drop_nil_values()
        |> maybe_put(:approved_by, Keyword.get(opts, :approved_by))

      package
      |> Ash.Changeset.for_update(:approve, attrs)
      |> Ash.update(ash_opts(scope, actor))
      |> refresh_contract_index()
    end
  end

  def approve(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  # See `ServiceRadarWebNG.Plugins.Packages.refresh_contract_index/1`: approval
  # is what makes an add-on's display contracts visible to the runtime index.
  defp refresh_contract_index({:ok, _package} = result) do
    ContractRegistry.refresh_async()
    result
  end

  defp refresh_contract_index(result), do: result

  @spec deny(String.t(), map(), keyword()) :: {:ok, AddonPackage.t()} | {:error, term()}
  def deny(id, attrs, opts \\ [])

  def deny(id, attrs, opts) when is_binary(id) and is_map(attrs) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor)

    with {:ok, package} <- get(id, scope: scope) do
      package
      |> Ash.Changeset.for_update(:deny, drop_nil_values(attrs))
      |> Ash.update(ash_opts(scope, actor))
    end
  end

  def deny(_id, _attrs, _opts), do: {:error, :invalid_attributes}

  @spec get(String.t(), keyword()) ::
          {:ok, AddonPackage.t()} | {:error, :not_found} | {:error, term()}
  def get(id, opts \\ [])

  def get(id, opts) when is_binary(id) do
    scope = Keyword.get(opts, :scope)

    case read_one(id, scope) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package}
      {:error, error} -> {:error, error}
    end
  end

  def get(_id, _opts), do: {:error, :not_found}

  defp read(query, nil), do: Ash.read!(query)
  defp read(query, scope), do: Ash.read!(query, ash_opts(scope, nil))

  defp read_one(id, nil) do
    AddonPackage |> Ash.Query.for_read(:read) |> Ash.Query.filter(id == ^id) |> Ash.read_one()
  end

  defp read_one(id, scope) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(ash_opts(scope, nil))
  end

  defp latest_package_per_addon(packages) do
    packages
    |> Enum.reduce(%{}, fn %AddonPackage{} = package, acc ->
      Map.update(acc, package.addon_id, package, &newer_package(&1, package))
    end)
    |> Map.values()
  end

  defp newer_package(%AddonPackage{} = left, %AddonPackage{} = right) do
    case compare_versions(left.version, right.version) do
      :lt -> right
      :gt -> left
      :eq -> newer_by_timestamp(left, right)
    end
  end

  defp compare_versions(left, right) when is_binary(left) and is_binary(right) do
    Version.compare(left, right)
  rescue
    Version.InvalidVersionError ->
      compare_fallback_versions(left, right)
  end

  defp compare_versions(left, right), do: compare_fallback_versions(to_string(left), to_string(right))

  defp compare_fallback_versions(left, right) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp newer_by_timestamp(%AddonPackage{} = left, %AddonPackage{} = right) do
    case DateTime.compare(timestamp_sort_key(left), timestamp_sort_key(right)) do
      :lt -> right
      _ -> left
    end
  end

  defp timestamp_sort_key(%AddonPackage{} = package) do
    package.updated_at || package.imported_at || package.inserted_at || ~U[1970-01-01 00:00:00Z]
  end

  defp package_sort_key(%AddonPackage{} = package) do
    {package.name |> to_string() |> String.downcase(), package.addon_id || ""}
  end

  defp ash_opts(scope, actor) when not is_nil(scope) do
    maybe_put_actor([scope: scope], actor || scope_actor(scope))
  end

  defp ash_opts(_scope, actor) when not is_nil(actor), do: [actor: actor]
  defp ash_opts(_scope, _actor), do: []

  defp maybe_put_actor(opts, nil), do: opts
  defp maybe_put_actor(opts, actor), do: Keyword.put(opts, :actor, actor)

  defp scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp maybe_filter_status(query, filters) do
    case status_atom(Map.get(filters, :status) || Map.get(filters, "status")) do
      nil -> query
      status -> Ash.Query.filter(query, status == ^status)
    end
  end

  defp status_atom(status) when is_atom(status) and not is_nil(status), do: status

  defp status_atom(status) when is_binary(status) and status != "" do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp status_atom(_status), do: nil

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp drop_nil_values(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
