defmodule ServiceRadar.Credentials.CredentialSecretProvider do
  @moduledoc """
  External secret server connection metadata.

  Provider records describe where credential references can be resolved and from
  which ServiceRadar location. They do not expose provider bootstrap secrets.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Credentials.Changes.WriteProviderLifecycleEvent
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  @fields [
    :name,
    :description,
    :provider_type,
    :endpoint_url,
    :auth_mode,
    :resolution_locations,
    :metadata
  ]

  postgres do
    table "credential_secret_providers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  state_machine do
    initial_states [:disabled]
    default_initial_state :disabled
    state_attribute :status

    transitions do
      transition :enable, from: [:disabled, :degraded, :unavailable], to: :active
      transition :disable, from: [:active, :degraded, :unavailable], to: :disabled

      transition :record_test_failure,
        from: [:disabled, :active, :degraded, :unavailable],
        to: :degraded

      transition :record_test_unavailable,
        from: [:disabled, :active, :degraded, :unavailable],
        to: :unavailable

      transition :record_test_success,
        from: [:disabled, :active, :degraded, :unavailable],
        to: :active
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "credential_secret_provider_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_by_type, action: :by_type, args: [:provider_type]
    define :create_provider, action: :create
    define :update_provider, action: :update
    define :enable, action: :enable
    define :disable, action: :disable
    define :record_test_success, action: :record_test_success
    define :record_test_failure, action: :record_test_failure
    define :record_test_unavailable, action: :record_test_unavailable
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_type do
      argument :provider_type, :string, allow_nil?: false
      filter expr(provider_type == ^arg(:provider_type))
    end

    create :create do
      accept @fields
    end

    update :update do
      accept @fields
    end

    update :enable do
      accept []
      change transition_state(:active)
      change set_attribute(:enabled, true)
      change {WriteProviderLifecycleEvent, action: :enable}
    end

    update :disable do
      accept [:last_test_message]
      change transition_state(:disabled)
      change set_attribute(:enabled, false)
      change {WriteProviderLifecycleEvent, action: :disable}
    end

    update :record_test_success do
      accept [:last_test_message]
      change transition_state(:active)
      change set_attribute(:enabled, true)
      change set_attribute(:last_test_status, :success)
      change set_attribute(:last_tested_at, &DateTime.utc_now/0)
      change {WriteProviderLifecycleEvent, action: :record_test_success}
    end

    update :record_test_failure do
      accept [:last_test_message]
      change transition_state(:degraded)
      change set_attribute(:last_test_status, :failed)
      change set_attribute(:last_tested_at, &DateTime.utc_now/0)
      change {WriteProviderLifecycleEvent, action: :record_test_failure}
    end

    update :record_test_unavailable do
      accept [:last_test_message]
      change transition_state(:unavailable)
      change set_attribute(:last_test_status, :unavailable)
      change set_attribute(:last_tested_at, &DateTime.utc_now/0)
      change {WriteProviderLifecycleEvent, action: :record_test_unavailable}
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)
    action_type_with_permission([:create, :update], @credential_manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :provider_type, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :stub,
                    :delinea,
                    :cyberark,
                    :vault,
                    :openbao,
                    :aws_secrets_manager,
                    :azure_key_vault,
                    :gcp_secret_manager,
                    :custom_future
                  ]
    end

    attribute :endpoint_url, :string do
      allow_nil? true
      public? true
    end

    attribute :auth_mode, :atom do
      allow_nil? false
      public? true
      default :deployment_secret
      constraints one_of: [:deployment_secret, :internal_credential, :workload_identity]
    end

    attribute :resolution_locations, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: [:control_plane, :agent, :hybrid]]
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :disabled
      constraints one_of: [:disabled, :active, :degraded, :unavailable]
    end

    attribute :last_test_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:success, :failed, :unavailable]
    end

    attribute :last_tested_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_test_message, :string do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
