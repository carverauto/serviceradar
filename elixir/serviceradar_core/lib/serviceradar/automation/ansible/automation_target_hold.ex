defmodule ServiceRadar.Automation.Ansible.AutomationTargetHold do
  @moduledoc """
  Device-wide quarantine for an uncertain or failed AWX-backed mutation.

  A hold is keyed to the canonical device rather than one AWX membership, so a
  later launch cannot bypass quarantine by selecting another inventory. Only an
  attributable principal with exact `ansible.targets.holds.clear` may clear it,
  and the clear action requires approval, current-policy, and reconciliation
  evidence.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.Changes.StampTargetHoldClearance
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}
  @clear_check {ActorHasPermission, permission: "ansible.targets.holds.clear"}

  @history_read_fields [
    :id,
    :canonical_device_uid,
    :trigger_execution_target_id,
    :transaction_id,
    :generation,
    :trigger_phase,
    :reason,
    :policy_digest,
    :evidence_digest,
    :active,
    :held_at,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "ansible_automation_target_holds"
    repo ServiceRadar.Repo
    schema "platform"

    identity_wheres_to_sql one_active_hold_per_device: "active = true"

    identity_index_names one_active_hold_per_device:
                           "ansible_automation_target_holds_active_device_uidx"

    references do
      reference :canonical_device, on_delete: :restrict
      reference :trigger_membership, on_delete: :restrict
      reference :trigger_execution_target, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    # Active-hold reads are optional lookups: no row is a valid "not held" answer,
    # not a hard NotFound. Callers treat {:ok, nil} as clear.
    define :get_active_for_device,
      action: :active_for_device,
      args: [:canonical_device_uid],
      not_found_error?: false

    define :get_active_history_for_device,
      action: :active_history_for_device,
      args: [:canonical_device_uid],
      not_found_error?: false

    define :list_for_device, action: :for_device, args: [:canonical_device_uid]
    define :place_hold, action: :place_hold

    define :clear_hold,
      action: :clear,
      args: [:approval_id, :current_policy_digest, :reconciliation_evidence]
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

    read :active_for_device do
      argument :canonical_device_uid, :string, allow_nil?: false
      get? true
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid) and active == true)
    end

    read :active_history_for_device do
      description "Secret-safe active hold evidence for a history surface"
      argument :canonical_device_uid, :string, allow_nil?: false
      get? true
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid) and active == true)
      prepare build(select: @history_read_fields)
    end

    read :for_device do
      argument :canonical_device_uid, :string, allow_nil?: false
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid))
      prepare build(sort: [held_at: :desc])
    end

    create :place_hold do
      primary? true

      accept [
        :canonical_device_uid,
        :trigger_membership_id,
        :trigger_execution_target_id,
        :transaction_id,
        :generation,
        :trigger_phase,
        :reason,
        :policy_digest,
        :evidence_digest,
        :held_at,
        :diagnostics,
        :metadata
      ]
    end

    update :clear do
      require_atomic? false
      accept []

      argument :approval_id, :uuid, allow_nil?: false

      argument :current_policy_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 512]

      argument :reconciliation_evidence, :map, allow_nil?: false

      change StampTargetHoldClearance
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :active_for_device, :active_history_for_device, :for_device],
      @view_check
    )

    action_with_permission([:clear], @clear_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :canonical_device_uid, :string, allow_nil?: false, public?: true
    attribute :trigger_membership_id, :uuid, allow_nil?: false, public?: true
    attribute :trigger_execution_target_id, :uuid, allow_nil?: false, public?: true
    attribute :transaction_id, :uuid, allow_nil?: false, public?: true

    attribute :generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :trigger_phase, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:staged, :verified, :critical, :unknown]
    end

    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :policy_digest, :string, allow_nil?: false, public?: true
    attribute :evidence_digest, :string, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :held_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :cleared_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :cleared_by_principal_type, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :cleared_by_principal_id, :string, allow_nil?: true, public?: true
    attribute :clearance_approval_id, :uuid, allow_nil?: true, public?: true
    attribute :clearance_policy_digest, :string, allow_nil?: true, public?: true
    attribute :clearance_evidence, :map, allow_nil?: true, public?: true
    attribute :diagnostics, :map, allow_nil?: false, default: %{}, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :canonical_device, ServiceRadar.Inventory.Device do
      define_attribute? false
      source_attribute :canonical_device_uid
      destination_attribute :uid
      public? true
    end

    belongs_to :trigger_membership, ServiceRadar.Automation.Ansible.AwxHostMembership do
      define_attribute? false
      source_attribute :trigger_membership_id
      public? true
    end

    belongs_to :trigger_execution_target,
               ServiceRadar.Automation.Ansible.AutomationExecutionTarget do
      define_attribute? false
      source_attribute :trigger_execution_target_id
      public? true
    end
  end

  identities do
    identity :one_active_hold_per_device, [:canonical_device_uid], where: expr(active == true)
  end
end
