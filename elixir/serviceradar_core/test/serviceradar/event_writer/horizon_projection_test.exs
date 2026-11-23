defmodule ServiceRadar.EventWriter.HorizonProjectionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.HorizonProjection

  defp ocsf_row(payload) do
    message = %{
      data: Jason.encode!(payload),
      metadata: %{subject: "events.ocsf.processed"}
    }

    Events.parse_message(message)
  end

  describe "build_projections/1" do
    test "projects horizon.outage OCSF payload matching plugins/horizon-feed shape" do
      row =
        ocsf_row(%{
          "id" => "horizon.outages:out-2026-001:1763913600000",
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
            "outage_id" => "out-2026-001",
            "horizon_outage_id" => "out-2026-001",
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

      %{outages: [outage], bgp_events: [], bgp_zombies: []} =
        HorizonProjection.build_projections([row])

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
    test "short-circuits when batch contains no horizon.* events" do
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

      insert_fn = fn _table, _rows, _opts ->
        flunk("insert_fn must not be called for non-Horizon rows")
      end

      assert :ok == HorizonProjection.project_rows([non_horizon], insert_fn: insert_fn)
    end

    test "dispatches upserts per populated table and fails open on error" do
      outage =
        ocsf_row(%{
          "id" => "horizon.outages:out-9:1",
          "time" => "2026-11-23T16:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.outage",
          "unmapped" => %{
            "outage_id" => "out-9",
            "status" => "active",
            "severity" => "minor",
            "entity_type" => "saas",
            "entity_key" => "github.com"
          }
        })

      parent = self()

      insert_fn = fn table, rows, opts ->
        send(parent, {:inserted, table, length(rows), opts[:conflict_target]})
        {length(rows), nil}
      end

      assert :ok == HorizonProjection.project_rows([outage], insert_fn: insert_fn)
      assert_received {:inserted, "horizon_outages", 1, [:time, :outage_id]}

      failing_insert = fn _table, _rows, _opts ->
        raise RuntimeError, "simulated CNPG outage"
      end

      log =
        capture_log(fn ->
          assert :ok == HorizonProjection.project_rows([outage], insert_fn: failing_insert)
        end)

      assert log =~ "Horizon OCSF projection failed (fail-open)"
    end
  end
end
