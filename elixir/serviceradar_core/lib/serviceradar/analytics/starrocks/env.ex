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

  @spec config() :: keyword()
  def config do
    [
      catalog_enabled: truthy?("SERVICERADAR_STARROCKS_CATALOG_ENABLED"),
      cutover_datasets: csv_datasets("SERVICERADAR_STARROCKS_CUTOVER_DATASETS"),
      shadow_datasets: csv_datasets("SERVICERADAR_STARROCKS_SHADOW_DATASETS"),
      fe_http: fe_http(),
      database: nonempty("SERVICERADAR_STARROCKS_DATABASE", "serviceradar"),
      user: nonempty("SERVICERADAR_STARROCKS_USER", "root"),
      password: System.get_env("SERVICERADAR_STARROCKS_PASSWORD", "")
    ]
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
