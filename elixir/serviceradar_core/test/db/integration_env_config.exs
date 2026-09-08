defmodule ServiceRadar.DB.IntegrationEnvConfig do
  @moduledoc """
  Derives the one disposable database destination for a guarded integration-test BEAM.

  The database name comes from Bazel's declared run-id input and lane. The endpoint, role, TLS
  posture, and secret come from `ServiceRadar.DB.FixtureConfig`. Ambient legacy DSNs are never an
  input: provisioning and the Elixir suite must resolve the same checked-in fixture.
  """

  alias ServiceRadar.DB.FixtureConfig

  @disposable_prefix "sr_core_test_"
  @database_url_env "SERVICERADAR_TEST_DATABASE_URL"
  @ca_cert_env "SERVICERADAR_TEST_DATABASE_CA_CERT"
  @server_name_env "SERVICERADAR_TEST_DATABASE_SERVER_NAME"

  @doc "Configures the guarded suite destination before `config/test.exs` is evaluated."
  def configure!(base_name, lane, fixture_resolver \\ &FixtureConfig.resolve!/1)
      when is_function(fixture_resolver, 1) do
    database = database_name!(base_name, lane)

    %{url: url, ca_pem: ca_pem, tls_server_name: tls_server_name} =
      fixture_resolver.(database)

    if not is_binary(url) or url == "" do
      raise "fixture resolver returned no database URL"
    end

    # Unconditional by design. A guarded Bazel lane has exactly one legitimate endpoint, and a
    # pre-set direct URL must not redirect the suite away from the server provisioned by Rust.
    System.put_env(@database_url_env, url)
    put_optional_env(@ca_cert_env, ca_pem)
    put_optional_env(@server_name_env, tls_server_name)

    %{database: database, url: url, ca_pem: ca_pem, tls_server_name: tls_server_name}
  end

  @doc false
  def database_name!(base_name, lane) when is_binary(base_name) do
    run_id =
      if String.starts_with?(base_name, @disposable_prefix) do
        String.replace_prefix(base_name, @disposable_prefix, "")
      else
        raise "run id file holds #{inspect(base_name)}, which does not start with " <>
                inspect(@disposable_prefix)
      end

    if not String.match?(run_id, ~r/\A[a-z0-9]{8,32}\z/) do
      raise "--//build:run_id must be 8..32 characters of [a-z0-9], got " <>
              "#{inspect(run_id)} -- mint one with " <>
              "`uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-8`"
    end

    case lane do
      value when value in [nil, ""] ->
        base_name

      value when is_binary(value) ->
        if String.match?(value, ~r/\A[a-z0-9_]+\z/) do
          "#{base_name}_#{value}"
        else
          raise "SERVICERADAR_TEST_DB_SHARD must be [a-z0-9_]+, got #{inspect(value)}"
        end
    end
  end

  defp put_optional_env(name, value) when is_binary(value) and value != "",
    do: System.put_env(name, value)

  defp put_optional_env(name, _value), do: System.delete_env(name)
end
