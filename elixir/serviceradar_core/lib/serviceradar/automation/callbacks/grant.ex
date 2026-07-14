defmodule ServiceRadar.Automation.Callbacks.Grant do
  @moduledoc """
  Immutable issuance ceiling and lifecycle state for one callback bearer.

  The bearer itself is never persisted. `token_verifier` is a keyed HMAC whose
  pepper is held outside the database; it is private and sensitive so ordinary
  Ash/API projections cannot expose it.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Callbacks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "automation_callback_grants"
    repo ServiceRadar.Repo
    schema "platform"

    identity_wheres_to_sql one_live_grant_per_partition: "state IN ('pending', 'active')"

    identity_index_names unique_token_verifier: "automation_callback_grants_token_verifier_uidx",
                         unique_idempotency_key_verifier:
                           "automation_callback_grants_idempotency_verifier_uidx",
                         one_live_grant_per_partition:
                           "automation_callback_grants_live_partition_uidx"

    references do
      reference :operation, on_delete: :restrict
      reference :execution, on_delete: :restrict
      reference :controller, on_delete: :restrict
      reference :template_binding, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_verifier, action: :by_verifier, args: [:token_verifier]
    define :list_for_execution, action: :for_execution, args: [:execution_id]
    define :create_pending, action: :create_pending
    define :bind_job_pending, action: :bind_job_pending
    define :activate_bound, action: :activate_bound
    define :record_consumed, action: :record_consumed
    define :record_revoked, action: :record_revoked
    define :record_expired, action: :record_expired
    define :record_credential_created, action: :record_credential_created
    define :record_credential_cleanup, action: :record_credential_cleanup
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

    read :by_verifier do
      argument :token_verifier, :binary, allow_nil?: false, sensitive?: true
      get? true
      filter expr(token_verifier == ^arg(:token_verifier))
    end

    read :for_execution do
      argument :execution_id, :uuid, allow_nil?: false
      filter expr(execution_id == ^arg(:execution_id))
      prepare build(sort: [issued_at: :desc])
    end

    create :create_pending do
      primary? true

      argument :grant_id, :uuid, allow_nil?: false

      accept [
        :operation_id,
        :execution_id,
        :tenant_id,
        :controller_id,
        :template_binding_id,
        :inventory_id,
        :job_template_id,
        :project_id,
        :scm_revision,
        :content_sha256,
        :action,
        :action_version,
        :audience,
        :response_schema_version,
        :manifest_sha256,
        :callback_phase,
        :remote_access_operation,
        :desired_state,
        :initiator_principal_type,
        :initiator_principal_id,
        :authorization_version,
        :permission_ceiling,
        :authority_ceiling,
        :approval_snapshot,
        :target_membership_ids,
        :target_snapshot,
        :target_digest,
        :policy_version,
        :policy_snapshot,
        :policy_digest,
        :ca_key_set_digest,
        :token_verifier,
        :token_pepper_version,
        :idempotency_key_verifier,
        :idempotency_pepper_version,
        :budget_limit,
        :idempotency_policy,
        :dispatch_agent_id,
        :dispatch_partition_id,
        :launch_envelope_ref,
        :issued_at,
        :expires_at
      ]

      change set_attribute(:id, arg(:grant_id))
    end

    update :activate_bound do
      require_atomic? true
      accept [:awx_job_id, :activated_at]
      filter expr(state == :pending)
      change set_attribute(:state, :active)
    end

    update :bind_job_pending do
      require_atomic? true
      accept [:awx_job_id]
      filter expr(state == :pending)
    end

    update :record_consumed do
      require_atomic? true
      accept [:budget_used, :consumed_at]
      filter expr(state == :active)
      change set_attribute(:state, :consumed)
    end

    update :record_revoked do
      require_atomic? true
      accept [:revoked_at, :revocation_reason, :orphan_risk_state]
      filter expr(state in [:pending, :active, :consumed])
      change set_attribute(:state, :revoked)
    end

    update :record_expired do
      require_atomic? true
      accept [:expired_at]
      filter expr(state in [:pending, :active, :consumed])
      change set_attribute(:state, :expired)
    end

    update :record_credential_created do
      require_atomic? true
      accept [:awx_ephemeral_credential_id]
      filter expr(credential_cleanup_state == :not_created)
      change set_attribute(:credential_cleanup_state, :pending)
    end

    update :record_credential_cleanup do
      require_atomic? true

      accept [
        :credential_cleanup_state,
        :credential_cleanup_attempted_at,
        :credential_cleanup_completed_at,
        :credential_cleanup_error_code,
        :orphan_risk_state
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_execution], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :execution_id, :uuid, allow_nil?: false, public?: true
    attribute :tenant_id, :string, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true
    attribute :template_binding_id, :uuid, allow_nil?: false, public?: true

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

    attribute :awx_job_id, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :scm_revision, :string, allow_nil?: false, public?: true
    attribute :content_sha256, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :action_version, :string, allow_nil?: false, public?: true
    attribute :audience, :string, allow_nil?: false, public?: true
    attribute :response_schema_version, :string, allow_nil?: false, public?: true
    attribute :manifest_sha256, :string, allow_nil?: false, public?: true

    attribute :callback_phase, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:preflight, :stage, :verify, :commit]
    end

    attribute :remote_access_operation, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:enroll]
    end

    attribute :desired_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:present]
    end

    attribute :initiator_principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :initiator_principal_id, :string, allow_nil?: false, public?: true
    attribute :authorization_version, :string, allow_nil?: false, public?: true

    attribute :permission_ceiling, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :authority_ceiling, :map, allow_nil?: false, public?: true
    attribute :approval_snapshot, :map, allow_nil?: false, public?: true

    attribute :target_membership_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :target_snapshot, :map, allow_nil?: false, public?: true
    attribute :target_digest, :string, allow_nil?: false, public?: true
    attribute :policy_version, :string, allow_nil?: false, public?: true
    attribute :policy_snapshot, :map, allow_nil?: false, public?: true
    attribute :policy_digest, :string, allow_nil?: false, public?: true
    attribute :ca_key_set_digest, :string, allow_nil?: false, public?: true

    attribute :token_verifier, :binary do
      allow_nil? false
      public? false
      sensitive? true
      description "Pepper-versioned HMAC verifier; never the bearer or an unkeyed bearer hash"
    end

    attribute :token_pepper_version, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :idempotency_key_verifier, :binary do
      allow_nil? false
      public? false
      sensitive? true

      description "Keyed verifier for the server-minted idempotency key; never plaintext or an unkeyed hash"
    end

    attribute :idempotency_pepper_version, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :state, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :active, :revoked, :expired, :consumed]
    end

    attribute :budget_limit, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 1
    end

    attribute :budget_used, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0, max: 1
    end

    attribute :idempotency_policy, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:one_logical_read_per_child_policy]
    end

    attribute :dispatch_agent_id, :string, allow_nil?: false, public?: true
    attribute :dispatch_partition_id, :string, allow_nil?: false, public?: true

    attribute :launch_envelope_ref, :string do
      allow_nil? false
      public? false
      sensitive? true
      description "Single-resolution envelope reference; never envelope plaintext"
    end

    attribute :awx_ephemeral_credential_id, :integer do
      allow_nil? true
      public? false
      sensitive? true
      constraints min: 1
    end

    attribute :credential_cleanup_state, :atom do
      allow_nil? false
      default :not_created
      public? true
      constraints one_of: [:not_created, :pending, :deleting, :deleted, :delete_failed]
    end

    attribute :credential_cleanup_attempted_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true

    attribute :credential_cleanup_completed_at, :utc_datetime_usec,
      allow_nil?: true,
      public?: true

    attribute :credential_cleanup_error_code, :string, allow_nil?: true, public?: true

    attribute :orphan_risk_state, :atom do
      allow_nil? false
      default :none
      public? true
      constraints one_of: [:none, :cancel_requested, :cancel_confirmed, :cancel_failed]
    end

    attribute :issued_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :activated_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :consumed_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :revoked_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :expired_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :revocation_reason, :string, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :operation, ServiceRadar.Automation.Ansible.AutomationOperation do
      define_attribute? false
      source_attribute :operation_id
    end

    belongs_to :execution, ServiceRadar.Automation.Ansible.AutomationExecution do
      define_attribute? false
      source_attribute :execution_id
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
    end

    belongs_to :template_binding, ServiceRadar.Automation.Ansible.AwxTemplateBinding do
      define_attribute? false
      source_attribute :template_binding_id
    end

    has_many :uses, ServiceRadar.Automation.Callbacks.Use do
      destination_attribute :grant_id
    end

    has_many :audit_events, ServiceRadar.Automation.Callbacks.AuditEvent do
      destination_attribute :grant_id
    end
  end

  identities do
    identity :unique_token_verifier, [:token_verifier]
    identity :unique_idempotency_key_verifier, [:idempotency_key_verifier]

    identity :one_live_grant_per_partition,
             [:execution_id, :action, :action_version, :policy_digest],
             where: expr(state in [:pending, :active])
  end
end
