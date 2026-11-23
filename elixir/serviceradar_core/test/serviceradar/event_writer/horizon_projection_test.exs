defmodule ServiceRadar.EventWriter.HorizonProjectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.HorizonProjection
  alias ServiceRadar.TestSupport.StreamLoadFE

  defp ocsf_row(payload) do
    message = %{
      data: Jason.encode!(payload),
      metadata: %{subject: "events.ocsf.processed"}
    }

    Events.parse_message(message)
  end

  defp outage_row(id \\ "out-2026-001") do
    ocsf_row(%{
      "id" => "horizon.outages:#{id}:1763913600000",
      "time" => "2026-11-23T16:00:00Z",
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1,
      "severity_id" => 5,
      "log_name" => "horizon.outage",
      "log_provider" => "horizon.outages",
      "message" => "Horizon major outage on asn AS13335 (us-east)",
      "unmapped" => %{
        "source" => "horizon.outages",
        "outage_id" => id,
        "horizon_outage_id" => id,
        "status" => "active",
        "severity" => "major",
        "level" => "critical",
        "entity_type" => "asn",
        "entity_key" => "AS13335",
        "affected_asn" => "AS13335",
        "region" => "us-east",
        "covering_prefix" => "1.1.1.0/24",
        "corroborating_pop_count" => 7,
        "avg_forwarding_loss_pct" => 42.5,
        "avg_synthetic_failure_pct" => 88.0,
        "window_start_unix_ms" => 1_763_913_000_000,
        "window_end_unix_ms" => 1_763_913_600_000,
        "correlated_bgp_event_ids" => ["bgp-1", "bgp-2"]
      }
    })
  end

  describe "build_projections/1" do
    test "projects horizon.outage OCSF payload matching plugins/horizon-feed shape" do
      %{outages: [outage], bgp_events: [], bgp_zombies: []} =
        HorizonProjection.build_projections([outage_row()])

      assert outage.outage_id == "out-2026-001"
      assert outage.status == "active"
      assert outage.severity == "major"
      assert outage.entity_type == "asn"
      assert outage.entity_key == "AS13335"
      assert outage.region == "us-east"
      assert outage.covering_prefix == "1.1.1.0/24"
      assert outage.origin_asn == 13_335
      assert outage.corroborating_pop_count == 7
      assert outage.avg_forwarding_loss_pct == 42.5
      assert outage.avg_synthetic_failure_pct == 88.0
      assert outage.window_start_ms == 1_763_913_000_000
      assert outage.window_end_ms == 1_763_913_600_000
      assert outage.correlated_bgp_event_ids == ["bgp-1", "bgp-2"]
      assert outage.raw_data["outage_id"] == "out-2026-001"
    end

    test "projects horizon.bgp_anomaly and horizon.bgp_watchlist into horizon_bgp_events" do
      anomaly =
        ocsf_row(%{
          "id" => "horizon.bgp_anomalies:bgp-anom-1",
          "time" => "2026-11-23T16:05:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 5,
          "log_name" => "horizon.bgp_anomaly",
          "log_provider" => "horizon.bgp_anomalies",
          "unmapped" => %{
            "event_id" => "bgp-anom-1",
            "kind" => "hijack",
            "level" => "critical",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_512,
            "as_path" => [3356, 64_500, 64_512],
            "rpki_status" => "invalid",
            "caida_leak_inference" => "valley_free_violation"
          }
        })

      watchlist =
        ocsf_row(%{
          "id" => "horizon.bgp_watchlist:bgp-wl-9:1763914200000",
          "time" => "2026-11-23T16:10:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 4,
          "log_name" => "horizon.bgp_watchlist",
          "log_provider" => "horizon.bgp_watchlist",
          "unmapped" => %{
            "event_id" => "bgp-wl-9",
            "watchlist_id" => "wl-edge-1",
            "label" => "Prod Edge Prefix",
            "level" => "warning",
            "event_type" => "origin_change",
            "watched_prefix" => "203.0.113.0/24",
            "observed_prefix" => "203.0.113.0/24",
            "covering_prefix" => "203.0.113.0/24",
            "observed_origin_asn" => 64_555,
            "observed_as_path" => [174, 64_555]
          }
        })

      %{outages: [], bgp_events: events, bgp_zombies: []} =
        HorizonProjection.build_projections([anomaly, watchlist])

      assert length(events) == 2

      by_id = Map.new(events, &{&1.event_id, &1})

      assert by_id["bgp-anom-1"].kind == "hijack"
      assert by_id["bgp-anom-1"].level == "critical"
      assert by_id["bgp-anom-1"].prefix == "198.51.100.0/24"
      assert by_id["bgp-anom-1"].origin_asn == 64_512
      assert by_id["bgp-anom-1"].as_path == [3356, 64_500, 64_512]
      assert by_id["bgp-anom-1"].rpki_status == "invalid"
      assert by_id["bgp-anom-1"].caida_leak_inference == "valley_free_violation"

      assert by_id["bgp-wl-9"].kind == "watchlist"
      assert by_id["bgp-wl-9"].level == "warning"
      assert by_id["bgp-wl-9"].prefix == "203.0.113.0/24"
      assert by_id["bgp-wl-9"].origin_asn == 64_555
      assert by_id["bgp-wl-9"].as_path == [174, 64_555]
      assert by_id["bgp-wl-9"].watchlist_id == "wl-edge-1"
      assert by_id["bgp-wl-9"].client_label == "Prod Edge Prefix"
    end

    test "projects horizon.bgp_zombie OCSF payload and ignores control events" do
      zombie =
        ocsf_row(%{
          "id" => "horizon.bgp_zombies:ep-77:active:1763914500000",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 3,
          "log_name" => "horizon.bgp_zombie",
          "log_provider" => "horizon.bgp_zombies",
          "unmapped" => %{
            "episode_id" => "ep-77",
            "status" => "active",
            "covering_prefix" => "192.0.2.0/24",
            "origin_asn" => 65_100,
            "divergence_pct" => 37.5,
            "is_beacon" => true,
            "withdrawn_peers" => 210,
            "total_peers" => 320,
            "stuck_peer_asns" => [1299, 2914],
            "first_seen" => "2026-11-23T15:30:00Z"
          }
        })

      snapshot_complete =
        ocsf_row(%{
          "id" => "horizon.outages:snapshot:1",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 1,
          "log_name" => "horizon.outage.snapshot_complete",
          "unmapped" => %{"condition_scope_complete" => "horizon.outages"}
        })

      %{outages: [], bgp_events: [], bgp_zombies: [projected]} =
        HorizonProjection.build_projections([zombie, snapshot_complete])

      assert projected.episode_id == "ep-77"
      assert projected.status == "active"
      assert projected.prefix == "192.0.2.0/24"
      assert projected.origin_asn == 65_100
      assert projected.divergence_pct == 37.5
      assert projected.is_beacon == true
      assert projected.withdrawn_peers == 210
      assert projected.total_peers == 320
      assert projected.stuck_peer_asns == [1299, 2914]
      assert projected.first_seen_at == ~U[2026-11-23 15:30:00Z]
      assert projected.resolved_at == nil
    end
  end

  describe "project_rows/2" do
    test "short-circuits when StarRocks is disabled or no horizon.* rows exist" do
      non_horizon =
        ocsf_row(%{
          "id" => Ecto.UUID.generate(),
          "time" => "2026-11-23T16:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "events.ocsf.processed"
        })

      load_fn = fn _dataset, _rows ->
        flunk("load_fn must not be called")
      end

      assert :ok ==
               HorizonProjection.project_rows([non_horizon],
                 starrocks_enabled: true,
                 load: load_fn
               )

      assert :ok ==
               HorizonProjection.project_rows([outage_row()],
                 starrocks_enabled: false,
                 load: load_fn
               )
    end

    test "isolates per-table StarRocks load failures and continues sibling tables" do
      bgp =
        ocsf_row(%{
          "id" => "horizon.bgp_anomalies:bgp-2",
          "time" => "2026-11-23T16:05:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 5,
          "log_name" => "horizon.bgp_anomaly",
          "unmapped" => %{
            "event_id" => "bgp-2",
            "kind" => "leak",
            "level" => "critical",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_512
          }
        })

      parent = self()

      load_fn = fn
        :horizon_outages, _rows ->
          {:error, :warehouse_unavailable}

        :horizon_bgp_events, rows ->
          send(parent, {:loaded, :horizon_bgp_events, length(rows)})
          {:ok, %{loaded: length(rows)}}
      end

      log =
        capture_log(fn ->
          assert :ok ==
                   HorizonProjection.project_rows([outage_row(), bgp],
                     starrocks_enabled: true,
                     load: load_fn
                   )
        end)

      assert log =~ "Horizon StarRocks projection failed for horizon_outages (fail-open)"
      assert_received {:loaded, :horizon_bgp_events, 1}
    end
  end

  describe "StarRocks routing and encoding" do
    test "routes canonical Horizon entities to StarRocks and requires StarRocks when disabled" do
      prev = Application.get_env(:serviceradar_core, StarRocks)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:serviceradar_core, StarRocks)
        else
          Application.put_env(:serviceradar_core, StarRocks, prev)
        end
      end)

      Application.put_env(:serviceradar_core, StarRocks, enabled: false)

      for entity <- ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths) do
        assert Readers.mode_for(entity) == {:error, :starrocks_required}
        assert Readers.backend(entity) == {:error, :starrocks_required}
      end

      Application.put_env(:serviceradar_core, StarRocks, enabled: true)

      for entity <- ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths) do
        assert Readers.mode_for(entity) == "starrocks"
        assert Readers.backend(entity) == :starrocks
      end

      assert Destination.table_for(:horizon_outages) == "horizon_outages"
      assert Destination.table_for(:horizon_bgp_events) == "horizon_bgp_events"
      assert Destination.table_for(:horizon_bgp_zombies) == "horizon_bgp_zombies"
      assert Destination.table_for(:horizon_path_hops) == "horizon_path_hops"
    end

    test "encodes Horizon rows as JSON for StarRocks Stream Load" do
      %{outages: outages} = HorizonProjection.build_projections([outage_row()])
      [encoded] = Rows.encode(:horizon_outages, outages)

      assert encoded["outage_id"] == "out-2026-001"
      assert encoded["origin_asn"] == 13_335
      assert encoded["correlated_bgp_event_ids"] == ["bgp-1", "bgp-2"]
      assert {:ok, _json} = Jason.encode(encoded)
    end

    test "projects Horizon rows when events are cut over to the StarRocks warehouse path" do
      prev = Application.get_env(:serviceradar_core, StarRocks)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:serviceradar_core, StarRocks)
        else
          Application.put_env(:serviceradar_core, StarRocks, prev)
        end
      end)

      if Process.whereis(LoadSupervisor) == nil do
        start_supervised!({LoadSupervisor, [max_in_flight: 2, wait_timeout_ms: 5_000]})
      end

      fe_http = StreamLoadFE.start!()

      Application.put_env(:serviceradar_core, StarRocks,
        enabled: true,
        cutover_datasets: [:events],
        fe_http: fe_http
      )

      parent = self()
      handler_id = {__MODULE__, :stream_load_spy, make_ref()}

      :telemetry.attach(
        handler_id,
        [:serviceradar, :starrocks, :stream_load, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_load_stop, metadata.dataset, metadata.table})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      bgp_row =
        ocsf_row(%{
          "id" => "horizon.bgp_anomalies:bgp-cutover-1",
          "time" => "2026-11-23T16:05:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 5,
          "log_name" => "horizon.bgp_anomaly",
          "log_provider" => "horizon.bgp_anomalies",
          "unmapped" => %{
            "event_id" => "bgp-cutover-1",
            "kind" => "hijack",
            "level" => "critical",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_512
          }
        })

      assert {:ok, 2} = Events.store_event_rows([outage_row(), bgp_row])

      assert_receive {:stream_load_stop, :events, "events"}, 5_000
      assert_receive {:stream_load_stop, :horizon_outages, "horizon_outages"}, 5_000
      assert_receive {:stream_load_stop, :horizon_bgp_events, "horizon_bgp_events"}, 5_000

      assert_receive {:wire_request, event_rows}, 5_000
      assert_receive {:wire_request, outage_rows}, 5_000
      assert_receive {:wire_request, bgp_rows}, 5_000

      assert Enum.sort(Enum.map(event_rows, & &1["log_name"])) == [
               "horizon.bgp_anomaly",
               "horizon.outage"
             ]

      assert [%{"outage_id" => "out-2026-001", "origin_asn" => 13_335}] = outage_rows
      assert [%{"event_id" => "bgp-cutover-1", "origin_asn" => 64_512}] = bgp_rows
    end
  end
end
