ExUnit.start()

fixture_config_path = Path.expand("fixture_config.exs", __DIR__)
integration_config_path = Path.expand("integration_env_config.exs", __DIR__)
database_guard_path = Path.expand("../../config/test_database_guard.exs", __DIR__)

if File.exists?(fixture_config_path), do: Code.require_file(fixture_config_path)
if File.exists?(integration_config_path), do: Code.require_file(integration_config_path)
if File.exists?(database_guard_path), do: Code.require_file(database_guard_path)

defmodule ServiceRadar.DB.IntegrationEnvConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.DB.FixtureConfig
  alias ServiceRadar.DB.IntegrationEnvConfig
  alias ServiceRadar.DB.TestDatabaseGuard

  @environment_variables [
    "SERVICERADAR_ENV",
    "SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD",
    "SERVICERADAR_SECRET_DATABASE_PASSWORD",
    "SRQL_TEST_DATABASE_URL",
    "SERVICERADAR_TEST_DATABASE_URL",
    "SERVICERADAR_TEST_DATABASE_CA_CERT",
    "SERVICERADAR_TEST_DATABASE_SERVER_NAME"
  ]

  setup do
    previous = Map.new(@environment_variables, &{&1, System.get_env(&1)})

    if Code.ensure_loaded?(TestDatabaseGuard) do
      TestDatabaseGuard.clear_template_lifecycle_authorization!()
    end

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)

      if Code.ensure_loaded?(TestDatabaseGuard) do
        TestDatabaseGuard.clear_template_lifecycle_authorization!()
      end
    end)

    :ok
  end

  test "the ci fixture resolves only to the checked-in srql-fixtures endpoint" do
    System.put_env("SERVICERADAR_ENV", "ci")
    System.put_env("SERVICERADAR_SECRET_DATABASE_PASSWORD", "fixture-password")

    fixture =
      FixtureConfig.resolve!("sr_core_test_deadbeef_async",
        ca_fetcher: fn _url -> "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----" end
      )

    uri = URI.parse(fixture.url)

    assert uri.host == "srql-fixture-rw.srql-fixtures.svc.cluster.local"
    assert uri.path == "/sr_core_test_deadbeef_async"
    assert fixture.tls_server_name == "srql-fixture-rw.srql-fixtures.svc.cluster.local"
  end

  test "the ci admin connection is assembled from the same typed srql-fixtures endpoint" do
    System.put_env("SERVICERADAR_ENV", "ci")
    System.put_env("SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD", "fixture-admin-password")

    uri =
      "postgres"
      |> FixtureConfig.admin_url!()
      |> URI.parse()

    assert uri.host == "srql-fixture-rw.srql-fixtures.svc.cluster.local"
    assert uri.path == "/postgres"
    assert uri.userinfo == "srql_hydra:fixture-admin-password"
    assert URI.decode_query(uri.query) == %{"sslmode" => "verify-full"}
  end

  test "guarded integration configuration ignores ambient legacy and direct endpoints" do
    System.put_env(
      "SRQL_TEST_DATABASE_URL",
      "postgres://wrong:wrong@production.invalid/production"
    )

    System.put_env(
      "SERVICERADAR_TEST_DATABASE_URL",
      "postgres://wrong:wrong@demo.invalid/demo"
    )

    resolver = fn database ->
      %{
        url:
          "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/#{database}?sslmode=verify-full",
        ca_pem: "fixture-ca",
        tls_server_name: "srql-fixture-rw.srql-fixtures.svc.cluster.local"
      }
    end

    assert %{database: "sr_core_test_deadbeef_async"} =
             IntegrationEnvConfig.configure!("sr_core_test_deadbeef", "async", resolver)

    configured = URI.parse(System.fetch_env!("SERVICERADAR_TEST_DATABASE_URL"))

    assert configured.host == "srql-fixture-rw.srql-fixtures.svc.cluster.local"
    assert configured.path == "/sr_core_test_deadbeef_async"
    assert System.fetch_env!("SERVICERADAR_TEST_DATABASE_CA_CERT") == "fixture-ca"

    assert System.fetch_env!("SERVICERADAR_TEST_DATABASE_SERVER_NAME") ==
             "srql-fixture-rw.srql-fixtures.svc.cluster.local"
  end

  test "an invalid run id fails before fixture resolution" do
    resolver = fn _database -> flunk("fixture resolution must not run") end

    assert_raise RuntimeError, ~r/does not start with "sr_core_test_"/, fn ->
      IntegrationEnvConfig.configure!("serviceradar", "async", resolver)
    end
  end

  test "the database guard accepts the in-cluster disposable fixture destination" do
    assert :ok =
             TestDatabaseGuard.validate!(
               "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/sr_core_test_deadbeef_async?sslmode=verify-full",
               tls_server_name: "srql-fixture-rw.srql-fixtures.svc.cluster.local",
               ssl_mode: "verify-full",
               ca_configured?: true
             )
  end

  test "the database guard accepts a workstation NodePort only with fixture TLS identity" do
    assert :ok =
             TestDatabaseGuard.validate!(
               "postgres://fixture:secret@192.168.10.31:30818/codex_guard_123?sslmode=verify-full",
               tls_server_name: "srql-fixture-rw.srql-fixtures.svc.cluster.local",
               ssl_mode: "verify-full",
               ca_configured?: true
             )
  end

  test "the database guard rejects demo and production endpoints" do
    for host <- ["demo-db.example.internal", "production-db.example.internal"] do
      assert_raise ArgumentError, ~r/srql-fixtures TLS identity/, fn ->
        TestDatabaseGuard.validate!(
          "postgres://fixture:secret@#{host}/codex_guard_123?sslmode=verify-full",
          ssl_mode: "verify-full",
          ca_configured?: true
        )
      end
    end

    assert_raise ArgumentError, ~r/srql-fixtures TLS identity/, fn ->
      TestDatabaseGuard.validate!(
        "postgres://fixture:secret@production.internal/codex_guard_123?sslmode=verify-full",
        tls_server_name: "srql-fixture-rw.srql-fixtures.svc.cluster.local",
        ssl_mode: "verify-full",
        ca_configured?: true
      )
    end
  end

  test "the database guard rejects the shared fixture database" do
    assert_raise ArgumentError, ~r/disposable test database/, fn ->
      TestDatabaseGuard.validate!(
        "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/srql_fixture?sslmode=verify-full",
        ssl_mode: "verify-full",
        ca_configured?: true
      )
    end
  end

  test "only the typed template lifecycle may address the shared clone template" do
    url =
      "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/sr_core_template?sslmode=verify-full"

    assert_raise ArgumentError, ~r/disposable test database/, fn ->
      TestDatabaseGuard.validate!(url,
        ssl_mode: "verify-full",
        ca_configured?: true
      )
    end

    refute TestDatabaseGuard.template_lifecycle_authorized?()
    TestDatabaseGuard.authorize_template_lifecycle!()
    assert TestDatabaseGuard.template_lifecycle_authorized?()

    assert :ok =
             TestDatabaseGuard.validate!(url,
               ssl_mode: "verify-full",
               ca_configured?: true,
               template_lifecycle?: TestDatabaseGuard.template_lifecycle_authorized?()
             )
  end

  test "template authorization permits only the manifest-selected generation" do
    selected = "sr_tpl_" <> String.duplicate("a", 48)
    other = "sr_tpl_" <> String.duplicate("b", 48)

    System.put_env("SERVICERADAR_ENV", "ci")
    System.put_env("SERVICERADAR_SECRET_DATABASE_PASSWORD", "synthetic-password")

    url = fn name ->
      FixtureConfig.resolve!(name, ca_fetcher: fn _ -> "synthetic-ca" end).url
    end

    opts = [ssl_mode: "verify-full", ca_configured?: true, template_lifecycle?: true]

    assert_raise ArgumentError, fn -> TestDatabaseGuard.validate!(url.(selected), opts) end
    TestDatabaseGuard.authorize_template_lifecycle!(selected)
    assert :ok = TestDatabaseGuard.validate!(url.(selected), opts)
    assert_raise ArgumentError, fn -> TestDatabaseGuard.validate!(url.(other), opts) end

    assert_raise ArgumentError, fn ->
      TestDatabaseGuard.validate!(url.("sr_core_template"), opts)
    end

    TestDatabaseGuard.clear_template_lifecycle_authorization!()
    assert_raise ArgumentError, fn -> TestDatabaseGuard.validate!(url.(selected), opts) end

    assert_raise ArgumentError, fn ->
      TestDatabaseGuard.authorize_template_lifecycle!("sr_tpl_invalid")
    end
  end

  test "the database guard rejects unverified fixture connections" do
    url =
      "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/codex_guard_123"

    assert_raise ArgumentError, ~r/sslmode=verify-full/, fn ->
      TestDatabaseGuard.validate!(url,
        ssl_mode: "require",
        ca_configured?: true
      )
    end

    assert_raise ArgumentError, ~r/fixture CA/, fn ->
      TestDatabaseGuard.validate!(url,
        ssl_mode: "verify-full",
        ca_configured?: false
      )
    end
  end

  test "the database guard rejects URL options that can override the verified destination" do
    base =
      "postgres://fixture:secret@srql-fixture-rw.srql-fixtures.svc.cluster.local/codex_guard_123"

    for query <- [
          "sslmode=verify-full&ssl=false",
          "sslmode=verify-full&hostname=production.invalid",
          "sslmode=verify-full&database=srql_fixture",
          "sslmode=verify-full&sslmode=disable"
        ] do
      assert_raise ArgumentError, ~r/database URL query/, fn ->
        TestDatabaseGuard.validate!("#{base}?#{query}",
          ssl_mode: "verify-full",
          ca_configured?: true
        )
      end
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
