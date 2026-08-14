defmodule ServiceRadar.Edge.OnboardingPackage do
  @moduledoc """
  Edge onboarding package resource with state machine lifecycle.

  Manages the lifecycle of edge deployment packages through states:
  - `issued` -> `delivered` -> `activated`
  - `issued` -> `revoked`
  - `issued` -> `expired` (automatic)
  - `delivered` -> `revoked`
  - Any state -> `deleted` (soft delete)

  ## Component Types

  - `:gateway` - Agent gateway component
  - `:agent` - Agent component
  - `:checker` - Checker component
  - `:sync` - Sync service component

  ## Security Modes

  - `:spire` - SPIFFE/SPIRE workload identity
  - `:mtls` - Manual mTLS certificate management
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban, AshCloak]

  @package_fields [
    :label,
    :component_id,
    :component_type,
    :parent_type,
    :parent_id,
    :gateway_id,
    :partition_id,
    :site,
    :security_mode,
    :selectors,
    :checker_kind,
    :checker_config_json,
    :metadata_json,
    :notes,
    :created_by,
    :downstream_spiffe_id
  ]
  @token_fields [
    :join_token_ciphertext,
    :join_token_expires_at,
    :bundle_ciphertext,
    :download_token_hash,
    :download_token_expires_at,
    :downstream_spiffe_id,
    :downstream_entry_id
  ]
  @metadata_fields [:metadata_json]
  @activation_fields [:activated_from_ip, :last_seen_spiffe_id]
  @soft_delete_fields [:deleted_by, :deleted_reason]
  @admin_only_actions [:activate, :revoke, :soft_delete]
  @operator_actions [:deliver, :update_tokens, :update_metadata]

  postgres do
    table "edge_onboarding_packages"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:issued]
    default_initial_state :issued
    state_attribute :status

    transitions do
      transition :deliver, from: :issued, to: :delivered
      transition :activate, from: :delivered, to: :activated
      transition :revoke, from: [:issued, :delivered], to: :revoked
      transition :expire, from: [:issued, :delivered], to: :expired

      transition :soft_delete,
        from: [:issued, :delivered, :activated, :revoked, :expired],
        to: :deleted
    end
  end

  oban do
    triggers do
      # Scheduled trigger for expiring packages with expired tokens
      trigger :expire_packages do
        queue :onboarding
        extra_args &ServiceRadar.Oban.AshObanQueueResolver.job_meta/1
        read_action :needs_expiration
        scheduler_cron "0 * * * *"
        action :expire

        scheduler_module_name ServiceRadar.Edge.OnboardingPackage.ExpirePackagesScheduler
        worker_module_name ServiceRadar.Edge.OnboardingPackage.ExpirePackagesWorker
      end
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    # Encrypted at rest; only decrypted when the bundle download endpoint
    # asks for it via ServiceRadar.Vault.decrypt/1.
    attributes([:nats_creds_ciphertext])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    read :by_status do
      argument :status, :atom, allow_nil?: false
      filter expr(status == ^arg(:status))
    end

    read :active do
      description "Packages that can still be used (issued or delivered)"
      filter expr(status in [:issued, :delivered])
    end

    read :by_site do
      argument :site, :string, allow_nil?: false
      filter expr(site == ^arg(:site))
    end

    read :by_partition do
      argument :partition_id, :string, allow_nil?: false
      filter expr(partition_id == ^arg(:partition_id))
    end

    read :with_legacy_nats do
      description "Packages that still retain legacy NATS credential material"
      filter expr(not is_nil(nats_credential_id) or not is_nil(nats_creds_ciphertext))
    end

    read :needs_expiration do
      description "Packages with expired tokens that need to be marked as expired"
      # Find packages that are still "issued" but both tokens have expired
      filter expr(
               status == :issued and
                 download_token_expires_at < now() and
                 join_token_expires_at < now()
             )

      pagination keyset?: true, default_limit: 100
    end

    create :create do
      accept @package_fields
    end

    update :update_tokens do
      description "Update token fields after generation"

      accept @token_fields
    end

    update :update_metadata do
      description "Update metadata fields for the package"
      accept @metadata_fields
    end

    update :attach_nats_creds do
      description "Attach legacy NATS creds for an explicitly provisioned transport."

      # Encrypts via AshCloak and sets a relationship FK in one transition.
      require_atomic? false
      accept []

      argument :nats_credential_id, :uuid, allow_nil?: false
      argument :nats_creds_content, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _context ->
        creds_content = Ash.Changeset.get_argument(changeset, :nats_creds_content)
        credential_id = Ash.Changeset.get_argument(changeset, :nats_credential_id)

        changeset
        |> Ash.Changeset.change_attribute(:nats_credential_id, credential_id)
        |> AshCloak.encrypt_and_set(:nats_creds_ciphertext, creds_content)
      end
    end

    update :clear_legacy_nats do
      description "Remove legacy NATS credential material after migration review"
      require_atomic? false
      accept []

      argument :reason, :string, allow_nil?: false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:nats_credential_id, nil)
        |> Ash.Changeset.force_change_attribute(:nats_creds_ciphertext, nil)
        |> Ash.Changeset.change_attribute(:legacy_nats_cleanup_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(
          :legacy_nats_cleanup_reason,
          Ash.Changeset.get_argument(changeset, :reason)
        )
      end
    end

    update :deliver do
      description "Mark package as delivered (downloaded)"
      change transition_state(:delivered)
      change set_attribute(:delivered_at, &__MODULE__.utc_now_second/0)
      change set_attribute(:download_token_consumed_at, &__MODULE__.utc_now_second/0)
    end

    update :activate do
      description "Mark package as activated (edge component running)"
      accept @activation_fields

      change transition_state(:activated)
      change set_attribute(:activated_at, &DateTime.utc_now/0)
    end

    update :revoke do
      description "Revoke an issued or delivered package"
      argument :reason, :string

      change transition_state(:revoked)
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :expire do
      description "Mark package as expired (automatic)"
      change transition_state(:expired)
    end

    update :soft_delete do
      description "Soft delete a package"
      accept @soft_delete_fields

      change transition_state(:deleted)
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    # Schema isolation is enforced by the DB connection's search_path.
    # Policies here only check role-based access.

    # Read access: Admins/operators can read
    read_operator_plus()

    # Create packages: Admins/operators can create
    operator_action(:create)

    # State transitions: Admins only (except deliver and update_tokens)
    admin_action(@admin_only_actions)

    # Expire action: Admins or AshOban scheduler (no actor)
    policy action(:expire) do
      authorize_if is_admin()
      # Allow AshOban scheduler (no actor) to expire packages
      authorize_if ServiceRadar.Policies.Checks.ActorIsNil
    end

    # Operators can also deliver and update tokens
    operator_action(@operator_actions)

    # Legacy credential removal is an explicit migration operation. It is not
    # available to operators or API callers because it irreversibly removes
    # the encrypted credential payload from the package.
    policy action(:clear_legacy_nats) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  changes do
  end

  attributes do
    uuid_primary_key :id, source: :package_id

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "Human-readable package label"
    end

    attribute :component_id, :string do
      public? true
      description "Target component identifier"
    end

    attribute :component_type, :atom do
      default :gateway
      public? true
      constraints one_of: [:gateway, :agent, :checker, :sync]
      description "Type of component being onboarded"
    end

    attribute :parent_type, :atom do
      public? true
      constraints one_of: [:gateway, :agent, :checker, :sync]
      description "Parent component type (for hierarchical components)"
    end

    attribute :parent_id, :string do
      public? true
      description "Parent component ID"
    end

    attribute :gateway_id, :string do
      public? true
      description "Associated gateway ID"
    end

    attribute :partition_id, :string do
      allow_nil? false
      default "default"
      public? true
      constraints min_length: 1, max_length: 255
      description "Network partition identifier"
    end

    attribute :site, :string do
      public? true
      description "Compatibility alias for partition_id"
    end

    attribute :status, :atom do
      allow_nil? false
      default :issued
      public? true
      constraints one_of: [:issued, :delivered, :activated, :revoked, :expired, :deleted]
      description "Current package lifecycle state"
    end

    attribute :security_mode, :atom do
      default :spire
      public? true
      constraints one_of: [:spire, :mtls]
      description "Security mode for edge identity"
    end

    attribute :downstream_entry_id, :string do
      description "SPIRE entry ID for downstream workload"
    end

    attribute :downstream_spiffe_id, :string do
      public? true
      description "SPIFFE ID for downstream workload"
    end

    attribute :selectors, {:array, :string} do
      default []
      public? true
      description "SPIRE selectors for workload attestation"
    end

    attribute :checker_kind, :string do
      public? true
      description "Checker type (for checker components)"
    end

    attribute :checker_config_json, :map do
      default %{}
      public? true
      description "Checker configuration"
    end

    attribute :join_token_ciphertext, :string do
      sensitive? true
      description "Encrypted SPIRE join token"
    end

    attribute :join_token_expires_at, :utc_datetime do
      description "Join token expiration time"
    end

    attribute :bundle_ciphertext, :string do
      sensitive? true
      description "Encrypted certificate bundle"
    end

    attribute :download_token_hash, :string do
      sensitive? true
      description "SHA256 hash of download token"
    end

    attribute :download_token_expires_at, :utc_datetime do
      description "Download token expiration time"
    end

    attribute :download_token_consumed_at, :utc_datetime do
      public? true
      description "When the single-use download token was consumed"
    end

    attribute :created_by, :string do
      default "system"
      public? true
      description "User who created the package"
    end

    attribute :delivered_at, :utc_datetime do
      public? true
      description "When package was downloaded"
    end

    attribute :activated_at, :utc_datetime do
      public? true
      description "When edge component activated"
    end

    attribute :activated_from_ip, :string do
      public? true
      description "IP address of activation request"
    end

    attribute :last_seen_spiffe_id, :string do
      public? true
      description "Last observed SPIFFE ID"
    end

    attribute :revoked_at, :utc_datetime do
      public? true
      description "When package was revoked"
    end

    attribute :deleted_at, :utc_datetime do
      public? true
      description "When package was soft deleted"
    end

    attribute :deleted_by, :string do
      public? true
      description "User who deleted the package"
    end

    attribute :deleted_reason, :string do
      public? true
      description "Reason for deletion"
    end

    attribute :metadata_json, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :kv_revision, :integer do
      description "Datasvc KV store revision"
    end

    attribute :nats_credential_id, :uuid do
      allow_nil? true
      public? false
      description "Associated per-agent flow-collector NATS credential (for revocation)"
    end

    attribute :nats_creds_ciphertext, :binary do
      allow_nil? true
      public? false
      sensitive? true
      description "Encrypted per-agent flow-collector NATS .creds file content"
    end

    attribute :legacy_nats_cleanup_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When legacy NATS credential material was removed"
    end

    attribute :legacy_nats_cleanup_reason, :string do
      allow_nil? true
      public? true
      description "Audit reason for removing legacy NATS credential material"
    end

    attribute :notes, :string do
      public? true
      description "Admin notes"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :events, ServiceRadar.Edge.OnboardingEvent do
      destination_attribute :package_id
    end

    belongs_to :nats_credential, ServiceRadar.Edge.NatsCredential do
      source_attribute :nats_credential_id
      allow_nil? true
    end
  end

  calculations do
    calculate :is_usable, :boolean, expr(status in [:issued, :delivered])

    calculate :is_terminal, :boolean, expr(status in [:activated, :revoked, :expired, :deleted])

    calculate :download_expired,
              :boolean,
              expr(not is_nil(download_token_expires_at) and download_token_expires_at < now())
  end

  @doc false
  def utc_now_second do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
