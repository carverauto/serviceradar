defmodule ServiceRadar.Automation.Ansible.PlaybookRepository do
  @moduledoc """
  Git repository registered as an Ansible playbook catalog source.

  Catalog repos generally live on github/gitlab.com (reachable from the SaaS
  plane), so the GitCatalogSyncWorker clones / pulls them in Elixir rather
  than via a plugin. See `GitCatalogSyncWorker` for supported repository access;
  the public configuration contract is documented in
  `docs/docs/ansible-provisioning-api.md`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer],
    # The primary `:read` carries a `prepare build(select: ...)`, which trips
    # Ash's "primary read has preparations" warning (an error under
    # --warnings-as-errors). Both are intentional — same pattern as #4495.
    primary_read_warning?: false

  alias ServiceRadar.Automation.Ansible.Changes.ScheduleGitCatalogSync
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "ansible.repositories.manage"}
  @view_check {ActorHasPermission, permission: "ansible.catalog.view"}

  @public_fields [
    :name,
    :description,
    :git_url,
    :git_ref,
    :sync_interval_seconds,
    :credential_secret_id,
    :last_sync_at,
    :last_sync_status,
    :last_sync_summary,
    :parse_diagnostics,
    :metadata
  ]

  @public_read_fields [:id, :inserted_at, :updated_at | @public_fields]

  postgres do
    table "ansible_playbook_repositories"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :credential_secret, on_delete: :restrict
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_playbook_repository_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :retained_versions_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true

    ignore_attributes [
      :inserted_at,
      :updated_at,
      :last_sync_at,
      :last_sync_status,
      :last_sync_summary,
      :parse_diagnostics
    ]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :create_repository, action: :create
    define :update_repository, action: :update
    define :destroy_repository, action: :destroy
    define :record_sync, action: :record_sync
  end

  actions do
    defaults [:destroy]

    read :read do
      # Primary read so this resource loads via its inbound relationship
      # (`Playbook.repository`). See PlaybookRun.
      primary? true
      prepare build(select: @public_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    create :create do
      accept [
        :name,
        :description,
        :git_url,
        :git_ref,
        :sync_interval_seconds,
        :credential_secret_id,
        :metadata
      ]

      # Seed the first sync job — the worker only re-schedules itself from
      # perform/1, so without this a new repository never syncs.
      change ScheduleGitCatalogSync
    end

    update :update do
      accept [
        :name,
        :description,
        :git_url,
        :git_ref,
        :sync_interval_seconds,
        :credential_secret_id,
        :metadata
      ]

      change ScheduleGitCatalogSync
    end

    update :record_sync do
      description "GitCatalogSyncWorker reports the outcome of a sync pass"
      accept [:last_sync_status, :last_sync_summary, :parse_diagnostics]
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id], @view_check)
    action_type_with_permission([:create, :update, :destroy], @manage_check)
    action_with_permission([:record_sync], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing repository name (unique)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :git_url, :string do
      allow_nil? false
      public? true
      description "HTTPS git remote, e.g. https://github.com/example/playbooks.git"
    end

    attribute :git_ref, :string do
      allow_nil? false
      public? true
      default "main"
      description "Branch or tag to sync from"
    end

    attribute :sync_interval_seconds, :integer do
      allow_nil? false
      public? true
      default 600
      constraints min: 60
    end

    attribute :credential_secret_id, :uuid do
      allow_nil? true
      public? true
      description "Optional NetworkCredentialSecret for HTTPS deploy token (private repos)"
    end

    attribute :last_sync_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_sync_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :ok, :error]
    end

    attribute :last_sync_summary, :string do
      allow_nil? true
      public? true
      description "Operator-safe one-line summary of the most recent sync result"
    end

    attribute :parse_diagnostics, :map do
      allow_nil? false
      public? true
      default %{}
      description "Per-file parse diagnostics from the most recent sync"
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :credential_secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :credential_secret_id
      destination_attribute :id
    end
  end

  identities do
    identity :unique_name, [:name]
    identity :unique_url_ref, [:git_url, :git_ref]
  end
end
