defmodule ServiceRadar.Automation.Ansible.AwxHostMembership do
  @moduledoc """
  Durable AWX inventory membership identity.

  Execution identity is the controller-local tuple
  `(controller_id, inventory_id, awx_host_id)`. Host names and addresses are
  retained as evidence and display data, never as source identity. A canonical
  device may therefore have multiple current memberships and duplicate names in
  separate inventories remain distinct.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.Changes.ApproveAwxHostMembership
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}
  @launch_check {ActorHasPermission, permission: "ansible.runs.launch"}
  @manage_check {ActorHasPermission, permission: "ansible.controllers.manage"}
  @launch_read_fields [
    :id,
    :controller_id,
    :inventory_id,
    :awx_host_id,
    :canonical_device_uid,
    :source_generation,
    :enabled,
    :current,
    :link_disposition
  ]

  postgres do
    table "ansible_awx_host_memberships"
    repo ServiceRadar.Repo
    schema "platform"
    identity_index_names source_identity: "ansible_awx_host_memberships_source_identity_uidx"

    references do
      reference :controller, on_delete: :delete
      reference :canonical_device, on_delete: :nilify
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :get_by_source_identity,
      action: :by_source_identity,
      args: [:controller_id, :inventory_id, :awx_host_id]

    define :list_current_for_device, action: :current_for_device, args: [:canonical_device_uid]

    define :list_current_for_inventory,
      action: :current_for_inventory,
      args: [:controller_id, :inventory_id]

    define :upsert_from_sync, action: :upsert_from_sync
    define :expire, action: :expire
    define :quarantine_link, action: :quarantine_link
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

    read :by_source_identity do
      argument :controller_id, :uuid, allow_nil?: false
      argument :inventory_id, :integer, allow_nil?: false
      argument :awx_host_id, :integer, allow_nil?: false
      get? true

      filter expr(
               controller_id == ^arg(:controller_id) and
                 inventory_id == ^arg(:inventory_id) and awx_host_id == ^arg(:awx_host_id)
             )
    end

    read :current_for_device do
      argument :canonical_device_uid, :string, allow_nil?: false
      filter expr(canonical_device_uid == ^arg(:canonical_device_uid) and current == true)

      prepare build(
                select: @launch_read_fields,
                sort: [controller_id: :asc, inventory_id: :asc, awx_host_id: :asc]
              )
    end

    read :current_for_inventory do
      argument :controller_id, :uuid, allow_nil?: false
      argument :inventory_id, :integer, allow_nil?: false

      filter expr(
               controller_id == ^arg(:controller_id) and
                 inventory_id == ^arg(:inventory_id) and current == true
             )

      prepare build(sort: [awx_host_id: :asc])
    end

    create :upsert_from_sync do
      primary? true

      accept [
        :controller_id,
        :inventory_id,
        :awx_host_id,
        :canonical_device_uid,
        :source_generation,
        :host_name,
        :ansible_host,
        :enabled,
        :current,
        :last_seen_at,
        :expired_at,
        :link_disposition,
        :link_evidence,
        :source_fingerprint,
        :metadata
      ]

      upsert? true
      upsert_identity :source_identity

      upsert_fields [
        :canonical_device_uid,
        :source_generation,
        :host_name,
        :ansible_host,
        :enabled,
        :current,
        :last_seen_at,
        :expired_at,
        :link_disposition,
        :link_evidence,
        :source_fingerprint,
        :metadata,
        :updated_at
      ]
    end

    update :expire do
      require_atomic? false
      accept [:source_generation, :last_seen_at, :expired_at, :source_fingerprint, :metadata]
      change set_attribute(:current, false)
      change set_attribute(:enabled, false)
    end

    update :quarantine_link do
      require_atomic? false
      accept [:source_generation, :last_seen_at, :link_evidence, :source_fingerprint, :metadata]
      change set_attribute(:link_disposition, :quarantined)
      change set_attribute(:canonical_device_uid, nil)
    end

    update :approve_link do
      description "Approve one exact, current, unambiguous AWX-to-device membership link"
      require_atomic? false
      accept []

      argument :controller_id, :uuid, allow_nil?: false

      argument :inventory_id, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :awx_host_id, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :canonical_device_uid, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_024]

      argument :source_generation, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :source_fingerprint, :string,
        allow_nil?: false,
        constraints: [match: ~r/\Asha256:[0-9a-f]{64}\z/]

      argument :expected_link_evidence, :map, allow_nil?: false

      argument :link_evidence_digest, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-f]{64}\z/]

      argument :approved_at, :utc_datetime_usec, allow_nil?: false

      change ApproveAwxHostMembership
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission(
      [:read, :by_id, :by_source_identity, :current_for_inventory],
      @view_check
    )

    policy action(:current_for_device) do
      authorize_if @view_check
      authorize_if @launch_check
    end

    action_with_permission([:approve_link], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

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

    attribute :canonical_device_uid, :string do
      allow_nil? true
      public? true
      description "Explicit canonical device link; nil for unresolved/quarantined memberships"
    end

    attribute :source_generation, :integer do
      description "Source observation that last changed membership authority; unchanged observations only refresh last_seen_at"
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :host_name, :string, allow_nil?: false, public?: true
    attribute :ansible_host, :string, allow_nil?: true, public?: true
    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true
    attribute :current, :boolean, allow_nil?: false, default: true, public?: true
    attribute :last_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expired_at, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :link_disposition, :atom do
      allow_nil? false
      public? true
      default :unlinked
      constraints one_of: [:unlinked, :proposed, :approved, :quarantined]
    end

    attribute :link_evidence, :map, allow_nil?: false, default: %{}, public?: true
    attribute :source_fingerprint, :string, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
      public? true
    end

    belongs_to :canonical_device, ServiceRadar.Inventory.Device do
      define_attribute? false
      source_attribute :canonical_device_uid
      destination_attribute :uid
      public? true
    end

    has_many :execution_targets, ServiceRadar.Automation.Ansible.AutomationExecutionTarget do
      destination_attribute :membership_id
    end
  end

  identities do
    identity :source_identity, [:controller_id, :inventory_id, :awx_host_id]
  end
end
