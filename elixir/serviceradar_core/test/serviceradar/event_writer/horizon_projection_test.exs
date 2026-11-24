defmodule ServiceRadar.EventWriter.HorizonProjectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator
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

  defp path_hop_row(overrides \\ %{}) do
    unmapped =
      Map.merge(
        %{
          "source" => "horizon.path_hops",
          "observed_at_unix_ms" => 1_763_914_500_000,
          "round_id" => "round-42",
          "target_id" => "saas-github-web",
          "pop_id" => "vantage-deadbeef",
          "hop_ttl" => 5,
          "hop_ip" => "198.51.100.5",
          "router_alias_id" => "rtr-iad-01",
          "alias_confidence" => "high",
          "asn" => 13_335,
          "as_org" => "Cloudflare, Inc.",
          "is_cloud" => true,
          "cloud_provider" => "cloudflare",
          "cloud_region" => "us-east",
          "forwarding_loss_pct" => 12.5,
          "avg_rtt_ms" => 8.4,
          "effective_path_mtu" => 1500,
          "mtu_blackhole_detected" => true,
          "blackhole_hop_ttl" => 6
        },
        Map.get(overrides, "unmapped", %{})
      )

    payload =
      %{
        "id" => "horizon.path_hops:round-42:vantage-deadbeef:5:1763914500000",
        "time" => "2026-11-23T16:15:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "severity_id" => 3,
        "log_name" => "horizon.path_hop",
        "log_provider" => "horizon.path_hops",
        "message" =>
          "Horizon path hop ttl=5 198.51.100.5 for saas-github-web from vantage-deadbeef (loss=12.5%, rtt=8.4ms)"
      }
      |> Map.merge(Map.delete(overrides, "unmapped"))
      |> Map.put("unmapped", unmapped)

    ocsf_row(payload)
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

    test "sets resolved_at for resolved/cleared zombies, dedupes by (time, id), and drops malformed rows" do
      resolved_zombie =
        ocsf_row(%{
          "id" => "horizon.bgp_zombies:ep-88:resolved:1763914500000",
          "time" => "2026-11-23T16:20:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 2,
          "log_name" => "horizon.bgp_zombie",
          "unmapped" => %{
            "episode_id" => "ep-88",
            "status" => "resolved",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_500
          }
        })

      malformed_outage =
        ocsf_row(%{
          "id" => "horizon.outages:missing-id",
          "time" => "2026-11-23T16:20:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.outage",
          "unmapped" => %{"status" => "active"}
        })

      dup1 = outage_row("out-dup-1")
      dup2 = put_in(dup1, [:unmapped, "status"], "resolved")

      %{outages: [outage], bgp_events: [], bgp_zombies: [zombie]} =
        HorizonProjection.build_projections([dup1, dup2, malformed_outage, resolved_zombie])

      assert outage.outage_id == "out-dup-1"
      assert outage.status == "resolved"
      assert zombie.episode_id == "ep-88"
      assert zombie.resolved_at == ~U[2026-11-23 16:20:00Z]
    end

    test "projects horizon.path_hop OCSF payload matching plugins/horizon-feed shape" do
      %{outages: [], bgp_events: [], bgp_zombies: [], path_hops: [hop]} =
        HorizonProjection.build_projections([path_hop_row()])

      assert hop.time == ~U[2026-11-23 16:15:00Z]
      assert hop.round_id == "round-42"
      assert hop.target_id == "saas-github-web"
      assert hop.pop_id == "vantage-deadbeef"
      assert hop.hop_ttl == 5
      assert hop.hop_ip == "198.51.100.5"
      assert hop.router_alias_id == "rtr-iad-01"
      assert hop.alias_confidence == 1.0
      assert hop.asn == 13_335
      assert hop.as_org == "Cloudflare, Inc."
      assert hop.is_cloud == true
      assert hop.cloud_provider == "cloudflare"
      assert hop.cloud_region == "us-east"
      assert hop.forwarding_loss_pct == 12.5
      assert hop.avg_rtt_ms == 8.4
      assert hop.effective_path_mtu == 1500
      assert hop.mtu_blackhole_detected == true
      assert hop.blackhole_hop_ttl == 6
      assert hop.raw_data["alias_confidence"] == "high"
      assert hop.raw_data["round_id"] == "round-42"

      [encoded] = Rows.encode(:horizon_path_hops, [hop])
      assert encoded["round_id"] == "round-42"
      assert encoded["alias_confidence"] == 1.0
      assert encoded["mtu_blackhole_detected"] == true
      assert {:ok, _json} = Jason.encode(encoded)
    end

    test "handles horizon.path_hops timeout hops, nullable fields, coercions, dedupe, and malformed rows" do
      timeout_hop =
        ocsf_row(%{
          "id" => "horizon.path_hops:round-42:vantage-deadbeef:6:1763914500000",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 1,
          "log_provider" => "horizon.path_hops",
          "unmapped" => %{
            "source" => "horizon.path_hops",
            "observed_at_unix_ms" => 1_763_914_500_000,
            "round_id" => "round-42",
            "target_id" => "saas-github-web",
            "pop_id" => "vantage-deadbeef",
            "hop_ttl" => 6,
            "is_cloud" => false,
            "forwarding_loss_pct" => 100,
            "avg_rtt_ms" => 0,
            "mtu_blackhole_detected" => false
          }
        })

      unix_ms_fallback_hop = %{
        log_provider: "horizon.path_hops",
        time: nil,
        unmapped: %{
          "observed_at_unix_ms" => 1_763_914_500_000,
          "round_id" => "round-43",
          "target_id" => "dns-cloudflare-1111",
          "pop_id" => "vantage-12345678",
          "hop_ttl" => "2",
          "hop_ip" => "1.1.1.1",
          "alias_confidence" => "medium",
          "asn" => "AS13335",
          "forwarding_loss_pct" => "0.5",
          "avg_rtt_ms" => "4"
        }
      }

      dup1 = path_hop_row(%{"unmapped" => %{"avg_rtt_ms" => 8.4, "alias_confidence" => "low"}})
      dup2 = path_hop_row(%{"unmapped" => %{"avg_rtt_ms" => 9.1, "alias_confidence" => 0.85}})

      malformed_missing_ttl =
        ocsf_row(%{
          "id" => "horizon.path_hops:bad:1",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.path_hop",
          "log_provider" => "horizon.path_hops",
          "unmapped" => %{
            "round_id" => "round-42",
            "target_id" => "saas-github-web",
            "pop_id" => "vantage-deadbeef"
          }
        })

      malformed_negative_ttl = path_hop_row(%{"unmapped" => %{"hop_ttl" => -1}})

      %{path_hops: hops} =
        HorizonProjection.build_projections([
          timeout_hop,
          unix_ms_fallback_hop,
          dup1,
          dup2,
          malformed_missing_ttl,
          malformed_negative_ttl
        ])

      assert length(hops) == 3

      by_key = Map.new(hops, &{{&1.round_id, &1.hop_ttl}, &1})

      t_hop = by_key[{"round-42", 6}]
      assert t_hop.hop_ip == nil
      assert t_hop.router_alias_id == nil
      assert t_hop.alias_confidence == nil
      assert t_hop.asn == nil
      assert t_hop.as_org == nil
      assert t_hop.is_cloud == false
      assert t_hop.cloud_provider == nil
      assert t_hop.cloud_region == nil
      assert t_hop.forwarding_loss_pct == 100.0
      assert t_hop.avg_rtt_ms == 0.0
      assert t_hop.effective_path_mtu == nil
      assert t_hop.mtu_blackhole_detected == false
      assert t_hop.blackhole_hop_ttl == nil

      fb_hop = by_key[{"round-43", 2}]
      assert fb_hop.time == DateTime.from_unix!(1_763_914_500_000, :millisecond)
      assert fb_hop.alias_confidence == 0.5
      assert fb_hop.asn == 13_335
      assert fb_hop.forwarding_loss_pct == 0.5
      assert fb_hop.avg_rtt_ms == 4.0

      deduped = by_key[{"round-42", 5}]
      assert deduped.avg_rtt_ms == 9.1
      assert deduped.alias_confidence == 0.85
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

    test "isolates raised exceptions on one table and still loads sibling Horizon tables" do
      bgp =
        ocsf_row(%{
          "id" => "horizon.bgp_anomalies:bgp-exc-1",
          "time" => "2026-11-23T16:05:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.bgp_anomaly",
          "unmapped" => %{
            "event_id" => "bgp-exc-1",
            "kind" => "hijack",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_501
          }
        })

      zombie =
        ocsf_row(%{
          "id" => "horizon.bgp_zombies:ep-exc-1",
          "time" => "2026-11-23T16:06:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.bgp_zombie",
          "unmapped" => %{
            "episode_id" => "ep-exc-1",
            "status" => "active",
            "covering_prefix" => "203.0.113.0/24",
            "origin_asn" => 64_502
          }
        })

      parent = self()

      load_fn = fn
        :horizon_outages, _rows ->
          raise "simulated outage encoder crash"

        dataset, rows ->
          send(parent, {:loaded, dataset, length(rows)})
          {:ok, %{loaded: length(rows)}}
      end

      log =
        capture_log(fn ->
          assert :ok ==
                   HorizonProjection.project_rows([outage_row(), bgp, zombie, path_hop_row()],
                     starrocks_enabled: true,
                     load: load_fn
                   )
        end)

      assert log =~ "Horizon StarRocks projection raised for horizon_outages (fail-open)"
      assert_received {:loaded, :horizon_bgp_events, 1}
      assert_received {:loaded, :horizon_bgp_zombies, 1}
      assert_received {:loaded, :horizon_path_hops, 1}
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

      assert {:ok, 3} = Events.store_event_rows([outage_row(), bgp_row, path_hop_row()])

      assert_receive {:stream_load_stop, :events, "events"}, 5_000
      assert_receive {:stream_load_stop, :horizon_outages, "horizon_outages"}, 5_000
      assert_receive {:stream_load_stop, :horizon_bgp_events, "horizon_bgp_events"}, 5_000
      assert_receive {:stream_load_stop, :horizon_path_hops, "horizon_path_hops"}, 5_000

      assert_receive {:wire_request, event_rows}, 5_000
      assert_receive {:wire_request, outage_rows}, 5_000
      assert_receive {:wire_request, bgp_rows}, 5_000
      assert_receive {:wire_request, hop_rows}, 5_000

      assert Enum.sort(Enum.map(event_rows, & &1["log_name"])) == [
               "horizon.bgp_anomaly",
               "horizon.outage",
               "horizon.path_hop"
             ]

      assert [%{"outage_id" => "out-2026-001", "origin_asn" => 13_335}] = outage_rows
      assert [%{"event_id" => "bgp-cutover-1", "origin_asn" => 64_512}] = bgp_rows

      assert [
               %{
                 "round_id" => "round-42",
                 "target_id" => "saas-github-web",
                 "pop_id" => "vantage-deadbeef",
                 "hop_ttl" => 5,
                 "hop_ip" => "198.51.100.5",
                 "alias_confidence" => 1.0,
                 "asn" => 13_335,
                 "mtu_blackhole_detected" => true,
                 "blackhole_hop_ttl" => 6
               }
             ] = hop_rows
    end

    test "encodes all four Horizon datasets for StarRocks Stream Load JSON" do
      [bgp_encoded] =
        Rows.encode(:horizon_bgp_events, [
          %{
            time: ~U[2026-11-23 16:05:00Z],
            event_id: "bgp-enc-1",
            kind: "watchlist",
            level: "warning",
            prefix: "198.51.100.0/24",
            origin_asn: 64_501,
            as_path: [64_500, 64_501],
            rpki_status: nil,
            caida_leak_inference: nil,
            watchlist_id: "wl-1",
            client_label: "Synthetic Edge",
            raw_data: %{"event_id" => "bgp-enc-1"}
          }
        ])

      [zombie_encoded] =
        Rows.encode(:horizon_bgp_zombies, [
          %{
            time: ~U[2026-11-23 16:10:00Z],
            episode_id: "ep-enc-1",
            status: "resolved",
            prefix: "203.0.113.0/24",
            origin_asn: 64_502,
            divergence_pct: 41.2,
            is_beacon: true,
            withdrawn_peers: 120,
            total_peers: 200,
            stuck_peer_asns: [64_510],
            first_seen_at: ~U[2026-11-23 15:00:00Z],
            resolved_at: ~U[2026-11-23 16:10:00Z],
            raw_data: %{"episode_id" => "ep-enc-1"}
          }
        ])

      [hop_encoded] =
        Rows.encode(:horizon_path_hops, [
          %{
            time: ~U[2026-11-23 16:15:00Z],
            round_id: "rnd-1",
            target_id: "tgt-1",
            pop_id: "pop-east-1",
            hop_ttl: 3,
            hop_ip: "192.0.2.15",
            router_alias_id: "rtr-1",
            alias_confidence: 0.95,
            asn: 64_503,
            as_org: "Example Transit",
            is_cloud: true,
            cloud_provider: "example_cloud",
            cloud_region: "us-east-1",
            forwarding_loss_pct: 1.5,
            avg_rtt_ms: 14.2,
            effective_path_mtu: 1500,
            mtu_blackhole_detected: false,
            blackhole_hop_ttl: nil,
            raw_data: %{"round_id" => "rnd-1"}
          }
        ])

      assert bgp_encoded["event_id"] == "bgp-enc-1"
      assert bgp_encoded["kind"] == "watchlist"
      assert zombie_encoded["episode_id"] == "ep-enc-1"
      assert zombie_encoded["is_beacon"] == true
      assert zombie_encoded["first_seen_at"] == "2026-11-23T15:00:00Z"
      assert zombie_encoded["resolved_at"] == "2026-11-23T16:10:00Z"
      assert hop_encoded["hop_ttl"] == 3
      assert hop_encoded["is_cloud"] == true
      assert hop_encoded["mtu_blackhole_detected"] == false

      for encoded <- [bgp_encoded, zombie_encoded, hop_encoded] do
        assert {:ok, _json} = Jason.encode(encoded)
      end
    end

    test "Events.store_event_rows fails open over HTTP when one Horizon table Stream Load fails" do
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

      fe_http = start_partial_fail_fe!("horizon_outages")

      Application.put_env(:serviceradar_core, StarRocks,
        enabled: true,
        cutover_datasets: [:events],
        fe_http: fe_http
      )

      watchlist_row =
        ocsf_row(%{
          "id" => "horizon.bgp_watchlist:bgp-wl-failopen",
          "time" => "2026-11-23T16:10:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 4,
          "log_name" => "horizon.bgp_watchlist",
          "unmapped" => %{
            "event_id" => "bgp-wl-failopen",
            "watchlist_id" => "wl-edge-9",
            "label" => "Synthetic Prefix",
            "level" => "warning",
            "observed_prefix" => "203.0.113.0/24",
            "observed_origin_asn" => 64_509,
            "observed_as_path" => [64_500, 64_509]
          }
        })

      log =
        capture_log(fn ->
          assert {:ok, 2} = Events.store_event_rows([outage_row("out-fail-http"), watchlist_row])
        end)

      assert log =~ "Horizon StarRocks projection failed for horizon_outages (fail-open)"
      assert_receive {:wire_table, "events", event_rows}, 5_000
      assert_receive {:wire_table, "horizon_outages", _failed_outage_rows}, 5_000
      assert_receive {:wire_table, "horizon_bgp_events", bgp_rows}, 5_000

      assert length(event_rows) == 2

      assert [
               %{
                 "event_id" => "bgp-wl-failopen",
                 "kind" => "watchlist",
                 "prefix" => "203.0.113.0/24",
                 "origin_asn" => 64_509,
                 "client_label" => "Synthetic Prefix"
               }
             ] = bgp_rows
    end
  end

  describe "StarRocks schema migration 0044_horizon_tables.sql" do
    test "Schema.migrations/0 and SchemaMigrator apply migration 0044 idempotently" do
      migration = Enum.find(Schema.migrations(), &(&1.version == 44))
      assert migration
      assert migration.name == "horizon_tables"

      {:ok, agent} = Agent.start_link(fn -> %{ledger: []} end)

      query_fn = fn sql ->
        Agent.get_and_update(agent, fn state ->
          cond do
            sql == "SHOW BACKENDS" ->
              {{:ok, %{columns: ["BackendId", "Alive"], rows: [[1, "true"]]}}, state}

            sql == "SHOW COMPUTE NODES" ->
              {{:ok, %{columns: ["ComputeNodeId", "Alive"], rows: []}}, state}

            String.starts_with?(sql, "SELECT version FROM ") ->
              {{:ok, %{columns: ["version"], rows: Enum.map(state.ledger, &[&1])}}, state}

            String.starts_with?(sql, "SELECT TABLE_NAME, PARTITION_KEY") ->
              {{:ok, %{columns: ["TABLE_NAME", "PARTITION_KEY"], rows: []}}, state}

            String.starts_with?(sql, "INSERT INTO ") ->
              [_, version] = Regex.run(~r/VALUES \((\d+),/, sql)

              {{:ok, %{columns: [], rows: []}},
               %{state | ledger: state.ledger ++ [String.to_integer(version)]}}

            true ->
              {{:ok, %{columns: [], rows: []}}, state}
          end
        end)
      end

      opts = [
        query: query_fn,
        try_lock: fn fun -> fun.(fn -> :ok end) end,
        migrations: [migration],
        database: "horizon_lab",
        sleep: fn _ms -> :ok end,
        workload_groups: fn _query -> :ok end
      ]

      assert {:ok, [44]} = SchemaMigrator.migrate(opts)
      assert {:ok, []} = SchemaMigrator.migrate(opts)
      assert Agent.get(agent, & &1.ledger) == [44]
    end
  end

  defp start_partial_fail_fe!(fail_table) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_partial_fail(listener, parent, fail_table) end})
    "http://127.0.0.1:#{port}"
  end

  defp serve_partial_fail(listener, parent, fail_table) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {:ok, {:http_request, :PUT, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = recv_http_headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        [_, table] = Regex.run(~r|^/api/[^/]+/([^/]+)/_stream_load$|, path)
        send(parent, {:wire_table, table, rows})

        response =
          if table == fail_table do
            Jason.encode!(%{"Status" => "Fail", "Message" => "simulated load failure"})
          else
            Jason.encode!(%{
              "Status" => "Success",
              "NumberLoadedRows" => length(rows),
              "NumberFilteredRows" => 0
            })
          end

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve_partial_fail(listener, parent, fail_table)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_partial_fail(listener, parent, fail_table)
    end
  end

  defp recv_http_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, key, _, value}} ->
        recv_http_headers(
          socket,
          Map.put(headers, key |> to_string() |> String.downcase(), value)
        )
    end
  end
end
