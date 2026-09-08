defmodule ServiceRadar.Observability.MtrSettingsRuntime do
  @moduledoc """
  Cached runtime accessor for MTR diagnostics settings.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.MtrSettings

  @cache_key {__MODULE__, :settings}
  @default_ttl_ms 30_000

  @defaults %{
    mtr_retention_days: 30,
    mtr_default_history_window: "last_30d",
    mtr_history_page_size_default: 50
  }

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

  def mtr_retention_days do
    settings()[:mtr_retention_days]
  end

  defp refresh_settings(now) do
    data =
      case MtrSettings.get_settings(actor: SystemActor.system(:mtr_settings_runtime)) do
        {:ok, %MtrSettings{} = settings} ->
          %{
            mtr_retention_days: settings.mtr_retention_days,
            mtr_default_history_window: settings.mtr_default_history_window,
            mtr_history_page_size_default: settings.mtr_history_page_size_default
          }

        _ ->
          @defaults
      end

    :persistent_term.put(@cache_key, %{fetched_at_ms: now, data: data})
    data
  rescue
    _ ->
      :persistent_term.put(@cache_key, %{fetched_at_ms: now, data: @defaults})
      @defaults
  end

  defp ttl_ms do
    Application.get_env(:serviceradar_core, :mtr_settings_runtime_cache_ms, @default_ttl_ms)
  end
end
