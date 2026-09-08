defmodule ServiceRadar.Automation.Callbacks.AuditEvent do
  @moduledoc """
  Append-only, secret-free callback grant lifecycle evidence.

  The schema intentionally has no arbitrary payload or metadata attribute. It
  can retain identifiers, bounded reason codes, state, budget transitions, and
  content fingerprints, but has nowhere to persist a bearer, verifier,
  envelope plaintext, response body, credential, or managed-host secret.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Callbacks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "automation_callback_audit_events"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_event_key: "automation_callback_audit_events_key_uidx"

    references do
      reference :grant, on_delete: :restrict
      reference :use, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_grant, action: :for_grant, args: [:grant_id]
    define :record, action: :record
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

    read :for_grant do
      argument :grant_id, :uuid, allow_nil?: false
      filter expr(grant_id == ^arg(:grant_id))
      prepare build(sort: [occurred_at: :asc, inserted_at: :asc])
    end

    create :record do
      primary? true

      accept [
        :grant_id,
        :use_id,
        :event_key,
        :event_type,
        :outcome,
        :tenant_id,
        :operation_id,
        :execution_id,
        :controller_id,
        :inventory_id,
        :job_template_id,
        :awx_job_id,
        :action,
        :action_version,
        :audience,
        :principal_type,
        :principal_id,
        :reason_code,
        :policy_version,
        :request_fingerprint,
        :response_fingerprint,
        :budget_before,
        :budget_after,
        :grant_state,
        :credential_cleanup_state,
        :occurred_at
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :for_grant], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :grant_id, :uuid, allow_nil?: false, public?: true
    attribute :use_id, :uuid, allow_nil?: true, public?: true
    attribute :event_key, :uuid, allow_nil?: false, public?: true

    attribute :event_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :mint_pending,
                    :envelope_resolved,
                    :credential_created,
                    :dispatch_succeeded,
                    :dispatch_failed,
                    :binding_activated,
                    :callback_allowed,
                    :callback_denied,
                    :callback_pending,
                    :callback_replay,
                    :budget_committed,
                    :grant_revoked,
                    :grant_expired,
                    :credential_delete_requested,
                    :credential_deleted,
                    :credential_delete_failed,
                    :cleanup_completed,
                    :misuse_detected
                  ]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :allowed, :denied, :succeeded, :failed]
    end

    attribute :tenant_id, :string, allow_nil?: false, public?: true
    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :execution_id, :uuid, allow_nil?: false, public?: true
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

    attribute :awx_job_id, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :action, :string, allow_nil?: false, public?: true
    attribute :action_version, :string, allow_nil?: false, public?: true
    attribute :audience, :string, allow_nil?: false, public?: true

    attribute :principal_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:human, :service_principal]
    end

    attribute :principal_id, :string, allow_nil?: false, public?: true

    attribute :reason_code, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :success,
                    :grant_pending,
                    :activation_pending,
                    :authorization_denied,
                    :permission_missing,
                    :principal_disabled,
                    :tenant_mismatch,
                    :approval_expired,
                    :target_drift,
                    :policy_drift,
                    :revision_mismatch,
                    :binding_mismatch,
                    :job_mismatch,
                    :dispatch_failed,
                    :dispatch_ambiguous,
                    :grant_expired,
                    :grant_revoked,
                    :budget_consumed,
                    :idempotency_conflict,
                    :replay_authority_denied,
                    :credential_delete_failed,
                    :cancel_failed,
                    :malformed_request,
                    :misuse_detected
                  ]
    end

    attribute :policy_version, :string, allow_nil?: false, public?: true
    attribute :request_fingerprint, :string, allow_nil?: true, public?: true
    attribute :response_fingerprint, :string, allow_nil?: true, public?: true

    attribute :budget_before, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :budget_after, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :grant_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pending, :active, :revoked, :expired, :consumed]
    end

    attribute :credential_cleanup_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:not_created, :pending, :deleting, :deleted, :delete_failed]
    end

    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :grant, ServiceRadar.Automation.Callbacks.Grant do
      define_attribute? false
      source_attribute :grant_id
    end

    belongs_to :use, ServiceRadar.Automation.Callbacks.Use do
      define_attribute? false
      source_attribute :use_id
    end
  end

  identities do
    identity :unique_event_key, [:grant_id, :event_key]
  end
end
