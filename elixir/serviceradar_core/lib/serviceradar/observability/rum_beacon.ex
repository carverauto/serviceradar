defmodule ServiceRadar.Observability.RumBeacon do
  @moduledoc """
  Read-only Ash resource backed by the `platform.rum_beacons` TimescaleDB hypertable.

  Schema lifecycle is owned by raw SQL migration (`CreateRumBeacons`), so
  `migrate?: false` is set here.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  postgres do
    table "rum_beacons"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  resource do
    require_primary_key? false
  end

  actions do
    defaults [:read]

    read :by_web_property do
      argument :web_property_id, :string, allow_nil?: false
      filter expr(web_property_id == ^arg(:web_property_id))
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if {ActorHasPermission, permission: "observability.metrics.view"}
    end
  end

  attributes do
    attribute :web_property_id, :string, allow_nil?: false, public?: true
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :beacon_id, :string, allow_nil?: false, public?: true
    attribute :canonical_origin, :string, public?: true
    attribute :environment, :string, public?: true
    attribute :url, :string, public?: true
    attribute :host, :string, public?: true
    attribute :path, :string, public?: true
    attribute :metric_path, :string, public?: true
    attribute :referrer, :string, public?: true
    attribute :page_group, :string, public?: true
    attribute :initiator, :string, public?: true
    attribute :trace_id, :string, public?: true
    attribute :span_id, :string, public?: true
    attribute :session_id, :string, public?: true
    attribute :user_agent, :string, public?: true
    attribute :device_type, :string, public?: true
    attribute :browser, :string, public?: true
    attribute :os, :string, public?: true
    attribute :lcp_ms, :float, public?: true
    attribute :inp_ms, :float, public?: true
    attribute :cls, :float, public?: true
    attribute :fcp_ms, :float, public?: true
    attribute :ttfb_ms, :float, public?: true
    attribute :page_load_ms, :float, public?: true
    attribute :dns_ms, :float, public?: true
    attribute :connect_ms, :float, public?: true
    attribute :tls_ms, :float, public?: true
    attribute :dom_ready_ms, :float, public?: true
    attribute :rage_clicks, :integer, default: 0, public?: true
    attribute :js_errors, :integer, default: 0, public?: true
    attribute :http_status, :integer, default: 0, public?: true
    attribute :has_error, :boolean, default: false, public?: true
    attribute :cdn_provider, :string, public?: true
    attribute :cdn_cache_status, :string, public?: true
    attribute :cdn_edge_rtt_ms, :float, public?: true
    attribute :cdn_origin_rtt_ms, :float, public?: true
    attribute :cdn_pop, :string, public?: true
    attribute :server_timing_raw, :string, public?: true
    attribute :client_ip, :string, public?: true
    attribute :client_ip_anonymized, :boolean, default: true, public?: true
    attribute :country, :string, public?: true
    attribute :region, :string, public?: true
    attribute :city, :string, public?: true
    attribute :asn, :integer, public?: true
    attribute :as_org, :string, public?: true
    attribute :prefix_tag, :string, public?: true
    attribute :attributes, :map, default: %{}, public?: true
    attribute :created_at, :utc_datetime_usec, public?: true
  end
end
