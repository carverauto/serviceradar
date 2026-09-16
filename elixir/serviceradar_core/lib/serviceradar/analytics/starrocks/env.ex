defmodule ServiceRadar.Analytics.StarRocks.Env do
  @moduledoc """
  Runtime environment for the opt-in StarRocks destination and JDBC catalog.

  Dataset names are mapped from a closed list so operator env cannot mint atoms.
  """

  @datasets %{
    "flows" => :flows,
    "flow_attribution" => :flow_attribution,
    "metrics" => :metrics,
    "logs" => :logs,
    "events" => :events
  }

  @all_datasets [:flows, :flow_attribution, :metrics, :logs, :events]

  @spec config() :: keyword()
  def config do
    enabled = truthy?("SERVICERADAR_STARROCKS_ENABLED")

    [
      enabled: enabled,
      catalog_enabled: truthy?("SERVICERADAR_STARROCKS_CATALOG_ENABLED"),
      cutover_datasets: csv_datasets("SERVICERADAR_STARROCKS_CUTOVER_DATASETS"),
      shadow_datasets: shadow_datasets(enabled),
      fe_http: fe_http(),
      fe_mysql_host: fe_mysql_host(),
      fe_mysql_port: fe_mysql_port(),
      mysql_pool_size: mysql_pool_size(),
      database: nonempty("SERVICERADAR_STARROCKS_DATABASE", "serviceradar"),
      user: nonempty("SERVICERADAR_STARROCKS_USER", "root"),
      password: System.get_env("SERVICERADAR_STARROCKS_PASSWORD", "")
    ]
  end

  defp shadow_datasets(enabled) do
    case csv_datasets("SERVICERADAR_STARROCKS_SHADOW_DATASETS") do
      [] when enabled -> @all_datasets
      datasets -> datasets
    end
  end

  defp fe_http do
    case System.get_env("SERVICERADAR_STARROCKS_FE_HTTP") do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        service = nonempty("SERVICERADAR_STARROCKS_FE_SERVICE", "127.0.0.1")
        port = nonempty("SERVICERADAR_STARROCKS_FE_HTTP_PORT", "8030")
        "http://#{service}:#{port}"
    end
  end

  defp fe_mysql_host do
    case System.get_env("SERVICERADAR_STARROCKS_FE_HOST") do
      host when is_binary(host) and host != "" ->
        host

      _ ->
        case URI.parse(fe_http()) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nonempty("SERVICERADAR_STARROCKS_FE_SERVICE", "127.0.0.1")
        end
    end
  end

  defp fe_mysql_port do
    parse_port(nonempty("SERVICERADAR_STARROCKS_FE_QUERY_PORT", "9030"), 9030)
  end

  defp mysql_pool_size do
    parse_port(nonempty("SERVICERADAR_STARROCKS_MYSQL_POOL_SIZE", "8"), 8)
  end

  defp parse_port(raw, default) when is_binary(raw) do
    case Integer.parse(raw) do
      {port, _} when port > 0 and port < 65_536 -> port
      _ -> default
    end
  end

  defp csv_datasets(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn raw ->
      case Map.fetch(@datasets, String.trim(raw)) do
        {:ok, dataset} -> [dataset]
        :error -> []
      end
    end)
  end

  defp truthy?(name), do: System.get_env(name, "") in ~w(true 1 yes)

  defp nonempty(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
