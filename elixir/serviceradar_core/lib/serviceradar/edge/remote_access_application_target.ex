defmodule ServiceRadar.Edge.RemoteAccessApplicationTarget do
  @moduledoc """
  Trusted HTTP/HTTPS application target registration for agent-routed remote access.

  Browser clients may select a target ID, but route, upstream, TLS, header,
  quota, approval, and recording policy are owned by this resource.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_permission "settings.remote_access_targets.manage"
  @open_permission "devices.remote_access.app.open"
  @manage_check {ActorHasPermission, permission: @manage_permission}
  @open_check {ActorHasPermission, permission: @open_permission}

  @create_fields [
    :name,
    :description,
    :device_uid,
    :enabled,
    :agent_id,
    :gateway_id,
    :upstream_scheme,
    :upstream_host,
    :upstream_port,
    :upstream_host_header,
    :upstream_sni,
    :tls_policy,
    :ca_bundle_ref,
    :allowed_methods,
    :allowed_path_prefixes,
    :header_policy,
    :cookie_policy,
    :quota_policy,
    :approval_policy,
    :recording_policy,
    :enhanced_recording_policy,
    :metadata
  ]

  postgres do
    table "remote_access_application_targets"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :create_target, action: :create
    define :update_target, action: :update
    define :destroy_target, action: :destroy
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept @create_fields
    end

    update :update do
      accept @create_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @manage_check
      authorize_if @open_check
    end

    action_type_with_permission([:create, :update, :destroy], @manage_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? false
      public? true
    end

    attribute :gateway_id, :string do
      public? true
    end

    attribute :upstream_scheme, :atom do
      allow_nil? false
      constraints one_of: [:http, :https]
      default :https
      public? true
    end

    attribute :upstream_host, :string do
      allow_nil? false
      public? true
    end

    attribute :upstream_port, :integer do
      allow_nil? false
      constraints min: 1, max: 65_535
      public? true
    end

    attribute :upstream_host_header, :string do
      public? true
    end

    attribute :upstream_sni, :string do
      public? true
    end

    attribute :tls_policy, :map do
      allow_nil? false
      default %{"verify" => "required"}
      public? true
    end

    attribute :ca_bundle_ref, :string do
      public? true
    end

    attribute :allowed_methods, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :allowed_path_prefixes, {:array, :string} do
      allow_nil? false
      default ["/"]
      public? true
    end

    attribute :header_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :cookie_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :quota_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :approval_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :recording_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :enhanced_recording_policy, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      public? true
      define_attribute? false
    end
  end
end
