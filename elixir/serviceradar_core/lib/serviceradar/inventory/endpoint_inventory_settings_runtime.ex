defmodule ServiceRadar.Inventory.EndpointInventorySettingsRuntime do
  @moduledoc """
  Cached runtime accessor for endpoint inventory settings.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.EndpointInventorySettings

  @cache_key {__MODULE__, :settings}
  @default_ttl_ms 30_000
  @default_retention_days 30

  @spec settings() :: map()
  def settings do
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()

    case :persistent_term.get(@cache_key, nil) do
      %{fetched_at_ms: fetched_at_ms, data: data}
      when is_integer(fetched_at_ms) and is_map(data) and now - fetched_at_ms < ttl ->
        data

      _ ->
        refresh_settings(now)
    end
  end

  @spec force_refresh() :: map()
  def force_refresh do
    refresh_settings(System.monotonic_time(:millisecond))
  end

  @spec retention_days(pos_integer()) :: pos_integer()
  def retention_days(fallback \\ @default_retention_days) do
    settings()
    |> Map.get(:retention_days, fallback)
    |> valid_days(fallback)
  end

  defp refresh_settings(now) do
    data =
      case EndpointInventorySettings.get_settings(
             actor: SystemActor.system(:endpoint_inventory_settings_runtime)
           ) do
        {:ok, %EndpointInventorySettings{} = settings} ->
          %{retention_days: settings.retention_days}

        _ ->
          %{retention_days: nil}
      end

    :persistent_term.put(@cache_key, %{fetched_at_ms: now, data: data})
    data
  rescue
    _ ->
      data = %{retention_days: nil}
      :persistent_term.put(@cache_key, %{fetched_at_ms: now, data: data})
      data
  end

  defp valid_days(days, _fallback) when is_integer(days) and days > 0, do: days
  defp valid_days(_days, fallback), do: max(fallback, 1)

  defp ttl_ms do
    Application.get_env(
      :serviceradar_core,
      :endpoint_inventory_settings_runtime_cache_ms,
      @default_ttl_ms
    )
  end
end
