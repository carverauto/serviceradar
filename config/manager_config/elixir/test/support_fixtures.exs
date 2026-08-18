defmodule ServiceradarConfig.ManagerFixtures do
  @moduledoc """
  A rule set built here rather than read from `//config/rules:ruleset_binpb`.

  These tests are about what the manager DOES with a rule set -- delegate, and refuse to return a
  value when anything fires -- not about the contents of the committed one. That the committed
  rules accept every committed instance is asserted by `//config/validator/elixir`, against the
  real artifacts.
  """

  alias Serviceradar.Config.V1.{
    CoreConfig,
    DatabaseConfig,
    DgraphConfig,
    EnvironmentConfig,
    NatsConfig,
    OneOf,
    Required,
    Rule,
    RuleSet,
    Scope
  }

  def rules do
    %RuleSet{
      rules: [
        %Rule{
          field_path: "database.host",
          code: "DATABASE_HOST_REQUIRED",
          phase: :PHASE_CONFIG,
          predicate: {:required, %Required{}}
        },
        %Rule{
          field_path: "database.tls_mode",
          code: "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST",
          phase: :PHASE_CONFIG,
          scope: %Scope{except_kinds: [:ENVIRONMENT_KIND_LOCALHOST]},
          predicate:
            {:one_of, %OneOf{enum_values: ["TLS_MODE_VERIFY_CA", "TLS_MODE_VERIFY_FULL"]}}
        }
      ]
    }
  end

  def valid_ci do
    %EnvironmentConfig{
      kind: :ENVIRONMENT_KIND_CI,
      database: %DatabaseConfig{
        host: "db",
        port: 5432,
        database: "srql_fixture",
        connecting_role: "srql_test",
        owning_role: "srql_test",
        tls_mode: :TLS_MODE_VERIFY_FULL,
        tls_server_name: "db",
        search_path: "platform, ag_catalog",
        pool_size: 10,
        queue_target_ms: 500,
        queue_interval_ms: 1000,
        ownership_timeout_ms: 60_000
      },
      nats: %NatsConfig{url: "nats://nats:4222", server_name: "nats"},
      core: %CoreConfig{
        address: "core:50052",
        api_url: "http://core:8090",
        security_mode: :SECURITY_MODE_MTLS,
        server_name: "core"
      },
      dgraph: %DgraphConfig{host: "dgraph", port: 9080, tls_mode: :DGRAPH_TLS_MODE_VERIFY_CA}
    }
  end

  def encode(config), do: EnvironmentConfig.encode(config)

  @doc "A mount that is not there."
  def missing_mount, do: fn path -> {:error, "no such file: #{path}"} end

  @doc "A mount carrying exactly these bytes."
  def mounted(bytes), do: fn _path -> {:ok, bytes} end
end
