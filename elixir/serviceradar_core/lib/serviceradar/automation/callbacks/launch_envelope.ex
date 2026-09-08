defmodule ServiceRadar.Automation.Callbacks.LaunchEnvelope do
  @moduledoc """
  Sealed, single-resolution carrier for one automation callback bearer.

  This table stores only a keyed reference verifier and ciphertext. The opaque
  reference is persisted solely in the narrow AgentCommand payload that owns
  this envelope; plaintext bearer material is never stored. Resolution is a
  system-only locked transition, and ordinary Ash APIs cannot project the
  verifier or ciphertext.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Callbacks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "automation_launch_envelopes"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_reference_verifier:
                           "automation_launch_envelopes_reference_verifier_uidx",
                         unique_command: "automation_launch_envelopes_command_uidx"

    references do
      reference :callback_grant, on_delete: :restrict
      reference :child_execution, on_delete: :restrict
      reference :controller, on_delete: :restrict
    end
  end

  code_interface do
    define :get_by_reference_verifier, action: :by_reference_verifier, args: [:reference_verifier]
    define :create_sealed, action: :create_sealed
    define :mark_resolved, action: :mark_resolved
    define :mark_expired, action: :mark_expired
  end

  actions do
    read :read do
      primary? true
    end

    read :by_reference_verifier do
      argument :reference_verifier, :binary, allow_nil?: false, sensitive?: true
      get? true
      filter expr(reference_verifier == ^arg(:reference_verifier))
    end

    create :create_sealed do
      primary? true

      accept [
        :reference_verifier,
        :tenant_id,
        :command_id,
        :child_execution_id,
        :callback_grant_id,
        :controller_id,
        :inventory_id,
        :job_template_id,
        :dispatch_agent_id,
        :dispatch_partition_id,
        :callback_url,
        :callback_allowed_origin,
        :manifest_sha256,
        :scm_revision,
        :content_sha256,
        :callback_phase,
        :callback_operation,
        :callback_state,
        :callback_credential_type_id,
        :callback_credential_organization_id,
        :callback_credential_injector_sha256,
        :context_digest,
        :ciphertext,
        :cipher_version,
        :cipher_key_id,
        :issued_at,
        :expires_at
      ]
    end

    update :mark_resolved do
      require_atomic? true
      accept [:resolved_at, :resolved_by_agent_id, :resolved_by_partition_id]
      filter expr(state == :sealed)
      change set_attribute(:state, :resolved)
    end

    update :mark_expired do
      require_atomic? true
      accept [:expired_at]
      filter expr(state == :sealed)
      change set_attribute(:state, :expired)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :reference_verifier, :binary do
      allow_nil? false
      public? false
      sensitive? true
      description "Keyed verifier for the opaque command reference"
    end

    attribute :tenant_id, :string, allow_nil?: false, public?: false
    attribute :command_id, :uuid, allow_nil?: false, public?: false
    attribute :child_execution_id, :uuid, allow_nil?: false, public?: false
    attribute :callback_grant_id, :uuid, allow_nil?: false, public?: false
    attribute :controller_id, :uuid, allow_nil?: false, public?: false

    attribute :inventory_id, :integer do
      allow_nil? false
      public? false
      constraints min: 1
    end

    attribute :job_template_id, :integer do
      allow_nil? false
      public? false
      constraints min: 1
    end

    attribute :dispatch_agent_id, :string, allow_nil?: false, public?: false
    attribute :dispatch_partition_id, :string, allow_nil?: false, public?: false
    attribute :callback_url, :string, allow_nil?: false, public?: false
    attribute :callback_allowed_origin, :string, allow_nil?: false, public?: false
    attribute :manifest_sha256, :string, allow_nil?: false, public?: false
    attribute :scm_revision, :string, allow_nil?: false, public?: false
    attribute :content_sha256, :string, allow_nil?: false, public?: false
    attribute :callback_phase, :string, allow_nil?: false, public?: false
    attribute :callback_operation, :string, allow_nil?: false, public?: false
    attribute :callback_state, :string, allow_nil?: false, public?: false

    attribute :callback_credential_type_id, :integer do
      allow_nil? false
      public? false
      constraints min: 1, max: 2_147_483_647
    end

    attribute :callback_credential_organization_id, :integer do
      allow_nil? false
      public? false
      constraints min: 1, max: 2_147_483_647
    end

    attribute :callback_credential_injector_sha256, :string do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :context_digest, :binary do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :ciphertext, :binary do
      allow_nil? false
      public? false
      sensitive? true
    end

    attribute :cipher_version, :string, allow_nil?: false, public?: false
    attribute :cipher_key_id, :string, allow_nil?: false, public?: false

    attribute :state, :atom do
      allow_nil? false
      default :sealed
      public? false
      constraints one_of: [:sealed, :resolved, :expired]
    end

    attribute :issued_at, :utc_datetime_usec, allow_nil?: false, public?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: false
    attribute :resolved_at, :utc_datetime_usec, allow_nil?: true, public?: false
    attribute :resolved_by_agent_id, :string, allow_nil?: true, public?: false
    attribute :resolved_by_partition_id, :string, allow_nil?: true, public?: false
    attribute :expired_at, :utc_datetime_usec, allow_nil?: true, public?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :callback_grant, ServiceRadar.Automation.Callbacks.Grant do
      define_attribute? false
      source_attribute :callback_grant_id
    end

    belongs_to :child_execution, ServiceRadar.Automation.Ansible.AutomationExecution do
      define_attribute? false
      source_attribute :child_execution_id
    end

    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
    end
  end

  identities do
    identity :unique_reference_verifier, [:reference_verifier]
    identity :unique_command, [:command_id]
  end
end
