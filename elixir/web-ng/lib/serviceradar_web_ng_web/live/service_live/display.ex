defmodule ServiceRadarWebNGWeb.ServiceLive.Display do
  @moduledoc false

  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNGWeb.ServiceLive.Service

  def for_service(service, scope) when is_map(service) do
    details = Service.parse_details(service)
    contract = load_contract(details, scope)

    display =
      details
      |> Service.display_instructions()
      |> Service.filter_display(contract)

    {details, display, contract, Service.schema_version(details, contract)}
  end

  def for_service(_service, _scope), do: {%{}, [], %{}, nil}

  def contracts_by_plugin_id(details_list, scope) when is_list(details_list) do
    plugin_ids =
      details_list
      |> Enum.map(&Service.plugin_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if plugin_ids == [] do
      %{}
    else
      %{"status" => "approved", "limit" => 500}
      |> Packages.list(scope: scope)
      |> Enum.filter(&(&1.plugin_id in plugin_ids))
      |> Enum.sort_by(&package_inserted_at_sort_key/1, :desc)
      |> Enum.reduce(%{}, fn package, acc ->
        case package.display_contract do
          contract when is_map(contract) -> Map.put_new(acc, package.plugin_id, contract)
          _ -> acc
        end
      end)
    end
  end

  def contracts_by_plugin_id(_details_list, _scope), do: %{}

  def filter_card_display(display, details, contracts) when is_list(display) and is_map(details) and is_map(contracts) do
    plugin_id = Service.plugin_id(details)

    if is_binary(plugin_id) and plugin_id != "" do
      Service.filter_display(display, Map.get(contracts, plugin_id, %{}))
    else
      display
    end
  end

  def filter_card_display(display, _details, _contracts), do: display

  defp load_contract(details, scope) when is_map(details) do
    plugin_id = Service.plugin_id(details)

    if is_binary(plugin_id) and plugin_id != "" do
      %{"plugin_id" => plugin_id, "status" => "approved", "limit" => 1}
      |> Packages.list(scope: scope)
      |> List.first()
      |> case do
        %{display_contract: contract} when is_map(contract) -> contract
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp package_inserted_at_sort_key(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp package_inserted_at_sort_key(%{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: NaiveDateTime.to_gregorian_seconds(inserted_at)

  defp package_inserted_at_sort_key(_package), do: 0
end
