defmodule ServiceRadar.Credentials.CredentialSecretResolutionAudit do
  @moduledoc """
  Redacted audit metadata for credential broker resolution attempts.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  @fields [
    :secret_id,
    :secret_provider_id,
    :grant_id,
    :consumer_kind,
    :consumer_id,
    :purpose,
    :target_kind,
    :target_id,
    :agent_id,
    :resolution_location,
    :outcome,
    :error_class,
    :cache_status,
    :lease_expires_at,
    :metadata,
    :occurred_at
  ]

  postgres do
    table "credential_secret_resolution_audits"
    repo ServiceRadar.Repo
    schema "platform"
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "credential_secret_resolution_audit_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :mixin, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at]
  end

  code_interface do
    define :create_audit, action: :create
    define :list_for_secret, action: :for_secret, args: [:secret_id]
    define :list_for_provider, action: :for_provider, args: [:secret_provider_id]
  end

  actions do
    read :read do
      prepare build(sort: [occurred_at: :desc])
    end

    read :for_secret do
      argument :secret_id, :uuid, allow_nil?: false
      filter expr(secret_id == ^arg(:secret_id))
      prepare build(sort: [occurred_at: :desc])
    end

    read :for_provider do
      argument :secret_provider_id, :uuid, allow_nil?: false
      filter expr(secret_provider_id == ^arg(:secret_provider_id))
      prepare build(sort: [occurred_at: :desc])
    end

    create :create do
      accept @fields

      change set_attribute(
               :occurred_at,
               &ServiceRadar.Credentials.CredentialSecretResolutionAudit.utc_now/0
             )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :secret_provider_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :grant_id, :string do
      allow_nil? true
      public? true
    end

    attribute :consumer_kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :plugin,
                    :mapper,
                    :discovery,
                    :snmp,
                    :remote_access,
                    :device_task,
                    :ansible,
                    :northbound_action,
                    :service_monitoring,
                    :test
                  ]
    end

    attribute :consumer_id, :string do
      allow_nil? true
      public? true
    end

    attribute :purpose, :string do
      allow_nil? true
      public? true
    end

    attribute :target_kind, :string do
      allow_nil? true
      public? true
    end

    attribute :target_id, :string do
      allow_nil? true
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
    end

    attribute :resolution_location, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:control_plane, :agent, :hybrid]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:success, :failed, :denied, :cache_hit]
    end

    attribute :error_class, :atom do
      allow_nil? true
      public? true

      constraints one_of: [
                    :not_found,
                    :unauthorized,
                    :unreachable,
                    :rate_limited,
                    :bad_field_mapping,
                    :provider_policy_denied,
                    :adapter_unavailable,
                    :invalid_reference,
                    :internal_error
                  ]
    end

    attribute :cache_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:miss, :hit, :disabled, :bypass]
    end

    # Keep seconds precision here because AshPaperTrail 0.5.7 copies tracked
    # datetime attributes to version resources that use :utc_datetime.
    attribute :lease_expires_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :occurred_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? true
      public? true
      source_attribute :secret_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :secret_provider, ServiceRadar.Credentials.CredentialSecretProvider do
      allow_nil? true
      public? true
      source_attribute :secret_provider_id
      destination_attribute :id
      define_attribute? false
    end
  end

  def utc_now do
    DateTime.truncate(DateTime.utc_now(), :second)
  end
end
