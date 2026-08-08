defmodule ServiceRadar.Plugins.AddonAssignment do
  @moduledoc """
  Assignment of an approved native add-on (feature set) package to an agent.

  An operator-selected add-on for an agent. The AgentConfigGenerator compiles
  enabled assignments whose package is approved into the `addons` section of the
  agent configuration, which the agent supervises as go-plugin subprocesses.
  """

  use Ash.Resource,
    domain: ServiceRadar.Plugins,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.AgentConfig.DependencyNotifier],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.Changes.ApplyAddonConfigDefaults
  alias ServiceRadar.Plugins.Changes.ApplyAddonUpdatePolicyDefaults
  alias ServiceRadar.Plugins.Changes.IssueDirectLeafAccess
  alias ServiceRadar.Plugins.Changes.RevokeDirectLeafAccess
  alias ServiceRadar.Plugins.Changes.SetAssignmentAddonId
  alias ServiceRadar.Plugins.Changes.SetDirectLeafAccess
  alias ServiceRadar.Plugins.Validations.AddonAssignmentParams
  alias ServiceRadar.Plugins.Validations.AddonPackageApproved
  alias ServiceRadar.Plugins.Validations.NoDuplicateEnabledAddonAssignment

  @mutable_fields [
    :addon_package_id,
    :source,
    :source_key,
    :addon_profile_id,
    :enabled,
    :params,
    :args,
    :profile_reconcile_status,
    :profile_reconcile_error,
    :profile_last_reconciled_at,
    :profile_metadata,
    :update_policy,
    :explicit_version_pin,
    :release_channel,
    :capability_ceiling,
    :rollout_policy,
    :edge_site_id
  ]

  @create_fields [:agent_uid, :addon_package_id | @mutable_fields]

  postgres do
    table "addon_assignments"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :addon_package, on_delete: :delete
    end
  end

  cloak do
    vault(ServiceRadar.Vault)

    # Named WITHOUT a `_ciphertext` suffix on purpose. AshCloak removes each attribute listed
    # here and replaces it with `encrypted_<name>` (the stored ciphertext) plus a calculation
    # under the original name that decrypts. So these three names describe the PLAINTEXT, and
    # the columns are `encrypted_direct_certificate_pem` and friends.
    #
    # Suffixing them produced `encrypted_direct_certificate_pem_ciphertext` as the column while
    # the migration created `direct_certificate_pem_ciphertext`, so every read of this resource
    # failed with `undefined_column` and every write to the un-suffixed name failed with
    # NoSuchAttribute -- the name had become a calculation. See
    # priv/repo/migrations/20260807120000_rename_direct_leaf_access_ciphertext_columns.exs.
    attributes([
      :direct_certificate_pem,
      :direct_private_key_pem,
      :direct_ca_chain_pem
    ])

    decrypt_by_default([])
  end

  actions do
    defaults [:read, :destroy]

    read :by_package do
      argument :addon_package_id, :uuid, allow_nil?: false
      filter expr(addon_package_id == ^arg(:addon_package_id) and enabled == true)
    end

    read :by_agent do
      argument :agent_uid, :string, allow_nil?: false
      filter expr(agent_uid == ^arg(:agent_uid))
    end

    read :by_profile do
      argument :addon_profile_id, :uuid, allow_nil?: false
      filter expr(source == :profile and addon_profile_id == ^arg(:addon_profile_id))
    end

    read :by_source_key do
      argument :source, :atom, allow_nil?: false
      argument :source_key, :string, allow_nil?: false
      get? true
      filter expr(source == ^arg(:source) and source_key == ^arg(:source_key))
    end

    create :create do
      accept @create_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      change SetDirectLeafAccess
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
      validate AddonAssignmentParams
    end

    update :update do
      accept @mutable_fields

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      change ApplyAddonUpdatePolicyDefaults
      change SetDirectLeafAccess
      validate AddonPackageApproved
      validate NoDuplicateEnabledAddonAssignment
      validate AddonAssignmentParams
    end

    update :apply_rollout_override do
      require_atomic? false
      accept [:rollout_package_id, :rollout_id, :rollout_started_at]
    end

    update :clear_rollout_override do
      require_atomic? false
      accept [:rollout_package_id, :rollout_id, :rollout_started_at]
    end

    update :promote_rollout do
      require_atomic? false
      accept [:addon_package_id, :rollout_package_id, :rollout_id, :rollout_started_at]

      change SetAssignmentAddonId
      change ApplyAddonConfigDefaults
      validate AddonPackageApproved
      validate AddonAssignmentParams
    end

    update :restore_managed_update_policy do
      description "Restore a non-explicit trusted first-party source to managed updates."
      require_atomic? false
      accept [:update_policy, :capability_ceiling]
    end

    update :issue_direct_access do
      description "Issue a short-lived assignment-scoped direct-leaf identity"
      require_atomic? false
      accept []
      argument :validity_days, :integer, allow_nil?: false, default: 30
      change IssueDirectLeafAccess
    end

    update :mark_direct_access_ready do
      description "Mark issued direct-leaf material ready after leaf ACL rollout"
      require_atomic? false
      accept []
      argument :generation, :integer, allow_nil?: false

      change fn changeset, _context ->
        generation = Ash.Changeset.get_argument(changeset, :generation)
        current_generation = Ash.Changeset.get_attribute(changeset, :direct_access_generation)
        status = Ash.Changeset.get_attribute(changeset, :direct_access_status)

        material_present? =
          Enum.all?(
            [
              :encrypted_direct_certificate_pem,
              :encrypted_direct_private_key_pem,
              :encrypted_direct_ca_chain_pem
            ],
            &(is_binary(Ash.Changeset.get_attribute(changeset, &1)) and
                byte_size(Ash.Changeset.get_attribute(changeset, &1)) > 0)
          )

        if status == :pending and generation == current_generation and material_present? do
          changeset
          |> Ash.Changeset.change_attribute(:direct_access_status, :ready)
          |> Ash.Changeset.change_attribute(:direct_access_error, nil)
        else
          Ash.Changeset.add_error(changeset,
            field: :direct_access_generation,
            message: "direct-leaf material is not pending for the requested generation"
          )
        end
      end
    end

    update :revoke_direct_access do
      description "Revoke the add-on-scoped direct-leaf identity"
      require_atomic? false
      accept []
      argument :reason, :string, allow_nil?: true
      change RevokeDirectLeafAccess
    end
  end

  policies do
    import ServiceRadar.Plugins.Policies

    # The managed-policy repair action is coordinator-internal and therefore
    # relies on the SystemActor bypass. Human/API plugin managers retain the
    # ordinary assignment and explicit rollout actions only.
    manage_actions([
      :create,
      :update,
      :destroy,
      :apply_rollout_override,
      :clear_rollout_override,
      :promote_rollout
    ])

    policy action([:issue_direct_access, :mark_direct_access_ready, :revoke_direct_access]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :addon_id, :string do
      allow_nil? false
      public? true

      description "Denormalized add-on identifier used to enforce one enabled assignment per agent/add-on."
    end

    attribute :addon_package_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :edge_site_id, :uuid do
      allow_nil? true
      public? true

      description "Registered edge site whose local NATS leaf is authorized for direct add-on output"
    end

    attribute :direct_subject_scope, :map do
      allow_nil? false
      public? true
      default %{}
      description "Derived publish/subscribe subjects for the direct-leaf identity"
    end

    attribute :direct_access_status, :atom do
      allow_nil? false
      public? true
      default :not_requested
      constraints one_of: [:not_requested, :pending, :ready, :revoked, :expired]
      description "Lifecycle state of the add-on-scoped direct-leaf identity"
    end

    attribute :direct_access_generation, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "Monotonic generation used to rotate direct-leaf identity material"
    end

    attribute :direct_access_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Expiry of the currently issued direct-leaf identity"
    end

    attribute :direct_access_revoked_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the direct-leaf identity was revoked"
    end

    attribute :direct_access_error, :string do
      allow_nil? true
      public? true
      description "Actionable reason why direct-leaf identity preparation is pending"
    end

    # Declared as the PLAINTEXT they are. The `cloak` block above rewrites each of these into an
    # `encrypted_*` :binary attribute holding ciphertext, plus a decrypting calculation that
    # keeps this name. Nothing writes these names directly -- use AshCloak.encrypt_and_set/3,
    # and clear via the `encrypted_*` attribute.
    attribute :direct_certificate_pem, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Assignment-scoped direct-leaf certificate"
    end

    attribute :direct_private_key_pem, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "Assignment-scoped direct-leaf private key"
    end

    attribute :direct_ca_chain_pem, :string do
      allow_nil? true
      public? false
      sensitive? true
      description "CA chain for the assignment-scoped direct leaf identity"
    end

    attribute :direct_certificate_fingerprint, :string do
      allow_nil? true
      public? true
      description "Fingerprint of the currently issued direct-leaf certificate"
    end

    attribute :direct_identity_component_id, :string do
      allow_nil? true
      public? false
      description "Gateway certificate component identifier for the direct identity"
    end

    attribute :direct_identity_partition_id, :string do
      allow_nil? true
      public? false
      description "Authenticated partition used for the direct identity"
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :manual
      constraints one_of: [:manual, :policy, :profile]
    end

    attribute :source_key, :string do
      allow_nil? true
      public? true
    end

    attribute :addon_profile_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :params, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :args, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :profile_reconcile_status, :string do
      allow_nil? true
      public? true
    end

    attribute :profile_reconcile_error, :string do
      allow_nil? true
      public? true
    end

    attribute :profile_last_reconciled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :profile_metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :update_policy, :atom do
      allow_nil? false
      public? true
      default :manual_pin
      constraints one_of: [:manual_pin, :track_latest_approved]
    end

    attribute :explicit_version_pin, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :release_channel, :string do
      allow_nil? false
      public? true
      default "stable"
    end

    attribute :capability_ceiling, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :rollout_policy, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :rollout_package_id, :uuid, public?: true
    attribute :rollout_id, :uuid, public?: true
    attribute :rollout_started_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :addon_package, AddonPackage do
      allow_nil? false
      public? true
      destination_attribute :id
      source_attribute :addon_package_id
      define_attribute? false
    end

    belongs_to :edge_site, ServiceRadar.Edge.EdgeSite do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :edge_site_id
      define_attribute? false
    end

    belongs_to :addon_profile, ServiceRadar.Plugins.AddonProfile do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :addon_profile_id
      define_attribute? false
    end

    belongs_to :rollout_package, AddonPackage do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :rollout_package_id
      define_attribute? false
    end

    belongs_to :rollout, ServiceRadar.Plugins.AddonRollout do
      allow_nil? true
      public? true
      destination_attribute :id
      source_attribute :rollout_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_source_key, [:source, :source_key]
  end
end
