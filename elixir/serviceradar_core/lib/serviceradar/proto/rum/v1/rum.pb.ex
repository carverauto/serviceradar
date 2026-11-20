defmodule Serviceradar.Rum.V1.RumPrefixTagRule do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.rum.v1.RumPrefixTagRule",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :cidr, 1, type: :string
  field :tag, 2, type: :string
end

defmodule Serviceradar.Rum.V1.WebPropertyRumPolicy do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.rum.v1.WebPropertyRumPolicy",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :web_property_id, 1, type: :string, json_name: "webPropertyId"
  field :name, 2, type: :string
  field :canonical_origin, 3, type: :string, json_name: "canonicalOrigin"
  field :allowed_origins, 4, repeated: true, type: :string, json_name: "allowedOrigins"
  field :allowed_query_keys, 5, repeated: true, type: :string, json_name: "allowedQueryKeys"

  field :trace_propagate_origins, 6,
    repeated: true,
    type: :string,
    json_name: "tracePropagateOrigins"

  field :rum_site_key, 7, type: :string, json_name: "rumSiteKey"
  field :rum_enabled, 8, type: :bool, json_name: "rumEnabled"
  field :rum_sample_rate, 9, type: :double, json_name: "rumSampleRate"
  field :anonymize_client_ip, 10, type: :bool, json_name: "anonymizeClientIp"
  field :environment, 11, type: :string

  field :prefix_tags, 12,
    repeated: true,
    type: Serviceradar.Rum.V1.RumPrefixTagRule,
    json_name: "prefixTags"
end

defmodule Serviceradar.Rum.V1.WebPropertyRumPolicySnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.rum.v1.WebPropertyRumPolicySnapshot",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :version, 1, type: :uint64
  field :generated_at_unix_ms, 2, type: :int64, json_name: "generatedAtUnixMs"
  field :properties, 3, repeated: true, type: Serviceradar.Rum.V1.WebPropertyRumPolicy

  field :global_prefix_tags, 4,
    repeated: true,
    type: Serviceradar.Rum.V1.RumPrefixTagRule,
    json_name: "globalPrefixTags"
end

defmodule Serviceradar.Rum.V1.RumBeaconV1.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.rum.v1.RumBeaconV1.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Rum.V1.RumBeaconV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.rum.v1.RumBeaconV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :beacon_id, 1, type: :string, json_name: "beaconId"
  field :observed_at_unix_ms, 2, type: :int64, json_name: "observedAtUnixMs"
  field :web_property_id, 3, type: :string, json_name: "webPropertyId"
  field :canonical_origin, 4, type: :string, json_name: "canonicalOrigin"
  field :environment, 5, type: :string
  field :url, 6, type: :string
  field :host, 7, type: :string
  field :path, 8, type: :string
  field :metric_path, 9, type: :string, json_name: "metricPath"
  field :referrer, 10, type: :string
  field :page_group, 11, type: :string, json_name: "pageGroup"
  field :initiator, 12, type: :string
  field :trace_id, 13, type: :string, json_name: "traceId"
  field :span_id, 14, type: :string, json_name: "spanId"
  field :session_id, 15, type: :string, json_name: "sessionId"
  field :user_agent, 16, type: :string, json_name: "userAgent"
  field :device_type, 17, type: :string, json_name: "deviceType"
  field :browser, 18, type: :string
  field :os, 19, type: :string
  field :lcp_ms, 20, proto3_optional: true, type: :double, json_name: "lcpMs"
  field :inp_ms, 21, proto3_optional: true, type: :double, json_name: "inpMs"
  field :cls, 22, proto3_optional: true, type: :double
  field :fcp_ms, 23, proto3_optional: true, type: :double, json_name: "fcpMs"
  field :ttfb_ms, 24, proto3_optional: true, type: :double, json_name: "ttfbMs"
  field :page_load_ms, 25, proto3_optional: true, type: :double, json_name: "pageLoadMs"
  field :dns_ms, 26, proto3_optional: true, type: :double, json_name: "dnsMs"
  field :connect_ms, 27, proto3_optional: true, type: :double, json_name: "connectMs"
  field :tls_ms, 28, proto3_optional: true, type: :double, json_name: "tlsMs"
  field :dom_ready_ms, 29, proto3_optional: true, type: :double, json_name: "domReadyMs"
  field :rage_clicks, 30, type: :uint32, json_name: "rageClicks"
  field :js_errors, 31, type: :uint32, json_name: "jsErrors"
  field :http_status, 32, type: :uint32, json_name: "httpStatus"
  field :has_error, 33, type: :bool, json_name: "hasError"
  field :cdn_provider, 34, type: :string, json_name: "cdnProvider"
  field :cdn_cache_status, 35, type: :string, json_name: "cdnCacheStatus"
  field :cdn_edge_rtt_ms, 36, proto3_optional: true, type: :double, json_name: "cdnEdgeRttMs"
  field :cdn_origin_rtt_ms, 37, proto3_optional: true, type: :double, json_name: "cdnOriginRttMs"
  field :cdn_pop, 38, type: :string, json_name: "cdnPop"
  field :server_timing_raw, 39, type: :string, json_name: "serverTimingRaw"
  field :client_ip, 40, type: :string, json_name: "clientIp"
  field :client_ip_anonymized, 41, type: :bool, json_name: "clientIpAnonymized"
  field :country, 42, type: :string
  field :region, 43, type: :string
  field :city, 44, type: :string
  field :asn, 45, type: :uint32
  field :as_org, 46, type: :string, json_name: "asOrg"
  field :prefix_tag, 47, type: :string, json_name: "prefixTag"

  field :attributes, 48,
    repeated: true,
    type: Serviceradar.Rum.V1.RumBeaconV1.AttributesEntry,
    map: true
end
