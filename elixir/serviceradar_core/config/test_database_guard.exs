defmodule ServiceRadar.DB.TestDatabaseGuard do
  @moduledoc false

  @fixture_tls_name "srql-fixture-rw.srql-fixtures.svc.cluster.local"
  @disposable_database ~r/\A(?:sr_core_test_[a-z0-9_]+|codex_[a-z0-9_]+)\z/
  @template_authorization_key {__MODULE__, :typed_template_lifecycle}

  @doc false
  def authorize_template_lifecycle!(database \\ "sr_core_template") do
    if !(database == "sr_core_template" or Regex.match?(~r/\Asr_tpl_[0-9a-f]{48}\z/, database)) do
      raise ArgumentError, "invalid template generation database"
    end

    :persistent_term.put(@template_authorization_key, database)
    :ok
  end

  @doc false
  def clear_template_lifecycle_authorization! do
    :persistent_term.erase(@template_authorization_key)
    :ok
  end

  @doc false
  def template_lifecycle_authorized? do
    is_binary(:persistent_term.get(@template_authorization_key, false))
  end

  @doc "Fails before Repo startup unless a database-backed test is confined to srql-fixtures."
  def validate!(url, opts) when is_binary(url) and is_list(opts) do
    uri = URI.parse(url)
    validate_query!(uri.query)

    tls_server_name = opts |> Keyword.get(:tls_server_name) |> normalize_name()
    ssl_mode = opts |> Keyword.get(:ssl_mode) |> normalize_name()
    ca_configured? = Keyword.get(opts, :ca_configured?, false)
    template_lifecycle? = Keyword.get(opts, :template_lifecycle?, false)
    database = uri.path |> to_string() |> String.trim_leading("/")

    cond do
      uri.scheme not in ["postgres", "postgresql"] or not is_binary(uri.host) ->
        raise ArgumentError, "test database URL must be a PostgreSQL URL with a host"

      not fixture_dial_target?(uri.host, tls_server_name) ->
        raise ArgumentError, """
        database-backed tests require the srql-fixtures TLS identity #{@fixture_tls_name};
        demo, production, and other PostgreSQL endpoints are not valid test destinations
        """

      not disposable_database?(database, template_lifecycle?) ->
        raise ArgumentError, """
        database-backed tests require a disposable test database named sr_core_test_* or codex_*;
        the shared srql_fixture database and unrelated databases are never valid test targets
        """

      ssl_mode != "verify-full" ->
        raise ArgumentError,
              "srql-fixtures tests require sslmode=verify-full (resolved mode: #{inspect(ssl_mode)})"

      not ca_configured? ->
        raise ArgumentError, "srql-fixtures tests require the fixture CA for peer verification"

      true ->
        :ok
    end
  end

  defp disposable_database?("sr_core_template", true),
    do: :persistent_term.get(@template_authorization_key, false) == "sr_core_template"

  defp disposable_database?("sr_tpl_" <> _rest = database, true),
    do: :persistent_term.get(@template_authorization_key, false) == database

  defp disposable_database?(database, _template_lifecycle?),
    do: Regex.match?(@disposable_database, database)

  defp fixture_dial_target?(@fixture_tls_name, _tls_server_name), do: true

  defp fixture_dial_target?(host, @fixture_tls_name) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, :einval} -> false
    end
  end

  defp fixture_dial_target?(_host, _tls_server_name), do: false

  # Ecto merges URL query options after the explicit Repo configuration. In particular,
  # `ssl=false` would replace the verified SSL option list, while `hostname=` or `database=`
  # would replace the URI authority/path that we validated above. Keep the DSN query surface
  # deliberately closed: the fixture needs only libpq's sslmode marker, plus an optional
  # redundant `ssl=true` that Ecto explicitly ignores when SSL options are already configured.
  defp validate_query!(query) do
    pairs = decode_query!(query)
    ssl_modes = for {"sslmode", value} <- pairs, do: String.downcase(value)
    ssl_values = for {"ssl", value} <- pairs, do: String.downcase(value)

    if Enum.any?(pairs, fn {key, _value} -> key not in ["sslmode", "ssl"] end) or
         length(ssl_modes) > 1 or
         length(ssl_values) > 1 or
         Enum.any?(ssl_modes, &(&1 != "verify-full")) or
         Enum.any?(ssl_values, &(&1 != "true")) do
      raise ArgumentError, """
      database URL query may contain at most sslmode=verify-full and ssl=true;
      connection, database, and TLS overrides are not permitted
      """
    end
  end

  defp decode_query!(nil), do: []

  defp decode_query!(query) do
    query
    |> URI.query_decoder()
    |> Enum.to_list()
  rescue
    _error ->
      raise ArgumentError, "database URL query is malformed"
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(value) when is_list(value), do: value |> to_string() |> String.downcase()
  defp normalize_name(value), do: value |> to_string() |> String.downcase()
end
