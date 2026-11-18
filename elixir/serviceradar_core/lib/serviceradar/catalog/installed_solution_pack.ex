defmodule ServiceRadar.Catalog.InstalledSolutionPack do
  @moduledoc """
  Tracks installed Solution Packs (`platform.installed_solution_packs`), storing
  provenance, resolved typed `config` values, materialized resource inventory,
  GitOps commit/branch/PR metadata, and deployment-local credential slot bindings.
  """

  use Ash.Resource,
    domain: ServiceRadar.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Catalog.CatalogNotifier],
    primary_read_warning?: false

  alias ServiceRadar.Catalog.CatalogRepository
  alias ServiceRadar.Catalog.InstalledSolutionPackCredentialBinding
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "catalog.view"}
  @install_check {ActorHasPermission, permission: "catalog.packs.install"}
  @export_check {ActorHasPermission, permission: "catalog.packs.export"}
  @sync_check {ActorHasPermission, permission: "catalog.gitops.sync"}

  @pack_id_regex ~r/\A[a-z][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\z/
  @slug_regex ~r/\A[a-z0-9][a-z0-9-]{0,126}\z/

  @create_fields [
    :pack_id,
    :slug,
    :name,
    :pack_version,
    :description,
    :categories,
    :icon,
    :source_type,
    :catalog_repository_id,
    :source_commit_sha,
    :source_release_tag,
    :source_branch,
    :source_pr_url,
    :content_hash,
    :config_values,
    :resource_manifest,
    :manifest_snapshot,
    :installed_at,
    :upgraded_at,
    :last_synced_at
  ]

  @update_fields List.delete(@create_fields, :pack_id)

  postgres do
    table "installed_solution_packs"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_pack_id: "installed_solution_packs_pack_id_uidx",
                         unique_slug: "installed_solution_packs_slug_uidx"

    custom_indexes do
      index [:catalog_repository_id],
        where: "catalog_repository_id IS NOT NULL",
        name: "installed_solution_packs_repository_idx"
    end

    references do
      reference :catalog_repository,
        on_delete: :nilify,
        name: "installed_solution_packs_catalog_repository_id_fkey"
    end

    check_constraints do
      check_constraint :pack_id, "installed_solution_packs_valid_contract",
        check: """
        btrim(pack_id) <> '' AND
        btrim(slug) <> '' AND
        btrim(name) <> '' AND
        btrim(pack_version) <> '' AND
        source_type IN ('builtin', 'release_catalog', 'gitops_tree', 'upload')
        """
    end
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_pack_id, action: :by_pack_id, args: [:pack_id]
    define :get_by_slug, action: :by_slug, args: [:slug]
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      prepare build(sort: [name: :asc, pack_id: :asc])
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_pack_id do
      argument :pack_id, :string, allow_nil?: false
      get? true
      filter expr(pack_id == ^arg(:pack_id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    create :create do
      primary? true
      accept @create_fields
    end

    update :update do
      primary? true
      accept @update_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @install_check
      authorize_if @export_check
      authorize_if @sync_check
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if @install_check
      authorize_if @sync_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :pack_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 3, max_length: 255, match: @pack_id_regex
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128, match: @slug_regex
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :pack_version, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 64
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 4_096
    end

    attribute :categories, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :icon, :string do
      allow_nil? true
      public? true
    end

    attribute :source_type, :atom do
      allow_nil? false
      default :builtin
      public? true
      constraints one_of: [:builtin, :release_catalog, :gitops_tree, :upload]
    end

    attribute :catalog_repository_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :source_commit_sha, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :source_release_tag, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :source_branch, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :source_pr_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 512
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
      constraints max_length: 128
    end

    attribute :config_values, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :resource_manifest, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :manifest_snapshot, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :installed_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :upgraded_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_synced_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :catalog_repository, CatalogRepository do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :catalog_repository_id
    end

    has_many :credential_bindings, InstalledSolutionPackCredentialBinding do
      destination_attribute :installed_pack_id
      public? true
    end
  end

  identities do
    identity :unique_pack_id, [:pack_id]
    identity :unique_slug, [:slug]
  end
end
