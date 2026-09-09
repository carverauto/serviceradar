ExUnit.start()

defmodule ServiceRadar.WebNgDbConfigTest do
  use ExUnit.Case, async: false

  @config Path.expand("../elixir/web-ng/config/test.exs", __DIR__)
  @environment ~w(
    SERVICERADAR_TEST_DATABASE_URL SERVICERADAR_TEST_DATABASE_CA_CERT
    SERVICERADAR_TEST_DATABASE_SERVER_NAME CNPG_SSL_MODE CNPG_TLS_SERVER_NAME
    CNPG_CA_FILE CNPG_CERT_FILE CNPG_KEY_FILE CNPG_CERT_DIR
  )

  setup do
    previous = Map.new(@environment, &{&1, System.get_env(&1)})
    Enum.each(@environment, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "guarded configuration refuses missing or invalid CA material" do
    System.put_env("SERVICERADAR_TEST_DATABASE_URL", "postgres://192.0.2.1/codex_example")

    for ca <- ["", "not a certificate"] do
      System.put_env("SERVICERADAR_TEST_DATABASE_CA_CERT", ca)

      assert_raise RuntimeError,
                   "guarded web-ng database tests require SERVICERADAR_TEST_DATABASE_CA_CERT",
                   fn -> Config.Reader.read!(@config, env: :test) end
    end
  end

  test "guarded configuration refuses missing TLS identity and unsafe destinations" do
    System.put_env("SERVICERADAR_TEST_DATABASE_URL", "postgres://192.0.2.1/codex_example")

    System.put_env(
      "SERVICERADAR_TEST_DATABASE_CA_CERT",
      :public_key.pem_encode([{:Certificate, <<1, 2, 3>>, :not_encrypted}])
    )

    assert_raise RuntimeError,
                 "guarded web-ng database tests require SERVICERADAR_TEST_DATABASE_SERVER_NAME",
                 fn -> Config.Reader.read!(@config, env: :test) end

    System.put_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME", "db.example.com")
    System.put_env("CNPG_SSL_MODE", "disable")

    assert_raise ArgumentError, ~r/database-backed tests require/, fn ->
      Config.Reader.read!(@config, env: :test)
    end
  end

  test "verify-full configuration enables peer and hostname verification" do
    System.put_env("CNPG_SSL_MODE", "verify-full")
    System.put_env("CNPG_TLS_SERVER_NAME", "db.example.com")
    System.put_env("CNPG_CA_FILE", "/synthetic/ca.pem")

    config = Config.Reader.read!(@config, env: :test)
    ssl = config[:serviceradar_core][ServiceRadar.Repo][:ssl]
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacertfile] == "/synthetic/ca.pem"
    assert ssl[:server_name_indication] == ~c"db.example.com"
    assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
  end
end
