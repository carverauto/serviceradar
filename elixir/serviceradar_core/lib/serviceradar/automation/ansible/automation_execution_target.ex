defmodule ServiceRadar.Automation.Ansible.AutomationExecutionTarget do
  @moduledoc """
  Frozen AWX membership tuple selected for one child execution.

  Controller, inventory, host ID, canonical device UID, source generation and
  fingerprint, host name, and address are copied into the snapshot. Later
  membership drift cannot silently retarget the child.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  @history_read_fields [
    :id,
    :execution_id,
    :membership_id,
    :canonical_device_uid,
    :controller_id,
    :inventory_id,
    :awx_host_id,
    :membership_generation,
    :source_fingerprint,
    :host_name,
    :ansible_host,
    :status,
    :snapshot_digest,
    :diagnostics,
    :inserted_at,
    :updated_at
  ]

  postgres do
    table "ansible_automation_execution_targets"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_execution_membership:
                           "ansible_automation_execution_targets_membership_uidx",
                         unique_execution_awx_host:
                           "ansible_automation_execution_targets_awx_host_uidx",
                         unique_execution_device:
                           "ansible_automation_execution_targets_device_uidx"

    references do
      reference :execution, on_delete: :delete
      reference :membership, on_delete: :restrict
      reference :canonical_device, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_execution_host, action: :by_execution_host, args: [:execution_id, :awx_host_id]
    define :list_for_execution, action: :for_execution, args: [:execution_id]
    define :list_for_device, action: :for_device, args: [:canonical_device_uid]
    define :list_history_for_execution, action: :history_for_execution, args: [:execution_id]
    define :list_history_for_device, action: :history_for_device, args: [:canonical_device_uid]
    define :create_target, action: :create
    define :record_status, action: :record_status
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

    read :by_execution_host do
      argument :execution_id, :uuid, allow_nil?: false
      argument :awx_host_id, :integer, allow_nil?: false
      get? true
      filter expr(execution_id == ^arg(:execution_id) and awx_host_id == ^arg(:awx_host_id))
    end

    read :for_execution do
      argument :execution_id, :uuid, allow_nil?: false
      filter expr(execution_id == ^arg(:execution_id))
      prepare build(sort: [awx_host_id: :asc])
    end

    read :for_device do
      argument :canonical_device_uid, :string, allow_nil?: false
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid))
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    read :history_for_execution do
      description "Secret-safe exact target tuples for one execution"
      argument :execution_id, :uuid, allow_nil?: false
      filter expr(execution_id == ^arg(:execution_id))
      prepare build(select: @history_read_fields, sort: [awx_host_id: :asc])
    end

    read :history_for_device do
      description "Recent secret-safe secure execution targets for one canonical device"
      argument :canonical_device_uid, :string, allow_nil?: false
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid))

      prepare build(
                select: @history_read_fields,
                sort: [inserted_at: :desc],
                limit: 100
              )
    end

    create :create do
      primary? true

      accept [
        :execution_id,
        :membership_id,
        :canonical_device_uid,
        :controller_id,
        :inventory_id,
        :awx_host_id,
        :membership_generation,
        :source_fingerprint,
        :host_name,
        :ansible_host,
        :snapshot_digest
      ]
    end

    update :record_status do
      require_atomic? false
      accept [:status, :diagnostics]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [
        :read,
        :by_id,
        :by_execution_host,
        :for_execution,
        :for_device,
        :history_for_execution,
        :history_for_device
      ],
      @view_check
    )
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :execution_id, :uuid, allow_nil?: false, public?: true
    attribute :membership_id, :uuid, allow_nil?: false, public?: true
    attribute :canonical_device_uid, :string, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true

    attribute :inventory_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :awx_host_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :membership_generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :source_fingerprint, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\Asha256:[0-9a-f]{64}\z/
    end

    attribute :host_name, :string, allow_nil?: false, public?: true
    attribute :ansible_host, :string, allow_nil?: true, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true

      constraints one_of: [
                    :pending,
                    :running,
                    :ok,
                    :failed,
                    :unreachable,
                    :skipped,
                    :scope_mismatch,
                    :canceled
                  ]
    end

    attribute :snapshot_digest, :string, allow_nil?: false, public?: true
    attribute :diagnostics, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :execution, ServiceRadar.Automation.Ansible.AutomationExecution do
      define_attribute? false
      source_attribute :execution_id
      public? true
    end

    belongs_to :membership, ServiceRadar.Automation.Ansible.AwxHostMembership do
      define_attribute? false
      source_attribute :membership_id
      public? true
    end

    belongs_to :canonical_device, ServiceRadar.Inventory.Device do
      define_attribute? false
      source_attribute :canonical_device_uid
      destination_attribute :uid
      public? true
    end

    has_many :mutation_phases, ServiceRadar.Automation.Ansible.AutomationMutationPhase do
      destination_attribute :execution_target_id
    end
  end

  identities do
    identity :unique_execution_membership, [:execution_id, :membership_id]
    identity :unique_execution_awx_host, [:execution_id, :awx_host_id]
    identity :unique_execution_device, [:execution_id, :canonical_device_uid]
  end
end
