defmodule ServiceRadar.Automation.Ansible.AutomationExecution do
  @moduledoc """
  One immutable, inventory-bound child execution of an automation operation.

  The row freezes content, execution environment, credential references,
  literal host limit, dispatch markers, and controller scope before AWX is
  contacted. AWX job IDs are unique only within their controller.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  # Excludes machine credential references/snapshots, accepted AWX snapshots,
  # callback references, and free-form metadata from all history consumers.
  @history_read_fields [
    :id,
    :operation_id,
    :controller_id,
    :inventory_id,
    :job_template_id,
    :project_id,
    :scm_revision,
    :content_sha256,
    :execution_environment_id,
    :check_mode,
    :host_limit,
    :dispatch_id,
    :snapshot_digest,
    :state,
    :awx_job_id,
    :scope_verified_at,
    :started_at,
    :ended_at,
    :diagnostics,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "ansible_automation_executions"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_dispatch: "ansible_automation_executions_dispatch_uidx",
                         unique_controller_job:
                           "ansible_automation_executions_controller_job_uidx"

    identity_wheres_to_sql unique_controller_job: "awx_job_id IS NOT NULL"

    check_constraints do
      # Multi-column pair: either all empty (legacy) or full attestation together.
      check_constraint :preflight_evidence_id,
                       "ansible_automation_executions_preflight_snapshot_pair",
                       check: """
                       (
                         preflight_evidence_id IS NULL
                         AND immutable_launch_snapshot_digest IS NULL
                         AND immutable_launch_snapshot = '{}'::jsonb
                       )
                       OR (
                         preflight_evidence_id IS NOT NULL
                         AND immutable_launch_snapshot_digest IS NOT NULL
                         AND immutable_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
                         AND jsonb_typeof(immutable_launch_snapshot) = 'object'
                         AND immutable_launch_snapshot <> '{}'::jsonb
                       )
                       """,
                       message:
                         "must retain a complete preflight-evidence ID, immutable launch snapshot, " <>
                           "and lowercase digest together"
    end

    references do
      reference :operation, on_delete: :delete
      reference :controller, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_history_by_id, action: :history_by_id, args: [:id]
    define :list_history_by_ids, action: :history_by_ids, args: [:ids]
    define :get_by_dispatch_id, action: :by_dispatch_id, args: [:dispatch_id]
    define :get_by_controller_job, action: :by_controller_job, args: [:controller_id, :awx_job_id]
    define :list_for_operation, action: :for_operation, args: [:operation_id]
    define :list_history_for_operation, action: :history_for_operation, args: [:operation_id]
    define :create_execution, action: :create
    define :record_state, action: :record_state
    define :bind_job, action: :bind_job
    define :record_scope_verified, action: :record_scope_verified
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :history_by_id do
      description "Secret-safe execution projection for human run history"
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @history_read_fields)
    end

    read :history_by_ids do
      description "Secret-safe execution projections for device history joins"
      argument :ids, {:array, :uuid}, allow_nil?: false
      filter expr(id in ^arg(:ids))
      prepare build(select: @history_read_fields)
    end

    read :by_dispatch_id do
      argument :dispatch_id, :uuid, allow_nil?: false
      get? true
      filter expr(dispatch_id == ^arg(:dispatch_id))
    end

    read :by_controller_job do
      argument :controller_id, :uuid, allow_nil?: false
      argument :awx_job_id, :integer, allow_nil?: false
      get? true
      filter expr(controller_id == ^arg(:controller_id) and awx_job_id == ^arg(:awx_job_id))
    end

    read :for_operation do
      argument :operation_id, :uuid, allow_nil?: false
      filter expr(operation_id == ^arg(:operation_id))
      prepare build(sort: [controller_id: :asc, inventory_id: :asc, inserted_at: :asc])
    end

    read :history_for_operation do
      description "Secret-safe child executions for an operation"
      argument :operation_id, :uuid, allow_nil?: false
      filter expr(operation_id == ^arg(:operation_id))

      prepare build(
                select: @history_read_fields,
                sort: [controller_id: :asc, inventory_id: :asc, inserted_at: :asc]
              )
    end

    create :create do
      primary? true

      accept [
        :operation_id,
        :controller_id,
        :inventory_id,
        :job_template_id,
        :project_id,
        :scm_revision,
        :content_sha256,
        :execution_environment_id,
        :machine_credential_id,
        :credential_snapshot,
        :check_mode,
        :host_limit,
        :dispatch_id,
        :snapshot_digest,
        :preflight_evidence_id,
        :immutable_launch_snapshot,
        :immutable_launch_snapshot_digest,
        :callback_reference,
        :metadata
      ]
    end

    update :record_state do
      require_atomic? false
      accept [:state, :started_at, :ended_at, :diagnostics, :metadata]
    end

    update :bind_job do
      require_atomic? false
      accept [:awx_job_id, :accepted_job_snapshot, :started_at, :diagnostics, :metadata]
      change set_attribute(:state, :launching)
    end

    update :record_scope_verified do
      require_atomic? false
      accept [:accepted_job_snapshot, :diagnostics, :metadata]
      change set_attribute(:state, :scope_verified)
      change set_attribute(:scope_verified_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [
        :read,
        :by_id,
        :history_by_id,
        :history_by_ids,
        :by_dispatch_id,
        :by_controller_job,
        :for_operation,
        :history_for_operation
      ],
      @view_check
    )
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true

    attribute :inventory_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :job_template_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :project_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :scm_revision, :string, allow_nil?: false, public?: true
    attribute :content_sha256, :string, allow_nil?: false, public?: true

    attribute :execution_environment_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :machine_credential_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :credential_snapshot, :map, allow_nil?: false, default: %{}, public?: true
    attribute :check_mode, :boolean, allow_nil?: false, default: false, public?: true
    attribute :host_limit, :string, allow_nil?: false, public?: true
    attribute :dispatch_id, :uuid, allow_nil?: false, public?: true
    attribute :snapshot_digest, :string, allow_nil?: false, public?: true

    # Attested preflight state never belongs in metadata because state updates
    # and dispatch recovery may amend metadata later. It is create-only on
    # this child and must exactly match the parent operation before launch.
    attribute :preflight_evidence_id, :uuid, allow_nil?: true, public?: false

    attribute :immutable_launch_snapshot, :map,
      allow_nil?: false,
      default: %{},
      public?: false

    attribute :immutable_launch_snapshot_digest, :string,
      allow_nil?: true,
      public?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :state, :atom do
      allow_nil? false
      default :planned
      public? true

      constraints one_of: [
                    :planned,
                    :dispatching,
                    :launching,
                    :scope_verified,
                    :running,
                    :succeeded,
                    :failed,
                    :canceled,
                    :dispatch_ambiguous,
                    :cancel_failed
                  ]
    end

    attribute :awx_job_id, :integer, allow_nil?: true, public?: true
    attribute :accepted_job_snapshot, :map, allow_nil?: false, default: %{}, public?: true
    attribute :scope_verified_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :callback_reference, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Opaque callback lifecycle reference; never a callback bearer or response"
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :ended_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :diagnostics, :map, allow_nil?: false, default: %{}, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :operation, ServiceRadar.Automation.Ansible.AutomationOperation do
      define_attribute? false
      source_attribute :operation_id
      public? true
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
      public? true
    end

    has_many :targets, ServiceRadar.Automation.Ansible.AutomationExecutionTarget do
      destination_attribute :execution_id
    end
  end

  identities do
    identity :unique_dispatch, [:dispatch_id]

    identity :unique_controller_job, [:controller_id, :awx_job_id],
      where: expr(not is_nil(awx_job_id))
  end
end
