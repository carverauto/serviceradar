defmodule ServiceradarConfig.ManagerFixtures do
  @moduledoc """
  Configuration fixtures for the manager tests.

  There is deliberately no rule set here. These tests validate against the REAL committed rules,
  which are embedded in `ServiceradarConfig.Rules` and are the only ones the manager will ever
  use. A synthetic rule set tested the manager against rules no deployment has, and let
  `valid_ci/0` below drift from what the committed rules actually require.
  """

  alias Serviceradar.Config.V1.{
    CoreConfig,
    DatabaseConfig,
    DgraphConfig,
    EnvironmentConfig,
    NatsConfig
  }

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
