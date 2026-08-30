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
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Credentials.Changes.WriteSecretLifecycleEvent
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

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
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at, :secret_payload]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_secret_by_id, action: :by_id_with_secret, args: [:id]
    define :list_by_provider, action: :by_provider, args: [:provider]
    define :create_secret, action: :create
    define :update_secret, action: :update
    define :mark_rotation_due, action: :mark_rotation_due
    define :start_rotation, action: :start_rotation
    define :complete_rotation, action: :complete_rotation
    define :fail_rotation, action: :fail_rotation
    define :disable_rotation, action: :disable_rotation
    define :enable_rotation, action: :enable_rotation
  end

  actions do
    read :read do
      prepare build(select: @public_read_fields)
    end

    # Ash re-reads a record through this action when it upgrades a non-atomic
    # update. Without one, every update action on this resource fails with
    # Ash.Error.Framework.MustBeAtomic ("cannot atomically update a record
    # without a primary read action or a configured `atomic_upgrade_with`
    # action") -- :update, :disable_rotation and the rotation transitions alike,
    # which is why none of them could be called at all.
    #
    # Deliberately NOT the primary read: `:read` carries a select preparation,
    # and Ash warns that a primary read with preparations also governs policy
    # checks and relationship loads. Narrowing those on a shared credential
    # resource is a larger change than enabling its own update actions needs.
    read :atomic_upgrade do
      description "Internal re-read used by Ash when upgrading a non-atomic update"
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
      accept [:secret_payload | @fields]
      atomic_upgrade_with :atomic_upgrade
    end

    update :mark_rotation_due do
      accept [:next_rotation_due_at]
      change transition_state(:rotation_due)
      change {WriteSecretLifecycleEvent, action: :mark_rotation_due}
    end

    update :start_rotation do
      accept [:metadata]
      change transition_state(:rotating)
      change set_attribute(:rotation_started_at, &DateTime.utc_now/0)
      change {WriteSecretLifecycleEvent, action: :start_rotation}
    end

    update :complete_rotation do
      accept [:secret_payload, :public_fingerprint, :next_rotation_due_at, :metadata]
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
      atomic_upgrade_with :atomic_upgrade
      change transition_state(:disabled)
      change {WriteSecretLifecycleEvent, action: :disable_rotation}
    end

    update :enable_rotation do
      accept []
      change transition_state(:active)
      change {WriteSecretLifecycleEvent, action: :enable_rotation}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_provider], @credential_manage_check)
    action_type_with_permission([:create, :update], @credential_manage_check)
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
