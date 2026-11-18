defmodule ServiceRadar.Inventory.WebProperty do
  @moduledoc """
  L7 Web Property inventory resource (`platform.web_properties`).

  Models web applications, domains, and public origins separately from
  L2/L3 `Device` (`platform.ocsf_devices`) and DIRE (`Identity.*`) so shared
  CDN/Anycast VIPs and multi-tenant gateways never collapse distinct sites or
  pollute physical device inventory.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    notifiers: [ServiceRadar.Inventory.WebPropertyNotifier],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Inventory.Changes.NormalizeWebProperty
  alias ServiceRadar.Inventory.Changes.RotateRumSiteKey
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @read_permission {ActorHasPermission, permission: "devices.view"}
  @manage_permission {ActorHasPermission, permission: "settings.networks.manage"}

  @web_property_fields [
    :name,
    :canonical_origin,
    :allowed_origins,
    :allowed_query_keys,
    :trace_propagate_origins,
    :environment,
    :tags,
    :prefix_tags,
    :rum_enabled,
    :rum_site_key,
    :rum_sample_rate,
    :anonymize_client_ip,
    :edge_provider
  ]

  @update_fields @web_property_fields -- [:rum_site_key]

  @posture_fields [
    :edge_provider,
    :observed_vips,
    :observed_asns,
    :tls_not_after,
    :tls_issuer,
    :last_posture_checked_at
  ]

  defdelegate normalize_canonical_origin(raw), to: NormalizeWebProperty
  defdelegate generate_rum_site_key(), to: NormalizeWebProperty
  defdelegate valid_rum_site_key?(key), to: NormalizeWebProperty

  postgres do
    table "web_properties"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :rum_sample_rate, "web_properties_valid",
        message: "must satisfy web property constraints"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_canonical_origin, action: :by_canonical_origin, args: [:canonical_origin]
    define :get_by_rum_site_key, action: :by_rum_site_key, args: [:rum_site_key]
  end

  actions do
    defaults [:read, :destroy]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_canonical_origin do
      argument :canonical_origin, :string, allow_nil?: false
      get? true
      filter expr(canonical_origin == ^arg(:canonical_origin))
    end

    read :by_rum_site_key do
      argument :rum_site_key, :string, allow_nil?: false
      get? true
      filter expr(rum_site_key == ^arg(:rum_site_key))
    end

    create :create do
      accept @web_property_fields
      change NormalizeWebProperty
    end

    update :update do
      accept @update_fields
      change NormalizeWebProperty
    end

    update :rotate_rum_site_key do
      description "Generate a new sr_rum_... site key, invalidating the previous key"
      accept []
      change RotateRumSiteKey
    end

    update :update_posture do
      description "Update observed TLS and edge/CDN posture fields"
      accept @posture_fields
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "Human-readable web property display name"
    end

    attribute :canonical_origin, :string do
      allow_nil? false
      public? true
      description "Normalized canonical origin (scheme://host[:port])"
    end

    attribute :allowed_origins, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Additional allowed CORS origins for RUM beacons"
    end

    attribute :allowed_query_keys, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Optional allowlist of non-PII query parameter keys preserved on RUM URLs"
    end

    attribute :trace_propagate_origins, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Opt-in cross-origin prefixes allowed for W3C traceparent injection"
    end

    attribute :environment, :atom do
      allow_nil? false
      default :production
      public? true
      constraints one_of: [:production, :staging, :development, :internal]
      description "Deployment environment classification"
    end

    attribute :tags, :map do
      allow_nil? false
      default %{}
      public? true
      description "Key-value tags for filtering and attribution"
    end

    attribute :prefix_tags, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Optional CIDR-to-site/region prefix rules for client IP enrichment"
    end

    attribute :rum_enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether Boomerang RUM ingestion is enabled for this property"
    end

    attribute :rum_site_key, :string do
      allow_nil? false
      public? true
      description "Public write-only RUM site key (sr_rum_...)"
    end

    attribute :rum_sample_rate, :float do
      allow_nil? false
      default 1.0
      public? true
      constraints min: 0.0, max: 1.0
      description "Client-side RUM sampling rate in [0.0, 1.0]"
    end

    attribute :anonymize_client_ip, :boolean do
      allow_nil? false
      default true
      public? true
      description "Truncate client IP (/24 IPv4, /48 IPv6) after prefix/ASN/Geo lookup"
    end

    attribute :edge_provider, :string do
      public? true
      description "Observed edge/CDN provider (akamai, cloudflare, fastly, envoy_gateway, direct)"
    end

    attribute :observed_vips, {:array, :string} do
      allow_nil? false
      default []
      public? true
      description "Observed DNS / Anycast / Gateway VIP addresses"
    end

    attribute :observed_asns, {:array, :integer} do
      allow_nil? false
      default []
      public? true
      description "Observed autonomous system numbers for VIPs"
    end

    attribute :tls_not_after, :utc_datetime_usec do
      public? true
      description "Leaf TLS certificate expiration timestamp"
    end

    attribute :tls_issuer, :string do
      public? true
      description "Leaf TLS certificate issuer common name / organization"
    end

    attribute :last_posture_checked_at, :utc_datetime_usec do
      public? true
      description "Timestamp of most recent TLS/DNS posture inspection"
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :bindings, ServiceRadar.Inventory.WebPropertyBinding do
      destination_attribute :web_property_id
      public? true
    end

    has_many :service_checks, ServiceRadar.Monitoring.ServiceCheck do
      destination_attribute :web_property_id
      public? true
    end
  end

  identities do
    identity :unique_canonical_origin, [:canonical_origin]
    identity :unique_rum_site_key, [:rum_site_key]
  end
end
