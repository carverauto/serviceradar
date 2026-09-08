defmodule ServiceRadar.Edge.RemoteAccessTcpTarget do
  @moduledoc """
  Trusted raw TCP target registration for agent-routed remote access.

  TCP access is intentionally separate from HTTP application access so generic
  forwarding cannot be created by browser-supplied host or port overrides.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_permission "settings.remote_access_targets.manage"
  @open_permission "devices.remote_access.tcp.open"
  @manage_check {ActorHasPermission, permission: @manage_permission}
  @open_check {ActorHasPermission, permission: @open_permission}

  @create_fields [
    :name,
    :description,
    :device_uid,
    :enabled,
    :agent_id,
    :gateway_id,
    :upstream_host,
    :upstream_port,
    :protocol_name,
    :idle_timeout_seconds,
    :absolute_timeout_seconds,
    :quota_policy,
    :approval_policy,
    :recording_policy,
    :enhanced_recording_policy,
    :metadata
  ]

  postgres do
    table "remote_access_tcp_targets"
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

    attribute :upstream_host, :string do
      allow_nil? false
      public? true
    end

    attribute :upstream_port, :integer do
      allow_nil? false
      constraints min: 1, max: 65_535
      public? true
    end

    attribute :protocol_name, :string do
      allow_nil? false
      default "tcp"
      public? true
    end

    attribute :idle_timeout_seconds, :integer do
      allow_nil? false
      constraints min: 1
      default 900
      public? true
    end

    attribute :absolute_timeout_seconds, :integer do
      allow_nil? false
      constraints min: 1
      default 3600
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
