defmodule ServiceRadar.Plugins.PluginRepository do
  @moduledoc """
  A source the deployment imports signed Wasm plugin packages from.

  Replaces the single `:first_party_plugin_import` `:repo_url` config value, so
  a deployment can subscribe to third-party catalogs alongside the first-party
  one. Every import resolves a row here -- including the built-in
  `carverauto/serviceradar` source, which is seeded by migration precisely so
  there is one code path rather than "configured default or user-added".

  ## Trust

  Each repository carries its own ed25519 trusted signing key. That is the whole
  point of the record: `UploadSignature` verification runs against *this
  repository's* key, so a bundle signed by one publisher cannot be imported
  through another's source. `signing_key_id` and `signing_public_key` are
  therefore required -- a repository without them could never import anything,
  and failing at create time puts that in front of a human.

  ## The built-in row

  `builtin: true` rows are seeded, not authored. They reject `:update` and
  `:destroy` so the first-party trust anchor cannot be edited into pointing
  somewhere else or deleted by accident, but they accept `:enable`/`:disable`
  because "stop importing from upstream" is a legitimate operator decision.

  ## Credentials

  A private repository references a `NetworkCredentialSecret` holding a GitHub
  PAT (`credential_kind: :api_token`). The token is never an attribute here: it
  is resolved at fetch time so it cannot leak through a read, a calculation, or
  an audit record.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Plugins.PluginRepositoryNotifier]

  alias ServiceRadar.Plugins.Changes.NormalizeRepoUrl
  alias ServiceRadar.Plugins.Changes.RejectBuiltinRepository
  alias ServiceRadar.Plugins.Validations.RepositoryCredentialKind
  alias ServiceRadar.Plugins.Validations.RepositorySource

  require Ash.Query

  @writable_fields [
    :name,
    :repo_url,
    :index_asset_name,
    :signing_key_id,
    :signing_public_key,
    :credential_secret_id,
    :enabled
  ]

  @default_index_asset "serviceradar-wasm-plugin-index.json"

  postgres do
    table "plugin_repositories"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :credential_secret, on_delete: :restrict
    end

    # The identity has to name the index the migration actually created. Ash
    # otherwise derives "plugin_repositories_unique_repo_url_index", which
    # matches nothing in Postgres, so the violation still escapes as a raw
    # Ecto.ConstraintError - the identity looks declared and changes nothing.
    identity_index_names unique_repo_url: "plugin_repositories_repo_url_index"
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :get_default, action: :default
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      description "Repositories eligible for import and recurring sync"
      filter expr(enabled == true)
    end

    read :default do
      description "The repository preselected in the catalog picker"
      get? true
      filter expr(is_default == true)
    end

    read :by_repo_url do
      argument :repo_url, :string, allow_nil?: false
      get? true
      filter expr(repo_url == ^arg(:repo_url))
    end

    create :create do
      accept @writable_fields

      change NormalizeRepoUrl
      validate RepositorySource
      validate RepositoryCredentialKind
    end

    update :update do
      accept @writable_fields

      change NormalizeRepoUrl
      change RejectBuiltinRepository
      validate RepositorySource
      validate RepositoryCredentialKind
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end

    update :record_sync_success do
      description "Stamped by the sync worker so a stale source is visible"
      accept []
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
      change set_attribute(:last_sync_error, nil)
    end

    update :record_sync_error do
      accept [:last_sync_error]
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      change RejectBuiltinRepository
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    repositories_manage_action_types()
  end

  validations do
    validate present([:name, :repo_url, :signing_key_id, :signing_public_key]),
      on: [:create]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing label for the source"
    end

    attribute :repo_url, :string do
      allow_nil? false
      public? true
      description "https://github.com/<owner>/<repo>"
    end

    attribute :artifact_kind, :atom do
      allow_nil? false
      public? true
      default :wasm_plugin
      constraints one_of: [:wasm_plugin, :native_addon]

      description """
      Present so the native add-on catalog can adopt this table without a
      migration. Every row is :wasm_plugin today.
      """
    end

    attribute :index_asset_name, :string do
      allow_nil? false
      public? true
      default @default_index_asset
      description "Release asset holding the plugin index for this source"
    end

    attribute :signing_key_id, :string do
      allow_nil? false
      public? true
      description "key_id the publisher signs bundles with"
    end

    attribute :signing_public_key, :string do
      allow_nil? false
      public? true
      description "Base64 ed25519 public key verifying this source's bundles"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :builtin, :boolean do
      allow_nil? false
      public? true
      default false
      description "Seeded first-party source; not editable or removable"
    end

    attribute :is_default, :boolean do
      allow_nil? false
      public? true
      default false
      description "Preselected in the catalog picker; at most one row"
    end

    attribute :last_sync_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_sync_error, :string do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :credential_secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? true
      attribute_type :uuid
      public? true

      description """
      GitHub PAT for a private repository. The token itself is resolved at fetch
      time and never surfaces through this resource.
      """
    end

    belongs_to :created_by, ServiceRadar.Identity.User do
      allow_nil? true
      attribute_type :uuid
      public? true
    end
  end

  calculations do
    calculate :credential_attached?,
              :boolean,
              expr(not is_nil(credential_secret_id)) do
      public? true
      description "Whether a PAT is bound, without exposing it"
    end
  end

  identities do
    # The unique index has existed since 20260829200000; the resource never
    # declared it. Without the identity Ash cannot translate the violation, so
    # adding a second repository for a URL already registered raised a raw
    # Ecto.ConstraintError - a stack dump rendered into the modal, telling an
    # operator to call unique_constraint/3 rather than that the repository
    # already exists and can be edited.
    #
    # No pre_check?: AshPostgres enforces this through the existing unique index
    # and maps the violation itself. Adding one forced every update off the
    # atomic path and broke :disable/:enable/:record_sync, which are declared
    # atomic - a pre-check is for identities the data layer cannot enforce, and
    # this one it can.
    identity :unique_repo_url, [:repo_url] do
      message "a plugin repository for this URL already exists; edit that one instead"
    end
  end
end
