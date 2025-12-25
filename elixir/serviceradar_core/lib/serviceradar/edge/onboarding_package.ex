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

  - `:poller` - Polling service component
  - `:agent` - Agent component
  - `:checker` - Checker component

  ## Security Modes

  - `:spire` - SPIFFE/SPIRE workload identity
  - `:mtls` - Manual mTLS certificate management
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "edge_onboarding_packages"
    repo ServiceRadar.Repo
  end

  oban do
    triggers do
      # Scheduled trigger for expiring packages with expired tokens
      trigger :expire_packages do
        queue :onboarding
        read_action :needs_expiration
        scheduler_cron "0 * * * *"
        action :expire

        scheduler_module_name ServiceRadar.Edge.OnboardingPackage.ExpirePackagesScheduler
        worker_module_name ServiceRadar.Edge.OnboardingPackage.ExpirePackagesWorker
      end
    end
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
      transition :soft_delete, from: [:issued, :delivered, :activated, :revoked, :expired], to: :deleted
    end
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
      default :poller
      public? true
      constraints one_of: [:poller, :agent, :checker]
      description "Type of component being onboarded"
    end

    attribute :parent_type, :atom do
      public? true
      constraints one_of: [:poller, :agent, :checker]
      description "Parent component type (for hierarchical components)"
    end

    attribute :parent_id, :string do
      public? true
      description "Parent component ID"
    end

    attribute :poller_id, :string do
      public? true
      description "Associated poller ID"
    end

    attribute :site, :string do
      public? true
      description "Site/location identifier"
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
      accept [
        :label, :component_id, :component_type, :parent_type, :parent_id,
        :poller_id, :site, :security_mode, :selectors, :checker_kind,
        :checker_config_json, :metadata_json, :notes, :created_by,
        :downstream_spiffe_id
      ]
    end

    update :update_tokens do
      description "Update token fields after generation"
      accept [
        :join_token_ciphertext, :join_token_expires_at, :bundle_ciphertext,
        :download_token_hash, :download_token_expires_at, :downstream_spiffe_id,
        :downstream_entry_id
      ]
    end

    update :deliver do
      description "Mark package as delivered (downloaded)"
      change transition_state(:delivered)
      change set_attribute(:delivered_at, &DateTime.utc_now/0)
    end

    update :activate do
      description "Mark package as activated (edge component running)"
      accept [:activated_from_ip, :last_seen_spiffe_id]

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
      accept [:deleted_by, :deleted_reason]

      change transition_state(:deleted)
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end
  end

  calculations do
    calculate :is_usable, :boolean, expr(status in [:issued, :delivered])

    calculate :is_terminal, :boolean, expr(status in [:activated, :revoked, :expired, :deleted])

    calculate :download_expired, :boolean, expr(
      not is_nil(download_token_expires_at) and download_token_expires_at < now()
    )
  end

  policies do
    # Super admins bypass all policies (platform-wide access)
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # TENANT ISOLATION: Onboarding packages contain credentials for edge deployments
    # CRITICAL: Must NEVER be accessible to other tenants

    # Read access: Admins/operators in same tenant
    policy action_type(:read) do
      authorize_if expr(
        ^actor(:role) in [:admin, :operator] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Create packages: Admins/operators in same tenant
    policy action(:create) do
      authorize_if expr(
        ^actor(:role) in [:admin, :operator] and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # State transitions: Admins in same tenant
    policy action([:deliver, :activate, :revoke, :soft_delete, :update_tokens]) do
      authorize_if expr(
        ^actor(:role) == :admin and
        tenant_id == ^actor(:tenant_id)
      )
    end

    # Expire action: Admins in same tenant, or AshOban (no actor)
    policy action(:expire) do
      authorize_if expr(
        ^actor(:role) == :admin and
        tenant_id == ^actor(:tenant_id)
      )
      # Allow AshOban scheduler (no actor) to expire packages
      authorize_if always()
    end

    # Operators can also deliver and update tokens (in same tenant)
    policy action([:deliver, :update_tokens]) do
      authorize_if expr(
        ^actor(:role) == :operator and
        tenant_id == ^actor(:tenant_id)
      )
    end
  end
end
