defmodule ServiceRadarWebNGWeb.DashboardLive.Data.EmptyDefaults do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp empty_device_summary, do: %{total: 0, available: 0, unavailable: 0}
      defp empty_services_summary, do: %{total: 0, available: 0, unavailable: 0, availability_pct: 0.0}
      defp empty_flow_summary, do: %{bytes_total: 0, packets_total: 0, flow_count: 0, bps: 0.0, pps: 0.0, link_count: 0}

      defp empty_mtr_summary,
        do: %{
          path_count: 0,
          endpoint_sample_count: 0,
          loss_sample_count: 0,
          latency_sample_count: 0,
          avg_loss_pct: nil,
          avg_latency_ms: nil,
          degraded_count: 0
        }

      defp empty_camera_summary, do: %{total: 0, online: 0, offline: 0, recording: 0, tiles: []}

      defp empty_survey_summary,
        do: Map.merge(%{sample_count: 0, session_count: 0, avg_rssi: 0.0, secure_count: 0}, empty_survey_raster_summary())

      defp empty_survey_raster_summary,
        do: %{
          raster_session_id: nil,
          raster_generated_at: nil,
          raster_cell_count: 0,
          raster_cells: [],
          raster_surface_data_uri: nil,
          raster_aspect_ratio: 1.78,
          floorplan_segment_count: 0,
          floorplan_segments: [],
          ap_marker_count: 0,
          ap_markers: [],
          raster_metadata: %{},
          raster_playlist_entry_id: nil,
          raster_playlist_label: nil,
          raster_playlist_diagnostics: []
        }

      defp empty_alert_summary, do: ServiceRadarWebNGWeb.Stats.empty_alerts_summary()
      defp empty_event_summary, do: ServiceRadarWebNGWeb.Stats.empty_events_summary()

      defp empty_virtualization_summary,
        do: %{
          available: false,
          host_count: 0,
          guest_count: 0,
          running_guests: 0,
          stopped_guests: 0,
          datastore_count: 0,
          storage_system_count: 0,
          provider_label: "No hypervisor inventory",
          avg_host_cpu_pct: 0.0,
          max_host_cpu_pct: 0.0,
          max_host_memory_pct: 0.0,
          max_guest_cpu_pct: 0.0,
          max_guest_memory_pct: 0.0,
          max_guest_disk_pct: 0.0,
          max_datastore_pct: 0.0,
          bottleneck_count: 0,
          ceph_warning_count: 0,
          ceph_error_count: 0,
          ceph_health_label: "No clustered storage",
          pressure_items: [],
          status_label: "No inventory",
          status_tone: "idle"
        }

      defp empty_threat_intel_summary,
        do: %{
          imported_indicators: 0,
          source_objects: 0,
          matched_ips: 0,
          indicator_matches: 0,
          max_severity: 0,
          sources: 0,
          latest_provider: nil,
          latest_source: nil,
          latest_status: nil,
          latest_message: nil,
          latest_attempt_at: nil,
          latest_success_at: nil,
          latest_sync_indicators: 0,
          latest_sync_skipped: 0,
          latest_sync_total: 0,
          recent_matches: []
        }

      defp empty_trace_summary,
        do: %{total: 0, errors: 0, avg_duration_ms: 0.0, p95_duration_ms: 0.0, error_rate: 0.0, successful: 0}
    end
  end
end
