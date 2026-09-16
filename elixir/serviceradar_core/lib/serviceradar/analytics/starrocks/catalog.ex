defmodule ServiceRadar.Analytics.StarRocks.Catalog do
  @moduledoc """
  CREATE EXTERNAL CATALOG SQL for the opt-in CNPG JDBC catalog.

  Passwords are supplied at apply time from infrastructure secrets. This
  module does not embed them. The driver URL is a file:// path, never Maven.
  """

  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist

  @driver_url "file:///opt/starrocks/jdbc/postgresql.jar"
  @driver_class "org.postgresql.Driver"
  @jdbc_uri "jdbc:postgresql://cnpg-rw:5432/serviceradar?ssl=true&sslmode=require"
  @reader "serviceradar_starrocks_reader"

  @spec driver_url() :: String.t()
  def driver_url, do: @driver_url

  @spec driver_class() :: String.t()
  def driver_class, do: @driver_class

  @spec create_sql(keyword()) :: String.t()
  def create_sql(opts \\ []) do
    name = Keyword.get(opts, :name, CatalogAllowlist.catalog_name())
    user = Keyword.get(opts, :user, @reader)
    uri = Keyword.get(opts, :jdbc_uri, @jdbc_uri)
    driver_url = Keyword.get(opts, :driver_url, @driver_url)
    driver_class = Keyword.get(opts, :driver_class, @driver_class)

    props = [
      {"type", "jdbc"},
      {"user", user},
      {"jdbc_uri", uri},
      {"driver_class", driver_class},
      {"driver_url", driver_url}
    ]

    props =
      case Keyword.get(opts, :password) do
        password when is_binary(password) and password != "" ->
          props ++ [{"password", password}]

        _ ->
          props
      end

    inner =
      props
      |> Enum.map(fn {key, value} -> ~s(  "#{key}" = "#{escape(value)}") end)
      |> Enum.join(",\n")

    "CREATE EXTERNAL CATALOG IF NOT EXISTS #{name}\nPROPERTIES (\n#{inner}\n);"
  end

  defp escape(value) when is_binary(value), do: String.replace(value, "\"", "\\\"")
end
