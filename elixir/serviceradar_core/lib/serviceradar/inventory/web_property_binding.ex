defmodule ServiceRadar.Inventory.WebPropertyBinding do
  @moduledoc """
  Connects an L7 `WebProperty` to underlying L3/L4 infrastructure:
  - `:k8s_public_endpoint` (Gateway / HTTPRoute / Ingress / LoadBalancer)
  - `:origin_device` (direct non-CDN `Device` in `platform.ocsf_devices`)
  - `:otel_service` (OTel `service.name` correlation)
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Inventory.Validations.WebPropertyBindingKind
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @read_permission {ActorHasPermission, permission: "devices.view"}
  @manage_permission {ActorHasPermission, permission: "settings.networks.manage"}

  @create_fields [
    :web_property_id,
    :binding_kind,
    :source,
    :cluster_id,
    :namespace,
    :resource_kind,
    :resource_name,
    :endpoint_key,
    :device_uid,
    :otel_service_name,
    :metadata,
    :last_observed_at
  ]

  @update_fields [:source, :endpoint_key, :metadata, :last_observed_at]

  postgres do
    table "web_property_bindings"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :binding_kind, "web_property_bindings_valid",
        message: "must satisfy binding kind consistency constraints"
    end
  end

  code_interface do
    define :list_by_web_property, action: :by_web_property, args: [:web_property_id]
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read, :destroy]

    read :by_web_property do
      argument :web_property_id, :uuid, allow_nil?: false
      filter expr(web_property_id == ^arg(:web_property_id))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end

    create :create do
      accept @create_fields
      validate WebPropertyBindingKind
    end

    update :update do
      accept @update_fields
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@read_permission)
    action_type_with_permission([:create, :update, :destroy], @manage_permission)
  end

  attributes do
    uuid_primary_key :id

    attribute :web_property_id, :uuid do
      allow_nil? false
      public? true
      description "Parent WebProperty UUID"
    end

    attribute :binding_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:k8s_public_endpoint, :origin_device, :otel_service]
      description "Infrastructure binding kind"
    end

    attribute :source, :atom do
      allow_nil? false
      default :manual
      public? true
      constraints one_of: [:manual, :k8s_discovery, :auto_vip_match, :trace_correlation]
      description "How this binding was established"
    end

    attribute :cluster_id, :string do
      public? true
      description "Kubernetes cluster_id for k8s_public_endpoint bindings"
    end

    attribute :namespace, :string do
      public? true
      description "Kubernetes namespace for k8s_public_endpoint bindings"
    end

    attribute :resource_kind, :string do
      public? true
      description "Kubernetes resource kind (HTTPRoute, Ingress, Service)"
    end

    attribute :resource_name, :string do
      public? true
      description "Kubernetes resource name"
    end

    attribute :endpoint_key, :string do
      public? true
      description "Optional key from platform.public_endpoints_current"
    end

    attribute :device_uid, :string do
      public? true
      description "Optional origin Device UID from platform.ocsf_devices"
    end

    attribute :otel_service_name, :string do
      public? true
      description "Optional OpenTelemetry service.name"
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
      description "Additional binding metadata"
    end

    attribute :last_observed_at, :utc_datetime_usec do
      public? true
      description "Most recent observation timestamp for discovered bindings"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :web_property, ServiceRadar.Inventory.WebProperty do
      source_attribute :web_property_id
      destination_attribute :id
      define_attribute? false
      allow_nil? false
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      define_attribute? false
      allow_nil? true
      public? true
    end
  end
end
