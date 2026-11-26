defmodule ServiceRadar.Catalog do
  @moduledoc """
  Ash domain and top-level public facade for Solution Packs, Signed Release
  Catalogs, and Two-Way Private GitOps Synchronization (`1.1`-`1.5`, `2.1`-`2.6`,
  `3.1`-`3.4`).
  """

  use Ash.Domain, validate_config_inclusion?: false

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.NotFound
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.DependencyChecker
  alias ServiceRadar.Catalog.GitOpsTreeClient
  alias ServiceRadar.Catalog.InstalledSolutionPack
  alias ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  alias ServiceRadar.Catalog.PackArchive
  alias ServiceRadar.Catalog.PackExporter

  ## Catalog Repositories

  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Catalog.ReleaseCatalogClient
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  require Ash.Query

  resources do
    resource CatalogRepository
    resource InstalledSolutionPack
    resource InstalledSolutionPackCredentialBinding
  end

  @doc "Lists configured `CatalogRepository` records ordered with `builtin` first."
  @spec list_repositories(keyword()) :: {:ok, [CatalogRepository.t()]} | {:error, term()}
  def list_repositories(opts \\ []) when is_list(opts) do
    CatalogRepository.list(actor: extract_actor(opts))
  end

  @doc "Lists enabled `CatalogRepository` records."
  @spec list_enabled_repositories(keyword()) :: {:ok, [CatalogRepository.t()]} | {:error, term()}
  def list_enabled_repositories(opts \\ []) when is_list(opts) do
    CatalogRepository.list_enabled(actor: extract_actor(opts))
  end

  @doc "Fetches a `CatalogRepository` by UUID."
  @spec get_repository(String.t(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, :not_found | term()}
  def get_repository(id, opts \\ []) when is_binary(id) and is_list(opts) do
    case CatalogRepository.get_by_id(id, actor: extract_actor(opts)) do
      {:ok, %CatalogRepository{} = r} -> {:ok, r}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Invalid{errors: [%NotFound{} | _]}} -> {:error, :not_found}
      {:error, %NotFound{}} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Creates a `CatalogRepository` (`:release_catalog` or `:gitops_tree`)."
  @spec create_repository(map(), keyword()) :: {:ok, CatalogRepository.t()} | {:error, term()}
  def create_repository(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    actor = extract_actor(opts)

    CatalogRepository
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor)
  end

  @doc "Updates a non-built-in `CatalogRepository`."
  @spec update_repository(CatalogRepository.t(), map(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, term()}
  def update_repository(%CatalogRepository{} = repo, attrs, opts \\ [])
      when is_map(attrs) and is_list(opts) do
    actor = extract_actor(opts)

    repo
    ## Built-in & Installed Solution Packs
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update(actor: actor)
  end

  @doc "Enables a `CatalogRepository` (including the seeded built-in row)."
  @spec enable_repository(CatalogRepository.t(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, term()}
  def enable_repository(%CatalogRepository{} = repo, opts \\ []) when is_list(opts) do
    actor = extract_actor(opts)

    repo
    |> Ash.Changeset.for_update(:enable, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  @doc "Disables a `CatalogRepository` (including the seeded built-in row)."
  @spec disable_repository(CatalogRepository.t(), keyword()) ::
          {:ok, CatalogRepository.t()} | {:error, term()}
  def disable_repository(%CatalogRepository{} = repo, opts \\ []) when is_list(opts) do
    actor = extract_actor(opts)

    repo
    |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  @doc "Deletes a non-built-in `CatalogRepository`."
  ## Validation, Guided Installation, Upgrade, Export & Sync
  @spec delete_repository(CatalogRepository.t(), keyword()) :: :ok | {:error, term()}
  def delete_repository(%CatalogRepository{} = repo, opts \\ []) when is_list(opts) do
    Ash.destroy(repo, actor: extract_actor(opts))
  end

  @doc "Lists shipped offline built-in Solution Packs (`priv/solution_packs/*`)."
  @spec list_builtin_packs() :: {:ok, [map()]} | {:error, term()}
  def list_builtin_packs, do: BuiltinPacks.list_packs()

  @doc "Fetches a shipped built-in Solution Pack by `pack_id` or `slug`."
  @spec get_builtin_pack(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_builtin_pack(id_or_slug), do: BuiltinPacks.get_pack(id_or_slug)

  @doc "Lists `InstalledSolutionPack` records."
  @spec list_installed_packs(keyword()) :: {:ok, [InstalledSolutionPack.t()]} | {:error, term()}
  def list_installed_packs(opts \\ []) when is_list(opts) do
    InstalledSolutionPack.list(actor: extract_actor(opts))
  end

  @doc "Fetches an `InstalledSolutionPack` by `pack_id` or `slug`."
  @spec get_installed_pack(String.t(), keyword()) ::
          {:ok, InstalledSolutionPack.t()} | {:error, :not_found | term()}
  def get_installed_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    actor = extract_actor(opts)

    query =
      InstalledSolutionPack
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(pack_id == ^id_or_slug or slug == ^id_or_slug)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, %InstalledSolutionPack{} = p} -> {:ok, p}
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Validates a pack directory map or `.srpack`/`.zip` archive binary."
  @spec validate_pack(map() | binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_pack(archive_bytes, opts \\ [])

  def validate_pack(archive_bytes, opts) when is_binary(archive_bytes) do
    PackArchive.extract(archive_bytes, opts)
  end

  def validate_pack(file_map, opts) when is_map(file_map) do
    PackManifest.validate_pack_tree(file_map, opts)
  end

  @doc "Checks Wasm `plugin_dependencies` readiness against `PluginPackage`."
  @spec check_dependencies(map() | [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def check_dependencies(manifest_or_deps, opts \\ []) do
    DependencyChecker.check(manifest_or_deps, opts)
  end

  @doc "Computes a dry-run installation or upgrade preview."
  @spec preview_install(map() | binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_install(pack_or_bytes, params \\ %{}, opts \\ []) do
    with {:ok, validated} <- validate_pack(pack_or_bytes, opts) do
      Reconciler.preview(validated, params, opts)
    end
  end

  @doc "Installs or upgrades a Solution Pack atomically."
  @spec install_pack(map() | binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def install_pack(pack_or_bytes, params \\ %{}, opts \\ []) do
    with {:ok, validated} <- validate_pack(pack_or_bytes, opts) do
      Reconciler.reconcile(validated, params, opts)
    end
  end

  @doc "Uninstalls a Solution Pack by `pack_id` or `slug`, preserving `managed: false` resources."
  @spec uninstall_pack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def uninstall_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    Reconciler.uninstall(id_or_slug, opts)
  end

  @doc "Detaches a Solution Pack by `pack_id` or `slug`, setting `managed: false` on its resources."
  @spec detach_pack(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def detach_pack(id_or_slug, opts \\ []) when is_binary(id_or_slug) and is_list(opts) do
    Reconciler.detach(id_or_slug, opts)
  end

  @doc "Exports live resources into a secret-free `.srpack` archive (requires `catalog.packs.export`)."
  @spec export_pack_archive(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def export_pack_archive(spec, opts \\ []) do
    with :ok <- authorize_permission(opts, "catalog.packs.export") do
      PackExporter.export_archive(spec, Keyword.put_new(opts, :emit_audit, true))
    end
  end

  @doc "Exports live resources into a secret-free `pack_format_version: 1` file map (requires `catalog.packs.export`)."
  @spec export_pack_tree(map(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def export_pack_tree(spec, opts \\ []) do
    with :ok <- authorize_permission(opts, "catalog.packs.export") do
      PackExporter.export_tree(spec, Keyword.put_new(opts, :emit_audit, true))
    end
  end

  @doc "Pushes a Solution Pack to a `:gitops_tree` `CatalogRepository` (requires `catalog.gitops.sync`)."
  @spec push_to_gitops(CatalogRepository.t() | map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def push_to_gitops(repo, pack_or_spec, opts \\ []) do
    with :ok <- authorize_permission(opts, "catalog.gitops.sync") do
      GitOpsTreeClient.push_pack(repo, pack_or_spec, opts)
    end
  end

  @doc "Imports and verifies a signed `.srpack` from a `:release_catalog` `CatalogRepository`."
  @spec fetch_from_release_catalog(CatalogRepository.t() | map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_from_release_catalog(repo, id_or_slug, opts \\ []) do
    with :ok <- authorize_permission(opts, "catalog.packs.install") do
      ReleaseCatalogClient.fetch_and_verify_pack(
        repo,
        id_or_slug,
        Keyword.put_new(opts, :emit_audit, true)
      )
    end
  end

  @doc false
  @spec extract_actor(keyword()) :: map() | nil
  def extract_actor(opts) when is_list(opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        case Keyword.get(opts, :scope) do
          %{user: user, permissions: %MapSet{} = perms} when is_map(user) ->
            user
            |> Map.take([:id, :email, :role, :role_profile_id])
            |> Map.put(:permissions, perms)

          %{actor: actor, permissions: %MapSet{} = perms} when is_map(actor) ->
            actor
            |> Map.take([:id, :email, :role, :role_profile_id])
            |> Map.put(:permissions, perms)

          %{user: user} when not is_nil(user) ->
            user

          %{actor: actor} when not is_nil(actor) ->
            actor

          _ ->
            nil
        end

      actor ->
        actor
    end
  end

  defp authorize_permission(opts, perm) do
    case extract_actor(opts) do
      nil ->
        {:error, Forbidden.exception([])}

      %{role: :system} ->
        :ok

      actor ->
        if ActorHasPermission.match?(actor, [permission: perm], %{}) do
          :ok
        else
          {:error, Forbidden.exception([])}
        end
    end
  end
end
