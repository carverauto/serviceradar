defmodule ServiceRadar.Automation.Ansible.AutomationOperation do
  @moduledoc """
  Immutable authorization and target ceiling for one requested automation operation.

  The operation is the parent of one or more inventory-bound AWX executions.
  It records the initiating principal separately from any system transport
  worker and stores only reviewed public/internal launch inputs.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}
  @cancel_check {ActorHasPermission, permission: "ansible.runs.cancel"}

  # History surfaces deliberately receive a narrow projection. In particular,
  # authority ceilings, approval/input snapshots, callback policy, budgets,
  # and metadata never enter LiveView state.
  @history_read_fields [
    :id,
    :action,
    :state,
    :mutating,
    :check_mode,
    :initiator_principal_type,
    :initiator_principal_id,
    :request_source,
    :target_digest,
    :diagnostics,
    :started_at,
    :ended_at,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "ansible_automation_operations"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      # Multi-column pair: either all empty (legacy) or full attestation together.
      check_constraint :preflight_evidence_id,
                       "ansible_automation_operations_preflight_snapshot_pair",
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
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_history_by_id, action: :history_by_id, args: [:id]
    define :list_history_by_ids, action: :history_by_ids, args: [:ids]
    define :list_history, action: :history
    define :list_active, action: :active
    define :create_operation, action: :create
    define :record_state, action: :record_state
    define :request_cancel, action: :request_cancel
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
      description "Secret-safe operation projection for human run history"
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @history_read_fields)
    end

    read :history_by_ids do
      description "Secret-safe operation projections for device history joins"
      argument :ids, {:array, :uuid}, allow_nil?: false
      filter expr(id in ^arg(:ids))
      prepare build(select: @history_read_fields)
    end

    read :history do
      description "Recent secret-safe operation history, optionally filtered by state"

      argument :state, :atom do
        allow_nil? true

        constraints one_of: [
                      :planned,
                      :dispatching,
                      :running,
                      :succeeded,
                      :failed,
                      :canceled,
                      :dispatch_partial,
                      :dispatch_ambiguous,
                      :cancel_failed
                    ]
      end

      filter expr(is_nil(^arg(:state)) or state == ^arg(:state))
      prepare build(select: @history_read_fields, sort: [inserted_at: :desc], limit: 100)
    end

    read :active do
      filter expr(state in [:planned, :dispatching, :running, :dispatch_partial, :cancel_failed])
      prepare build(sort: [inserted_at: :asc])
    end

    create :create do
      primary? true

      accept [
        :tenant_id,
        :action,
        :mutating,
        :check_mode,
        :initiator_principal_type,
        :initiator_principal_id,
        :service_principal_owner_id,
        :authorization_version,
        :authority_ceiling,
        :approval_snapshot,
        :request_source,
        :declared_inputs,
        :input_classifications,
        :input_digest,
        :target_digest,
        :callback_actions,
        :run_budget,
        :preflight_evidence_id,
        :immutable_launch_snapshot,
        :immutable_launch_snapshot_digest,
        :metadata
      ]
    end

    update :record_state do
      require_atomic? false
      accept [:state, :started_at, :ended_at, :diagnostics, :metadata]
    end

    update :request_cancel do
      require_atomic? false
      accept [:diagnostics, :metadata]
      change set_attribute(:state, :canceled)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :history_by_id, :history_by_ids, :history, :active],
      @view_check
    )

    action_with_permission([:request_cancel], @cancel_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :tenant_id, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      default :planned
      public? true

      constraints one_of: [
                    :planned,
                    :dispatching,
                    :running,
                    :succeeded,
                    :failed,
                    :canceled,
                    :dispatch_partial,
                    :dispatch_ambiguous,
                    :cancel_failed
                  ]
    end

    attribute :mutating, :boolean, allow_nil?: false, default: true, public?: true
    attribute :check_mode, :boolean, allow_nil?: false, default: false, public?: true

    attribute :initiator_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :initiator_principal_id, :string, allow_nil?: false, public?: true
    attribute :service_principal_owner_id, :string, allow_nil?: true, public?: true
    attribute :authorization_version, :string, allow_nil?: false, public?: true
    attribute :authority_ceiling, :map, allow_nil?: false, public?: true
    attribute :approval_snapshot, :map, allow_nil?: false, default: %{}, public?: true
    attribute :request_source, :string, allow_nil?: false, public?: true
    attribute :declared_inputs, :map, allow_nil?: false, default: %{}, public?: true
    attribute :input_classifications, :map, allow_nil?: false, default: %{}, public?: true
    attribute :input_digest, :string, allow_nil?: false, public?: true
    attribute :target_digest, :string, allow_nil?: false, public?: true
    attribute :callback_actions, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :run_budget, :map, allow_nil?: false, default: %{}, public?: true

    # These fields are deliberately separate from mutable metadata. They are
    # set only by the create action after a successful live AWX preflight, and
    # the child execution stores an identical copy for cross-checking before
    # dispatch. Empty/nil values represent legacy, non-launchable rows.
    attribute :preflight_evidence_id, :uuid, allow_nil?: true, public?: false

    attribute :immutable_launch_snapshot, :map,
      allow_nil?: false,
      default: %{},
      public?: false

    attribute :immutable_launch_snapshot_digest, :string,
      allow_nil?: true,
      public?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :diagnostics, :map, allow_nil?: false, default: %{}, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    attribute :started_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :ended_at, :utc_datetime_usec, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :executions, ServiceRadar.Automation.Ansible.AutomationExecution do
      destination_attribute :operation_id
    end
  end
end
