defmodule ServiceRadar.Automation.Ansible.AutomationExecutionDelegation do
  @moduledoc """
  Expiring, revocable execution ceiling for scheduled automation.

  The row never contains a user bearer. It records the issuer, owner, fixed
  execution principal, and immutable issuance-time ceilings that the scheduler
  must intersect with current authority at fire time.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.schedules.view"}
  @manage_check {ActorHasPermission, permission: "ansible.delegations.manage"}

  postgres do
    table "ansible_automation_execution_delegations"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :schedule, on_delete: :delete
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_active_for_schedule, action: :active_for_schedule, args: [:schedule_id]
    define :create_managed, action: :create_managed
    define :revoke_managed, action: :revoke_managed
    define :record_invalidated, action: :record_invalidated
    define :record_expired, action: :record_expired
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

    read :active_for_schedule do
      argument :schedule_id, :uuid, allow_nil?: false
      filter expr(schedule_id == ^arg(:schedule_id) and status == :active)
      prepare build(sort: [issued_at: :desc])
    end

    create :create_managed do
      primary? true

      accept [
        :schedule_id,
        :tenant_id,
        :issuer_principal_type,
        :issuer_principal_id,
        :owner_principal_id,
        :execution_principal_type,
        :execution_principal_id,
        :authorization_version,
        :permission_ceiling,
        :action_ceiling,
        :target_membership_ids,
        :non_secret_input_ceiling,
        :approval_snapshot,
        :run_budget,
        :issued_at,
        :expires_at,
        :metadata
      ]
    end

    update :revoke_managed do
      require_atomic? false
      accept [:revocation_reason, :metadata]
      change set_attribute(:status, :revoked)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :record_invalidated do
      require_atomic? false
      accept [:revocation_reason, :metadata]
      change set_attribute(:status, :invalidated)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :record_expired do
      require_atomic? false
      accept [:metadata]
      change set_attribute(:status, :expired)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :active_for_schedule], @view_check)
    action_with_permission([:create_managed, :revoke_managed], @manage_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :schedule_id, :uuid, allow_nil?: true, public?: true
    attribute :tenant_id, :string, allow_nil?: false, public?: true

    attribute :issuer_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :issuer_principal_id, :string, allow_nil?: false, public?: true
    attribute :owner_principal_id, :string, allow_nil?: false, public?: true

    attribute :execution_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :execution_principal_id, :string, allow_nil?: false, public?: true
    attribute :authorization_version, :string, allow_nil?: false, public?: true

    attribute :permission_ceiling, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :action_ceiling, :map, allow_nil?: false, default: %{}, public?: true

    attribute :target_membership_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :non_secret_input_ceiling, :map,
      allow_nil?: false,
      default: %{},
      public?: true

    attribute :approval_snapshot, :map, allow_nil?: false, default: %{}, public?: true
    attribute :run_budget, :map, allow_nil?: false, default: %{}, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :expired, :revoked, :invalidated]
    end

    attribute :issued_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :revoked_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :revocation_reason, :string, allow_nil?: true, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :schedule, ServiceRadar.Automation.Ansible.PlaybookSchedule do
      define_attribute? false
      source_attribute :schedule_id
      public? true
    end
  end
end
