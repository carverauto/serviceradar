defmodule ServiceRadar.Automation.Ansible.Playbook do
  @moduledoc """
  Polymorphic Ansible playbook catalog entry.

  `source_type = :git` entries are produced by GitCatalogSyncWorker walking
  a `PlaybookRepository`; metadata comes from parsing the YAML, and a
  separate AWX Job Template binding (`awx_job_template_id` on the entry's
  controller) is required before the playbook is launchable.

  `source_type = :awx` entries are produced by AwxCatalogSyncWorker mirroring
  AWX Job Templates. A parse-valid AWX row with a job-template ID is only a
  launch candidate; current immutable binding and exact target membership are
  resolved separately before launch.

  See openspec change `add-ansible-integration` for the full design.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.catalog.view"}
  @launch_check {ActorHasPermission, permission: "ansible.runs.launch"}
  @manage_check {ActorHasPermission, permission: "ansible.repositories.manage"}

  @public_fields [
    :source_type,
    :name,
    :description,
    :path,
    :tags,
    :hosts_pattern,
    :declared_vars,
    :vars_prompt,
    :survey_spec,
    :awx_job_template_id,
    :parse_status,
    :parse_diagnostics,
    :metadata
  ]

  @public_read_fields [
    :id,
    :repository_id,
    :controller_id,
    :inserted_at,
    :updated_at | @public_fields
  ]

  @launch_read_fields [
    :id,
    :source_type,
    :name,
    :controller_id,
    :awx_job_template_id,
    :parse_status
  ]

  postgres do
    table "ansible_playbooks"
    repo ServiceRadar.Repo
    schema "platform"

    identity_wheres_to_sql unique_git_path: "source_type = 'git'",
                           unique_awx_template: "source_type = 'awx'"

    references do
      reference :repository, on_delete: :delete
      reference :controller, on_delete: :delete
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "ansible_playbook_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :parse_diagnostics]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_repository, action: :by_repository, args: [:repository_id]
    define :list_by_controller, action: :by_controller, args: [:controller_id]
    define :list_launchable, action: :launchable
    define :get_launch_candidate_by_id, action: :launch_candidate_by_id, args: [:id]
    define :upsert_git, action: :upsert_git
    define :upsert_awx, action: :upsert_awx
    define :destroy_playbook, action: :destroy
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      prepare build(select: @public_read_fields)
    end

    # Canonical launch-candidate read shared by the device panel and launch page.
    # It exposes only parse-valid AWX rows with a job-template ID; the secure
    # resolver still requires a current approved binding and exact memberships.
    read :launchable do
      description "AWX-launchable playbooks, optionally scoped to one controller"
      argument :controller_id, :uuid, allow_nil?: true

      filter expr(
               source_type == :awx and parse_status == :ok and
                 not is_nil(awx_job_template_id) and
                 (is_nil(^arg(:controller_id)) or controller_id == ^arg(:controller_id))
             )

      prepare build(select: @launch_read_fields, sort: [name: :asc], limit: 200)
    end

    read :launch_candidate_by_id do
      argument :id, :uuid, allow_nil?: false
      get? true

      filter expr(
               id == ^arg(:id) and source_type == :awx and parse_status == :ok and
                 not is_nil(awx_job_template_id)
             )

      prepare build(select: @launch_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    read :by_repository do
      argument :repository_id, :uuid, allow_nil?: false
      filter expr(repository_id == ^arg(:repository_id))
      prepare build(select: @public_read_fields)
    end

    read :by_controller do
      argument :controller_id, :uuid, allow_nil?: false
      filter expr(controller_id == ^arg(:controller_id))
      prepare build(select: @public_read_fields)
    end

    create :upsert_git do
      description "GitCatalogSyncWorker upsert: source_type = :git"
      upsert? true
      upsert_identity :unique_git_path

      accept [
        :name,
        :description,
        :path,
        :tags,
        :hosts_pattern,
        :declared_vars,
        :vars_prompt,
        :awx_job_template_id,
        :parse_status,
        :parse_diagnostics,
        :metadata
      ]

      argument :repository_id, :uuid, allow_nil?: false
      change set_attribute(:repository_id, arg(:repository_id))
      change set_attribute(:source_type, :git)
    end

    create :upsert_awx do
      description "AwxCatalogSyncWorker upsert: source_type = :awx"
      upsert? true
      upsert_identity :unique_awx_template

      accept [
        :name,
        :description,
        :tags,
        :hosts_pattern,
        :survey_spec,
        :awx_job_template_id,
        :parse_status,
        :metadata
      ]

      argument :controller_id, :uuid, allow_nil?: false
      change set_attribute(:controller_id, arg(:controller_id))
      change set_attribute(:source_type, :awx)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission([:read, :by_id, :by_repository, :by_controller], @view_check)

    policy action([:launchable, :launch_candidate_by_id]) do
      authorize_if @view_check
      authorize_if @launch_check
    end

    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  validations do
    validate fn changeset, _context ->
      source_type = Ash.Changeset.get_attribute(changeset, :source_type)
      repository_id = Ash.Changeset.get_attribute(changeset, :repository_id)
      controller_id = Ash.Changeset.get_attribute(changeset, :controller_id)

      case source_type do
        :git when not is_nil(repository_id) and is_nil(controller_id) ->
          :ok

        :awx when not is_nil(controller_id) and is_nil(repository_id) ->
          :ok

        nil ->
          :ok

        _ ->
          {:error,
           field: :source_type,
           message:
             "git source requires repository_id and not controller_id; " <>
               "awx source requires controller_id and not repository_id"}
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:git, :awx]
      description "Where this catalog entry originated"
    end

    attribute :repository_id, :uuid do
      allow_nil? true
      public? true
      description "PlaybookRepository for git-sourced entries; null for awx-sourced"
    end

    attribute :controller_id, :uuid do
      allow_nil? true
      public? true
      description "Controller for awx-sourced entries; null for git-sourced"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :path, :string do
      allow_nil? true
      public? true
      description "Repo-relative file path for git-sourced entries"
    end

    attribute :tags, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :hosts_pattern, :string do
      allow_nil? true
      public? true
      description "Ansible `hosts:` pattern declared in the playbook"
    end

    attribute :declared_vars, :map do
      allow_nil? false
      public? true
      default %{}
      description "Top-level vars parsed from the playbook YAML (git-sourced)"
    end

    attribute :vars_prompt, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "vars_prompt entries parsed from the playbook (git-sourced)"
    end

    attribute :survey_spec, :map do
      allow_nil? false
      public? true
      default %{}
      description "AWX Job Template survey_spec (awx-sourced)"
    end

    attribute :awx_job_template_id, :integer do
      allow_nil? true
      public? true
      description "AWX Job Template ID; required for launchability"
    end

    attribute :parse_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :ok, :error]
    end

    attribute :parse_diagnostics, :map do
      allow_nil? false
      public? true
      default %{}
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
    belongs_to :repository, ServiceRadar.Automation.Ansible.PlaybookRepository do
      attribute_writable? false
      public? true
      define_attribute? false
      source_attribute :repository_id
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      attribute_writable? false
      public? true
      define_attribute? false
      source_attribute :controller_id
    end
  end

  identities do
    identity :unique_git_path, [:repository_id, :path] do
      where expr(source_type == :git)
    end

    identity :unique_awx_template, [:controller_id, :awx_job_template_id] do
      where expr(source_type == :awx)
    end
  end
end
