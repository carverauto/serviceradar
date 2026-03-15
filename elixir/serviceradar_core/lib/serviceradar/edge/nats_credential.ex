defmodule ServiceRadar.Edge.NatsCredential do
  @moduledoc """
  NATS credential resource for tracking issued collector credentials.

  This resource tracks NATS user credentials issued to edge collectors
  (flowgger, trapd, netflow, otel). Each credential is scoped to a specific
  account and can be revoked if compromised.

  ## Credential Types

  - `:collector` - For edge collectors (flowgger, trapd, netflow, otel)
  - `:service` - For internal services
  - `:admin` - For admin access (limited)

  ## Collector Types

  - `:flowgger` - Syslog collector
  - `:trapd` - SNMP trap collector
  - `:netflow` - NetFlow/sFlow/IPFIX collector
  - `:otel` - OpenTelemetry collector

  ## Status Values

  - `:active` - Credential is valid and in use
  - `:revoked` - Credential has been revoked
  - `:expired` - Credential has expired (if expiration was set)
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Edge.PubSub

  @credential_fields [:user_name, :credential_type, :collector_type, :expires_at, :metadata]

  postgres do
    table "nats_credentials"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:active]
    default_initial_state :active
    state_attribute :status

    transitions do
      transition :revoke, from: :active, to: :revoked
      transition :expire, from: :active, to: :expired
    end
  end

  actions do
    defaults [:read]

    read :active do
      description "Get active (non-revoked, non-expired) credentials"
      filter expr(status == :active)
    end

    read :by_collector_type do
      argument :collector_type, :atom, allow_nil?: false
      filter expr(collector_type == ^arg(:collector_type) and status == :active)
    end

    read :by_user_name do
      argument :user_name, :string, allow_nil?: false
      get? true
      filter expr(user_name == ^arg(:user_name))
    end

    create :create do
      description "Create a new NATS credential record"
      accept @credential_fields

      argument :user_public_key, :string, allow_nil?: false
      argument :onboarding_package_id, :uuid

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(
          :user_public_key,
          Ash.Changeset.get_argument(changeset, :user_public_key)
        )
        |> Ash.Changeset.change_attribute(
          :onboarding_package_id,
          Ash.Changeset.get_argument(changeset, :onboarding_package_id)
        )
        |> Ash.Changeset.change_attribute(:status, :active)
        |> Ash.Changeset.change_attribute(:issued_at, DateTime.utc_now())
        |> AfterAction.after_action(fn credential ->
          __MODULE__.broadcast_created(credential)
        end)
      end
    end

    update :revoke do
      description "Revoke a credential"
      # Non-atomic: sets multiple attributes and broadcasts event
      require_atomic? false
      accept []

      argument :reason, :string

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:status, :revoked)
        |> Ash.Changeset.change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(
          :revoke_reason,
          Ash.Changeset.get_argument(changeset, :reason)
        )
        |> AfterAction.after_action(fn credential ->
          __MODULE__.broadcast_revoked(credential)
        end)
      end
    end

    update :expire do
      description "Mark a credential as expired (state machine transition)"
      accept []
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    admin_action_type([:read, :create])
    admin_action(:revoke)
  end

  changes do
  end

  attributes do
    uuid_primary_key :id

    attribute :user_name, :string do
      allow_nil? false
      public? true
      description "Human-readable user/credential name"
    end

    attribute :user_public_key, :string do
      allow_nil? false
      public? false
      description "NATS user public key (starts with 'U')"
    end

    attribute :credential_type, :atom do
      allow_nil? false
      default :collector
      public? true
      constraints one_of: [:collector, :service, :admin]
      description "Type of credential"
    end

    attribute :collector_type, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:flowgger, :trapd, :netflow, :otel]
      description "Type of collector (if credential_type is :collector)"
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? true
      constraints one_of: [:active, :revoked, :expired]
      description "Current credential status"
    end

    attribute :issued_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the credential was issued"
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the credential expires (null = never)"
    end

    attribute :revoked_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      description "When the credential was revoked"
    end

    attribute :revoke_reason, :string do
      allow_nil? true
      public? false
      description "Reason for revocation"
    end

    attribute :onboarding_package_id, :uuid do
      allow_nil? true
      public? false
      description "Associated onboarding package (if any)"
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
      public? false
      description "Additional metadata (site, hostname, etc.)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :onboarding_package, ServiceRadar.Edge.OnboardingPackage do
      source_attribute :onboarding_package_id
      allow_nil? true
    end
  end

  calculations do
    calculate :is_valid?,
              :boolean,
              expr(
                status == :active and
                  (is_nil(expires_at) or expires_at > ^DateTime.utc_now())
              )
  end

  identities do
    identity :unique_user_public_key, [:user_public_key]
  end

  # PubSub broadcast helpers - delegates to ServiceRadar.Edge.PubSub

  @doc false
  def broadcast_created(credential) do
    PubSub.broadcast_credential_created(credential)
  end

  @doc false
  def broadcast_revoked(credential) do
    PubSub.broadcast_credential_revoked(credential)
  end
end
