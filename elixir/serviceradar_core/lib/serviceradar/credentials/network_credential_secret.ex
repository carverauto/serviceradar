defmodule ServiceRadar.Credentials.NetworkCredentialSecret do
  @moduledoc """
  Encrypted reusable credential material for network integrations.

  Public reads expose metadata such as provider, kind, username, and
  fingerprint. The `secret_payload` plaintext attribute is encrypted by
  AshCloak into `encrypted_secret_payload` and is never public.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak, AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer],
    # The primary read deliberately carries a select preparation; see `read :read`.
    primary_read_warning?: false

  alias ServiceRadar.Credentials.Changes.GuardCredentialDestroy
  alias ServiceRadar.Credentials.Changes.WriteSecretLifecycleEvent
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}
  @credential_in_use_message "credential_in_use"

  @fields [
    :name,
    :description,
    :provider,
    :credential_kind,
    :username,
    :public_fingerprint,
    :source_type,
    :secret_provider_id,
    :external_secret_ref,
    :external_secret_version,
    :external_secret_fields,
    :resolution_location,
    :cache_policy,
    :cache_ttl_seconds,
    :last_rotated_at,
    :next_rotation_due_at,
    :last_resolved_at,
    :last_resolution_status,
    :last_resolution_message,
    :metadata
  ]

  @rotation_read_fields [
    :rotation_state,
    :rotation_started_at,
    :last_rotation_failed_at,
    :last_rotation_failure_message
  ]

  @editable_fields [:name, :description]
  @lifecycle_actions [
    :mark_rotation_due,
    :start_rotation,
    :complete_rotation,
    :fail_rotation,
    :disable_rotation,
    :enable_rotation
  ]

  @public_read_fields [:id, :inserted_at, :updated_at | @fields] ++ @rotation_read_fields
  @secret_read_fields [
    :id,
    :provider,
    :credential_kind,
    :username,
    :metadata,
    :source_type,
    :secret_provider_id,
    :external_secret_ref,
    :external_secret_version,
    :external_secret_fields,
    :resolution_location,
    :cache_policy,
    :cache_ttl_seconds,
    :rotation_state,
    :encrypted_secret_payload
  ]

  postgres do
    table "network_credential_secrets"
    repo ServiceRadar.Repo
    schema "platform"

    foreign_key_names [
      {:id, "network_credential_rules_secret_id_fkey", @credential_in_use_message},
      {:id, "snmp_profiles_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "snmp_targets_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "device_snmp_credentials_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "mapper_unifi_controllers_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "mapper_mikrotik_controllers_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "integration_sources_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "plugin_repositories_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "ansible_controllers_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "ansible_controllers_sync_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "ansible_controllers_execution_credential_secret_id_fkey",
       @credential_in_use_message},
      {:id, "ansible_controllers_callback_credential_secret_id_fkey", @credential_in_use_message},
      {:id, "ansible_playbook_repositories_credential_secret_id_fkey",
       @credential_in_use_message},
      {:id, "outbound_mail_settings_password_secret_id_fkey", @credential_in_use_message},
      {:id, "outbound_mail_settings_api_key_secret_id_fkey", @credential_in_use_message},
      {:id, "credential_broker_grants_secret_id_fkey", @credential_in_use_message},
      {:id, "network_credential_secret_bindings_secret_id_fkey", @credential_in_use_message}
    ]
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:secret_payload])
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active
    state_attribute :rotation_state

    transitions do
      transition :mark_rotation_due, from: [:active, :rotation_failed], to: :rotation_due
      transition :start_rotation, from: [:active, :rotation_due, :rotation_failed], to: :rotating
      transition :complete_rotation, from: :rotating, to: :active
      transition :fail_rotation, from: :rotating, to: :rotation_failed

      transition :disable_rotation,
        from: [:active, :rotation_due, :rotating, :rotation_failed],
        to: :disabled

      transition :enable_rotation, from: :disabled, to: :active
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "network_credential_secret_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :cascade_versions_with_audit_actor, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :secret_payload]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_secret_by_id, action: :by_id_with_secret, args: [:id]
    define :list_by_provider, action: :by_provider, args: [:provider]
    define :create_secret, action: :create
    define :update_secret, action: :update
    define :edit_details, action: :edit_details
    define :destroy_permanently, action: :destroy_permanently, args: [:confirm_secret_id]
  end

  actions do
    # Primary because every update on this resource needs it. Without a primary
    # read, `:update`, `:disable_rotation` and the rotation transitions all fail
    # -- first with Ash.Error.Framework.MustBeAtomic, and then, once
    # `atomic_upgrade_with` is configured, with `Required primary read action`
    # raised from the `Ash.load/3` inside `Ash.Actions.Update.run/4`. No caller
    # had ever updated this resource, so none of its update actions worked.
    #
    # The select preparation is why `use Ash.Resource` carries
    # `primary_read_warning?: false`. Ash warns that a primary read with
    # preparations also governs relationship loads and policy checks -- here that
    # is the desired effect, not an accident: it means loading a repository's
    # `credential_secret` yields the public fields and never the encrypted
    # payload. `:by_id_with_secret` remains the only way to reach that.
    read :read do
      primary? true
      prepare build(select: @public_read_fields)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @public_read_fields)
    end

    read :by_id_with_secret do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
      prepare build(select: @secret_read_fields)
    end

    read :by_provider do
      argument :provider, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider))
      prepare build(select: @public_read_fields)
    end

    create :create do
      accept [:secret_payload | @fields]
    end

    update :update do
      accept @editable_fields
    end

    update :edit_details do
      accept @editable_fields
    end

    update :mark_rotation_due do
      accept [:next_rotation_due_at]
      change transition_state(:rotation_due)
      change {WriteSecretLifecycleEvent, action: :mark_rotation_due}
    end

    update :start_rotation do
      accept []
      change transition_state(:rotating)
      change set_attribute(:rotation_started_at, &DateTime.utc_now/0)
      change {WriteSecretLifecycleEvent, action: :start_rotation}
    end

    update :complete_rotation do
      accept [
        :secret_payload,
        :username,
        :public_fingerprint,
        :next_rotation_due_at,
        :metadata
      ]

      change transition_state(:active)
      change set_attribute(:last_rotated_at, &DateTime.utc_now/0)
      change set_attribute(:rotation_started_at, nil)
      change set_attribute(:last_rotation_failed_at, nil)
      change set_attribute(:last_rotation_failure_message, nil)
      change {WriteSecretLifecycleEvent, action: :complete_rotation}
    end

    update :fail_rotation do
      argument :message, :string, allow_nil?: false
      change transition_state(:rotation_failed)
      change set_attribute(:rotation_started_at, nil)
      change set_attribute(:last_rotation_failed_at, &DateTime.utc_now/0)
      change set_attribute(:last_rotation_failure_message, arg(:message))
      change {WriteSecretLifecycleEvent, action: :fail_rotation}
    end

    update :disable_rotation do
      accept []
      change transition_state(:disabled)
      change {WriteSecretLifecycleEvent, action: :disable_rotation}
    end

    update :enable_rotation do
      accept []
      change transition_state(:active)
      change {WriteSecretLifecycleEvent, action: :enable_rotation}
    end

    destroy :destroy_permanently do
      argument :confirm_secret_id, :uuid, allow_nil?: false

      touches_resources [
        ServiceRadar.Credentials.CredentialBrokerGrant,
        ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit
      ]

      change GuardCredentialDestroy
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_provider], @credential_manage_check)

    action_with_permission(
      [:create, :update, :edit_details, :destroy_permanently],
      @credential_manage_check
    )

    policy action(@lifecycle_actions) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Operator-facing credential name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      description "Package-declared integration provider identifier"
    end

    attribute :credential_kind, :atom do
      allow_nil? false
      public? true

      # The bounded platform vocabulary of credential primitives. `:snmp` is one
      # kind rather than three because v1/v2c community strings and v3 auth/priv
      # material are the same credential to an operator -- which one applies is
      # decided by the profile's SNMP version, not by picking a different
      # secret. The payload is JSON so a single secret can carry whichever
      # fields its version needs; `SNMPProfiles.CredentialResolver` already
      # reads exactly that shape.
      constraints one_of: [
                    :api_token,
                    :username_password,
                    :ssh_private_key,
                    :certificate,
                    :snmp,
                    :opaque
                  ]
    end

    attribute :username, :string do
      allow_nil? true
      public? true
      description "Optional non-secret username or API token ID"
    end

    attribute :public_fingerprint, :string do
      allow_nil? true
      public? true
      description "Optional public key, certificate, or token fingerprint"
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      default :internal_encrypted
      constraints one_of: [:internal_encrypted, :external_reference]

      description "Whether the credential is stored internally or resolved from an external provider"
    end

    attribute :secret_provider_id, :uuid do
      allow_nil? true
      public? true
      description "External secret provider used when source_type is external_reference"
    end

    attribute :external_secret_ref, :string do
      allow_nil? true
      public? true
      description "Provider-specific object, item, path, or secret identifier"
    end

    attribute :external_secret_version, :string do
      allow_nil? true
      public? true
      description "Optional provider-specific version selector"
    end

    attribute :external_secret_fields, :map do
      allow_nil? false
      public? true
      default %{}
      description "Provider field mapping for structured external secrets"
    end

    attribute :resolution_location, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:control_plane, :agent, :hybrid]
      description "Preferred broker location for resolving the external reference"
    end

    attribute :cache_policy, :atom do
      allow_nil? false
      public? true
      default :no_cache
      constraints one_of: [:no_cache, :memory_ttl, :encrypted_ttl]
    end

    attribute :cache_ttl_seconds, :integer do
      allow_nil? true
      public? true
      constraints min: 1
    end

    attribute :rotation_state, :atom do
      allow_nil? false
      public? true
      default :active

      constraints one_of: [
                    :active,
                    :rotation_due,
                    :rotating,
                    :rotation_failed,
                    :disabled
                  ]

      description "First-class credential rotation lifecycle state"
    end

    attribute :rotation_started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_rotation_failed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_rotation_failure_message, :string do
      allow_nil? true
      public? true
    end

    attribute :last_rotated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When this credential material was last rotated"
    end

    attribute :next_rotation_due_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Operator-facing rotation due date for this credential"
    end

    attribute :last_resolved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_resolution_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:success, :failed, :denied, :cache_hit]
    end

    attribute :last_resolution_message, :string do
      allow_nil? true
      public? true
    end

    attribute :secret_payload, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Credential payload encrypted at rest by AshCloak"
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
    belongs_to :secret_provider, ServiceRadar.Credentials.CredentialSecretProvider do
      allow_nil? true
      public? true
      source_attribute :secret_provider_id
      destination_attribute :id
      define_attribute? false
    end
  end

  calculations do
    calculate :secret_payload_present, :boolean, fn records, _opts ->
      Enum.map(records, fn record ->
        case Map.get(record, :encrypted_secret_payload) do
          value when is_binary(value) -> byte_size(value) > 0
          _ -> false
        end
      end)
    end
  end

  identities do
    identity :unique_provider_name, [:provider, :name]
  end
end
