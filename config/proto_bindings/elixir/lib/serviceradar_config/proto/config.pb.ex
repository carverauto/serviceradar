defmodule Serviceradar.Config.V1.EnvironmentKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.config.v1.EnvironmentKind",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :ENVIRONMENT_KIND_UNSPECIFIED, 0
  field :ENVIRONMENT_KIND_LOCALHOST, 1
  field :ENVIRONMENT_KIND_CI, 2
  field :ENVIRONMENT_KIND_SAAS, 3
  field :ENVIRONMENT_KIND_ONPREM, 4
  field :ENVIRONMENT_KIND_DEMO, 5
end

defmodule Serviceradar.Config.V1.TlsMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.config.v1.TlsMode",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :TLS_MODE_UNSPECIFIED, 0
  field :TLS_MODE_DISABLE, 1
  field :TLS_MODE_REQUIRE, 2
  field :TLS_MODE_VERIFY_CA, 3
  field :TLS_MODE_VERIFY_FULL, 4
end

defmodule Serviceradar.Config.V1.DgraphTlsMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.config.v1.DgraphTlsMode",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :DGRAPH_TLS_MODE_UNSPECIFIED, 0
  field :DGRAPH_TLS_MODE_DISABLE, 1
  field :DGRAPH_TLS_MODE_REQUIRE_NO_VERIFY, 2
  field :DGRAPH_TLS_MODE_VERIFY_CA, 3
end

defmodule Serviceradar.Config.V1.SecurityMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.config.v1.SecurityMode",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :SECURITY_MODE_UNSPECIFIED, 0
  field :SECURITY_MODE_NONE, 1
  field :SECURITY_MODE_MTLS, 2
  field :SECURITY_MODE_SPIFFE, 3
end

defmodule Serviceradar.Config.V1.DatabaseConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.DatabaseConfig",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :host, 1, proto3_optional: true, type: :string
  field :port, 2, proto3_optional: true, type: :uint32
  field :database, 3, proto3_optional: true, type: :string
  field :connecting_role, 4, proto3_optional: true, type: :string, json_name: "connectingRole"
  field :owning_role, 5, proto3_optional: true, type: :string, json_name: "owningRole"

  field :tls_mode, 6,
    proto3_optional: true,
    type: Serviceradar.Config.V1.TlsMode,
    json_name: "tlsMode",
    enum: true

  field :tls_server_name, 7, proto3_optional: true, type: :string, json_name: "tlsServerName"
  field :search_path, 8, proto3_optional: true, type: :string, json_name: "searchPath"
  field :pool_size, 9, proto3_optional: true, type: :uint32, json_name: "poolSize"
  field :queue_target_ms, 10, proto3_optional: true, type: :uint32, json_name: "queueTargetMs"
  field :queue_interval_ms, 11, proto3_optional: true, type: :uint32, json_name: "queueIntervalMs"

  field :ownership_timeout_ms, 12,
    proto3_optional: true,
    type: :uint32,
    json_name: "ownershipTimeoutMs"

  field :admin_role, 13, proto3_optional: true, type: :string, json_name: "adminRole"
  field :ca_bundle_url, 14, proto3_optional: true, type: :string, json_name: "caBundleUrl"
end

defmodule Serviceradar.Config.V1.NatsConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.NatsConfig",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :url, 1, proto3_optional: true, type: :string
  field :server_name, 2, proto3_optional: true, type: :string, json_name: "serverName"
end

defmodule Serviceradar.Config.V1.DgraphConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.DgraphConfig",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :host, 1, proto3_optional: true, type: :string
  field :port, 2, proto3_optional: true, type: :uint32

  field :tls_mode, 3,
    proto3_optional: true,
    type: Serviceradar.Config.V1.DgraphTlsMode,
    json_name: "tlsMode",
    enum: true

  field :ca_bundle_url, 4, proto3_optional: true, type: :string, json_name: "caBundleUrl"
end

defmodule Serviceradar.Config.V1.CoreConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.CoreConfig",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :address, 1, proto3_optional: true, type: :string
  field :api_url, 2, proto3_optional: true, type: :string, json_name: "apiUrl"

  field :security_mode, 3,
    proto3_optional: true,
    type: Serviceradar.Config.V1.SecurityMode,
    json_name: "securityMode",
    enum: true

  field :server_name, 4, proto3_optional: true, type: :string, json_name: "serverName"
  field :trust_domain, 5, proto3_optional: true, type: :string, json_name: "trustDomain"
  field :server_spiffe_id, 6, proto3_optional: true, type: :string, json_name: "serverSpiffeId"
  field :workload_socket, 7, proto3_optional: true, type: :string, json_name: "workloadSocket"
end

defmodule Serviceradar.Config.V1.EnvironmentConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.EnvironmentConfig",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :kind, 1, proto3_optional: true, type: Serviceradar.Config.V1.EnvironmentKind, enum: true
  field :instance, 2, proto3_optional: true, type: :string
  field :database, 3, proto3_optional: true, type: Serviceradar.Config.V1.DatabaseConfig
  field :nats, 4, proto3_optional: true, type: Serviceradar.Config.V1.NatsConfig
  field :core, 5, proto3_optional: true, type: Serviceradar.Config.V1.CoreConfig
  field :dgraph, 6, proto3_optional: true, type: Serviceradar.Config.V1.DgraphConfig
end
