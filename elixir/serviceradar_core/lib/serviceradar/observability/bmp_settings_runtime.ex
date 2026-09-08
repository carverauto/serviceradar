defmodule ServiceRadar.Observability.BmpSettingsRuntime do
  @moduledoc """
  Cached runtime accessor for BMP settings.

  Uses `:persistent_term` with a short TTL to avoid hot-path DB reads in
  EventWriter and God-View snapshot loops.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.BmpSettings

  @cache_key {__MODULE__, :settings}
  @default_ttl_ms 30_000

  @defaults %{
    bmp_routing_retention_days: 3,
    bmp_ocsf_min_severity: 4,
    god_view_causal_overlay_window_seconds: 300,
    god_view_causal_overlay_max_events: 512,
    god_view_routing_causal_severity_threshold: 4
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

  def bmp_ocsf_min_severity do
    settings()[:bmp_ocsf_min_severity]
  end

  def god_view_causal_overlay_window_seconds do
    settings()[:god_view_causal_overlay_window_seconds]
  end

  def god_view_causal_overlay_max_events do
    settings()[:god_view_causal_overlay_max_events]
  end

  def god_view_routing_causal_severity_threshold do
    settings()[:god_view_routing_causal_severity_threshold]
  end

  defp refresh_settings(now) do
    data =
      case BmpSettings.get_settings(actor: SystemActor.system(:bmp_settings_runtime)) do
        {:ok, %BmpSettings{} = settings} ->
          %{
            bmp_routing_retention_days: settings.bmp_routing_retention_days,
            bmp_ocsf_min_severity: settings.bmp_ocsf_min_severity,
            god_view_causal_overlay_window_seconds:
              settings.god_view_causal_overlay_window_seconds,
            god_view_causal_overlay_max_events: settings.god_view_causal_overlay_max_events,
            god_view_routing_causal_severity_threshold:
              settings.god_view_routing_causal_severity_threshold
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
    Application.get_env(:serviceradar_core, :bmp_settings_runtime_cache_ms, @default_ttl_ms)
  end
end
