defmodule ServiceRadar.Credentials.NetworkCredentialRule do
  @moduledoc """
  Binds an encrypted credential to an SRQL target query and edge scope.

  Rules are ordered by priority per provider. A lower priority value wins when
  multiple enabled rules match a target.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Credentials.Changes.GuardCredentialRuleLifecycle
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Credentials.NetworkCredentialRuleTestDispatcher
  alias ServiceRadar.Credentials.NetworkCredentialRuleTestPlan
  alias ServiceRadar.Credentials.Validations.TargetQuery
  alias ServiceRadar.Credentials.Validations.TrustMaterial
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  @fields [
    :name,
    :description,
    :enabled,
    :priority,
    :provider,
    :auth_method,
    :purpose,
    :target_query,
    :scope_type,
    :scope_value,
    :secret_id,
    :allowed_ports,
    :tls_policy,
    :ssh_host_key_policy,
    :ca_bundle_pem,
    :server_cert_fingerprint,
    :metadata
  ]

  postgres do
    table "network_credential_rules"
    repo ServiceRadar.Repo
    schema "platform"

    foreign_key_names [
      {:id, "proxmox_console_sessions_credential_rule_id_fkey", "credential_rule_in_use"},
      {:id, "remote_access_sessions_credential_rule_id_fkey", "credential_rule_in_use"},
      {:id, "remote_access_requests_credential_rule_id_fkey", "credential_rule_in_use"},
      {:id, "remote_access_desktop_targets_credential_rule_id_fkey", "credential_rule_in_use"}
    ]

    references do
      reference :secret, on_delete: :restrict
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "network_credential_rule_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :retained_versions, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? true
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]

    define :list_enabled_for_scope,
      action: :enabled_for_scope,
      args: [:provider, :scope_type, :scope_value]

    define :create_rule, action: :create
    define :update_rule, action: :update
    define :destroy_rule, action: :destroy
    define :preview, action: :preview, args: [:id]
    define :proxmox_api_test_plan, action: :proxmox_api_test_plan, args: [:id]
    define :dispatch_proxmox_api_test, action: :dispatch_proxmox_api_test, args: [:id]
    define :record_test_result, action: :record_test_result
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled_for_scope do
      argument :provider, :string, allow_nil?: false
      argument :scope_type, :atom, allow_nil?: false
      argument :scope_value, :string, allow_nil?: false

      filter expr(
               provider == ^arg(:provider) and enabled == true and scope_type == ^arg(:scope_type) and
                 scope_value == ^arg(:scope_value)
             )

      prepare build(sort: [priority: :asc, inserted_at: :asc])
    end

    create :create do
      accept @fields
      validate TargetQuery
      validate TrustMaterial
    end

    update :update do
      accept @fields
      validate TargetQuery
      validate TrustMaterial
    end

    update :enable do
      change set_attribute(:enabled, true)
    end

    update :disable do
      change set_attribute(:enabled, false)
    end

    destroy :destroy do
      change {GuardCredentialRuleLifecycle, mode: :destroy}
    end

    update :record_test_result do
      accept [:last_test_status, :last_test_message]
      change set_attribute(:last_tested_at, &DateTime.utc_now/0)
    end

    action :preview do
      argument :id, :uuid, allow_nil?: false
      argument :sample_limit, :integer, allow_nil?: true, default: 10

      run fn input, context ->
        NetworkCredentialRulePreview.preview_by_id(
          input.arguments.id,
          sample_limit: input.arguments.sample_limit,
          actor: context.actor
        )
      end
    end

    action :proxmox_api_test_plan do
      argument :id, :uuid, allow_nil?: false

      run fn input, context ->
        NetworkCredentialRuleTestPlan.proxmox_api_test_by_id(
          input.arguments.id,
          actor: context.actor
        )
      end
    end

    action :dispatch_proxmox_api_test do
      argument :id, :uuid, allow_nil?: false

      run fn input, context ->
        NetworkCredentialRuleTestDispatcher.dispatch_proxmox_api_test_by_id(
          input.arguments.id,
          actor: context.actor
        )
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)
    action_type_with_permission([:create, :update, :destroy], @credential_manage_check)
    action_with_permission(:preview, @credential_manage_check)
    action_with_permission(:proxmox_api_test_plan, @credential_manage_check)
    action_with_permission(:dispatch_proxmox_api_test, @credential_manage_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :integration_id, :uuid do
      allow_nil? false
      public? true
      default &Ecto.UUID.generate/0

      description "Immutable identity of the configured integration scope"
    end

    attribute :controller_id, :uuid do
      allow_nil? false
      public? true
      default &Ecto.UUID.generate/0

      description "Immutable identity of the configured controller scope"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      description "Package-declared integration provider identifier"
    end

    attribute :auth_method, :string do
      allow_nil? false
      public? true
      description "Package-declared authentication method identifier"
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
      description "Package-declared primary credential purpose identifier"
    end

    attribute :target_query, :string do
      allow_nil? false
      public? true
      description "SRQL device query that defines where this credential rule applies"
    end

    attribute :scope_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:agent, :gateway, :partition]
    end

    attribute :scope_value, :string do
      allow_nil? false
      public? true
      description "Agent ID, gateway ID, or partition name for the selected scope type"
    end

    attribute :secret_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :allowed_ports, {:array, :integer} do
      allow_nil? false
      public? true
      default []
    end

    attribute :tls_policy, :atom do
      allow_nil? false
      public? true
      default :verify
      constraints one_of: [:verify, :skip_verify]
    end

    attribute :ssh_host_key_policy, :atom do
      allow_nil? false
      public? true
      default :known_hosts
      constraints one_of: [:known_hosts, :trust_on_first_use, :skip_verify]
    end

    # Trust anchors, not secrets: publishing a CA certificate reveals nothing,
    # and keeping them on the rule lets an operator read back what a rule
    # trusts. See Validations.TrustMaterial.
    attribute :ca_bundle_pem, :string do
      allow_nil? true
      public? true
    end

    attribute :server_cert_fingerprint, :string do
      allow_nil? true
      public? true
    end

    attribute :last_test_status, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:success, :failed, :timeout, :skipped]
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

  relationships do
    belongs_to :secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? false
      public? true
      source_attribute :secret_id
      destination_attribute :id
      define_attribute? false
    end
  end

  identities do
    identity :unique_scoped_name, [:provider, :scope_type, :scope_value, :name]
    identity :unique_integration_id, [:integration_id]
    identity :unique_controller_id, [:controller_id]
  end
end
