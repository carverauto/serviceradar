defmodule ServiceRadar.EventWriter.HorizonProjectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Broadway.Message
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator
  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.HorizonProjection
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.ExternalProjection
  alias ServiceRadar.TestSupport.ExposureBroker
  alias ServiceRadar.TestSupport.StreamLoadFE
  alias ServiceRadarSRQL.Native

  defmodule JetStreamEventsSink do
    @moduledoc false
    use GenStage

    def start_link({producer, owner, expected_count}) do
      GenStage.start_link(__MODULE__, {producer, owner, expected_count})
    end

    @impl true
    def init({producer, owner, expected_count}) do
      {:consumer, %{owner: owner, expected_count: expected_count, buffer: [], done?: false},
       subscribe_to: [{producer, max_demand: 32, min_demand: 1}]}
    end

    @impl true
    def handle_events(_events, _from, %{done?: true} = state), do: {:noreply, [], state}

    def handle_events(events, _from, state) do
      buffer = state.buffer ++ events

      if length(buffer) >= state.expected_count do
        {batch, rest} = Enum.split(buffer, state.expected_count)

        routed =
          Enum.map(batch, fn event ->
            Pipeline.handle_message(:default, Pipeline.transform(event, []), %{})
          end)

        processor = Pipeline.processor_for_batcher(:events)
        rows = processor.build_rows(routed)
        store_result = processor.store_event_rows(rows)
        :ok = Pipeline.ack(:ack_ref, routed, [])

        send(
          state.owner,
          {:jetstream_batch,
           %{
             batchers: Enum.map(routed, & &1.batcher),
             processor: processor,
             row_count: length(rows),
             store_result: store_result,
             rows: rows
           }}
        )

        {:noreply, [], %{state | buffer: rest, done?: true}}
      else
        {:noreply, [], %{state | buffer: buffer}}
      end
    end
  end

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
          "alias_confidence" => 0.95,
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

      assert map_size(hop) == 19

      assert %{
               time: ~U[2026-11-23 16:15:00Z],
               round_id: "round-42",
               target_id: "saas-github-web",
               pop_id: "vantage-deadbeef",
               hop_ttl: 5,
               hop_ip: "198.51.100.5",
               router_alias_id: "rtr-iad-01",
               alias_confidence: 0.95,
               asn: 13_335,
               as_org: "Cloudflare, Inc.",
               is_cloud: true,
               cloud_provider: "cloudflare",
               cloud_region: "us-east",
               forwarding_loss_pct: 12.5,
               avg_rtt_ms: 8.4,
               effective_path_mtu: 1500,
               mtu_blackhole_detected: true,
               blackhole_hop_ttl: 6,
               raw_data: %{"alias_confidence" => 0.95, "round_id" => "round-42"}
             } = hop

      [encoded] = Rows.encode(:horizon_path_hops, [hop])
      assert encoded |> Map.keys() |> Enum.sort() == path_hops_ddl_columns()

      for col <- path_hops_not_null_columns() do
        refute is_nil(Map.fetch!(encoded, col)),
               "NOT NULL column #{col} must not encode as nil"
      end

      assert %{
               "round_id" => "round-42",
               "alias_confidence" => 0.95,
               "mtu_blackhole_detected" => true
             } = encoded

      assert {:ok, _json} = Jason.encode(encoded)
    end

    test "handles horizon.path_hop timeout hops, nullable fields, coercions, dedupe, and malformed rows" do
      timeout_hop =
        ocsf_row(%{
          "id" => "horizon.path_hops:round-42:vantage-deadbeef:6:1763914500000",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 1,
          "log_name" => "horizon.path_hop",
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

      coerced_hop =
        path_hop_row(%{
          "id" => "horizon.path_hops:round-43:vantage-12345678:2:1763914500000",
          "unmapped" => %{
            "observed_at_unix_ms" => 1_700_000_000_000,
            "round_id" => "round-43",
            "target_id" => "dns-example-01",
            "pop_id" => "vantage-12345678",
            "hop_ttl" => "2",
            "hop_ip" => "203.0.113.2",
            "alias_confidence" => "high",
            "asn" => "AS64512",
            "forwarding_loss_pct" => "0.5",
            "avg_rtt_ms" => "4"
          }
        })

      ttl_zero_hop =
        path_hop_row(%{
          "id" => "horizon.path_hops:round-43:vantage-12345678:0:1763914500000",
          "unmapped" => %{
            "round_id" => "round-43",
            "target_id" => "dns-example-01",
            "pop_id" => "vantage-12345678",
            "hop_ttl" => 0
          }
        })

      other_pop_hop =
        path_hop_row(%{
          "id" => "horizon.path_hops:round-42:vantage-otherpop:5:1763914500000",
          "unmapped" => %{
            "pop_id" => "vantage-otherpop",
            "hop_ip" => "198.51.100.15",
            "avg_rtt_ms" => 11.2
          }
        })

      provider_only_hop =
        ocsf_row(%{
          "id" => "horizon.path_hops:round-44:vantage-deadbeef:1:1763914500000",
          "time" => "2026-11-23T16:15:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 1,
          "log_provider" => "horizon.path_hops",
          "unmapped" => %{
            "round_id" => "round-44",
            "target_id" => "saas-github-web",
            "pop_id" => "vantage-deadbeef",
            "hop_ttl" => 1
          }
        })

      control_event_hop =
        path_hop_row(%{"log_name" => "horizon.path_hop.snapshot_complete"})

      plural_log_name_hop =
        path_hop_row(%{"log_name" => "horizon.path_hops"})

      dup1 = path_hop_row(%{"unmapped" => %{"avg_rtt_ms" => 8.4, "alias_confidence" => "0.75"}})
      dup2 = path_hop_row(%{"unmapped" => %{"avg_rtt_ms" => 9.1, "alias_confidence" => "0.85"}})

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
      malformed_blank_round = path_hop_row(%{"unmapped" => %{"round_id" => "   "}})
      malformed_blank_target = path_hop_row(%{"unmapped" => %{"target_id" => ""}})
      malformed_nil_pop = path_hop_row(%{"unmapped" => %{"pop_id" => nil}})

      %{path_hops: hops} =
        HorizonProjection.build_projections([
          timeout_hop,
          coerced_hop,
          ttl_zero_hop,
          other_pop_hop,
          provider_only_hop,
          control_event_hop,
          plural_log_name_hop,
          dup1,
          dup2,
          malformed_missing_ttl,
          malformed_negative_ttl,
          malformed_blank_round,
          malformed_blank_target,
          malformed_nil_pop
        ])

      assert length(hops) == 5

      by_key = Map.new(hops, &{{&1.round_id, &1.pop_id, &1.hop_ttl}, &1})

      assert %{
               hop_ip: nil,
               router_alias_id: nil,
               alias_confidence: nil,
               asn: nil,
               as_org: nil,
               is_cloud: false,
               cloud_provider: nil,
               cloud_region: nil,
               forwarding_loss_pct: 100.0,
               avg_rtt_ms: 0.0,
               effective_path_mtu: nil,
               mtu_blackhole_detected: false,
               blackhole_hop_ttl: nil
             } = t_hop = by_key[{"round-42", "vantage-deadbeef", 6}]

      [encoded_timeout] = Rows.encode(:horizon_path_hops, [t_hop])

      for col <- path_hops_not_null_columns() do
        refute is_nil(Map.fetch!(encoded_timeout, col)),
               "NOT NULL column #{col} must not encode as nil for timeout hop"
      end

      assert %{
               time: ~U[2026-11-23 16:15:00Z],
               alias_confidence: nil,
               raw_data: %{"alias_confidence" => "high"},
               asn: 64_512,
               forwarding_loss_pct: 0.5,
               avg_rtt_ms: 4.0
             } = by_key[{"round-43", "vantage-12345678", 2}]

      assert %{hop_ttl: 0} = by_key[{"round-43", "vantage-12345678", 0}]

      assert %{avg_rtt_ms: 9.1, alias_confidence: 0.85} =
               by_key[{"round-42", "vantage-deadbeef", 5}]

      assert %{hop_ip: "198.51.100.15", avg_rtt_ms: 11.2} =
               by_key[{"round-42", "vantage-otherpop", 5}]
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

      provider_only =
        ocsf_row(%{
          "id" => Ecto.UUID.generate(),
          "time" => "2026-11-23T16:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_provider" => "horizon.path_hops",
          "unmapped" => %{
            "round_id" => "round-99",
            "target_id" => "saas-github-web",
            "pop_id" => "vantage-deadbeef",
            "hop_ttl" => 1
          }
        })

      load_fn = fn _dataset, _rows ->
        flunk("load_fn must not be called")
      end

      assert :ok ==
               HorizonProjection.project_rows([non_horizon, provider_only],
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

    test "forwards horizon.outage and horizon.bgp_anomaly to NATS independent of starrocks_enabled and normalizes via ExternalProjection" do
      parent = self()

      publish_nats = fn subject, payload, opts ->
        send(parent, {:nats_status, subject, Jason.decode!(payload), opts})
        :ok
      end

      asn_outage =
        ocsf_row(%{
          "id" => "out-asn-1",
          "time" => "2026-11-27T01:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.outage",
          "unmapped" => %{
            "outage_id" => "out-asn-1",
            "status" => "active",
            "entity_type" => "asn",
            "entity_key" => "AS13335",
            "affected_asn" => 13_335
          }
        })

      saas_cleared =
        ocsf_row(%{
          "id" => "out-saas-1",
          "time" => "2026-11-27T01:05:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.outage",
          "unmapped" => %{
            "outage_id" => "out-saas-1",
            "status" => "cleared",
            "entity_type" => "saas",
            "entity_key" => "cloud-akamai-us-east"
          }
        })

      bgp_rtbh =
        ocsf_row(%{
          "id" => "bgp-rtbh-1",
          "time" => "2026-11-27T01:10:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.bgp_anomaly",
          "unmapped" => %{
            "event_id" => "bgp-rtbh-1",
            "kind" => "rtbh_blackhole",
            "covering_prefix" => "198.51.100.0/24",
            "origin_asn" => 64_512,
            "rpki_status" => "invalid",
            "rtbh_blackhole" => true
          }
        })

      bgp_asn_only =
        ocsf_row(%{
          "id" => "bgp-leak-1",
          "time" => "2026-11-27T01:12:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "log_name" => "horizon.bgp_anomaly",
          "unmapped" => %{
            "event_id" => "bgp-leak-1",
            "kind" => "leak",
            "origin_asn" => 64_513,
            "rpki_status" => "valid",
            "rtbh_blackhole" => false
          }
        })

      load_fn = fn _dataset, _rows ->
        flunk("load_fn must not be called when starrocks_enabled is false")
      end

      assert :ok ==
               HorizonProjection.project_rows([asn_outage, saas_cleared, bgp_rtbh, bgp_asn_only],
                 starrocks_enabled: false,
                 load: load_fn,
                 publish_nats: publish_nats
               )

      assert_received {:nats_status, "serviceradar.horizon.outages.asn", asn_payload, asn_opts}
      assert {"Nats-Msg-Id", _} = List.keyfind(asn_opts[:headers], "Nats-Msg-Id", 0)

      assert {:ok,
              %{
                entity_id: "asn:13335",
                kind: "ASN",
                outage_state: "confirmed_outage"
              }} =
               ExternalProjection.normalize_status_event(
                 "serviceradar.horizon.outages.asn",
                 asn_payload
               )

      assert_received {:nats_status, "serviceradar.horizon.outages.saas", saas_payload, _}

      assert {:ok,
              %{
                entity_id: "saas:cloud-akamai-us-east",
                kind: "SaasTarget",
                outage_state: "up"
              }} =
               ExternalProjection.normalize_status_event(
                 "serviceradar.horizon.outages.saas",
                 saas_payload
               )

      assert_received {:nats_status, "serviceradar.horizon.bgp.rtbh_blackhole", bgp_payload, _}

      assert {:ok,
              %{
                entity_id: "198.51.100.0/24",
                kind: "Prefix",
                rpki_state: "invalid",
                rtbh_active: true
              }} =
               ExternalProjection.normalize_status_event(
                 "serviceradar.horizon.bgp.rtbh_blackhole",
                 bgp_payload
               )

      assert_received {:nats_status, "serviceradar.horizon.bgp.leak", leak_payload, _}

      assert {:ok,
              %{
                entity_id: "asn:64513",
                kind: "ASN",
                rpki_state: "valid",
                rtbh_active: false
              }} =
               ExternalProjection.normalize_status_event(
                 "serviceradar.horizon.bgp.leak",
                 leak_payload
               )
    end

    test "NATS forwarding failures are fail-open and never block StarRocks loads" do
      parent = self()

      load_fn = fn dataset, rows ->
        send(parent, {:loaded, dataset, length(rows)})
        {:ok, %{loaded: length(rows)}}
      end

      log =
        capture_log(fn ->
          assert :ok ==
                   HorizonProjection.project_rows([outage_row()],
                     starrocks_enabled: true,
                     load: load_fn,
                     publish_nats: fn _subject, _payload, _opts -> {:error, :timeout} end
                   )

          assert :ok ==
                   HorizonProjection.project_rows([outage_row()],
                     starrocks_enabled: true,
                     load: load_fn,
                     publish_nats: fn _subject, _payload, _opts -> raise "nats crashed" end
                   )
        end)

      assert log =~ "Horizon NATS status publish failed"
      assert log =~ "Horizon NATS status publish raised"
      assert_received {:loaded, :horizon_outages, 1}
      assert_received {:loaded, :horizon_outages, 1}
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
      configure_starrocks_fe!(StreamLoadFE.start!())

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
                 "time" => "2026-11-23T16:15:00Z",
                 "round_id" => "round-42",
                 "target_id" => "saas-github-web",
                 "pop_id" => "vantage-deadbeef",
                 "hop_ttl" => 5,
                 "hop_ip" => "198.51.100.5",
                 "router_alias_id" => "rtr-iad-01",
                 "alias_confidence" => 0.95,
                 "asn" => 13_335,
                 "as_org" => "Cloudflare, Inc.",
                 "is_cloud" => true,
                 "cloud_provider" => "cloudflare",
                 "cloud_region" => "us-east",
                 "forwarding_loss_pct" => 12.5,
                 "avg_rtt_ms" => 8.4,
                 "effective_path_mtu" => 1500,
                 "mtu_blackhole_detected" => true,
                 "blackhole_hop_ttl" => 6,
                 "raw_data" => %{"round_id" => "round-42"}
               } = wire_hop
             ] = hop_rows

      assert wire_hop |> Map.keys() |> Enum.sort() == path_hops_ddl_columns()
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
      configure_starrocks_fe!(start_partial_fail_fe!("horizon_outages"))

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
          assert {:ok, 3} =
                   Events.store_event_rows([
                     outage_row("out-fail-http"),
                     watchlist_row,
                     path_hop_row()
                   ])
        end)

      assert log =~ "Horizon StarRocks projection failed for horizon_outages (fail-open)"
      assert_receive {:wire_table, "events", event_rows}, 5_000
      assert_receive {:wire_table, "horizon_outages", _failed_outage_rows}, 5_000
      assert_receive {:wire_table, "horizon_bgp_events", bgp_rows}, 5_000
      assert_receive {:wire_table, "horizon_path_hops", hop_rows}, 5_000

      assert length(event_rows) == 3

      assert [
               %{
                 "event_id" => "bgp-wl-failopen",
                 "kind" => "watchlist",
                 "prefix" => "203.0.113.0/24",
                 "origin_asn" => 64_509,
                 "client_label" => "Synthetic Prefix"
               }
             ] = bgp_rows

      assert [
               %{
                 "round_id" => "round-42",
                 "target_id" => "saas-github-web",
                 "pop_id" => "vantage-deadbeef",
                 "hop_ttl" => 5
               } = wire_hop
             ] = hop_rows

      assert wire_hop |> Map.keys() |> Enum.sort() == path_hops_ddl_columns()
    end

    test "Pipeline and Events fail open over HTTP when horizon_path_hops Stream Load fails" do
      configure_starrocks_fe!(start_partial_fail_fe!("horizon_path_hops"))

      raw_messages =
        Enum.map(
          [
            %{
              "id" => "horizon.outages:out-hop-failopen:1763913600000",
              "time" => "2026-11-23T16:00:00Z",
              "class_uid" => 1008,
              "category_uid" => 1,
              "type_uid" => 100_801,
              "activity_id" => 1,
              "severity_id" => 5,
              "log_name" => "horizon.outage",
              "log_provider" => "horizon.outages",
              "unmapped" => %{
                "outage_id" => "out-hop-failopen",
                "status" => "active",
                "severity" => "major",
                "entity_type" => "asn",
                "entity_key" => "AS64512",
                "affected_asn" => "AS64512",
                "corroborating_pop_count" => 3
              }
            },
            %{
              "id" => "horizon.path_hops:round-99:vantage-failopen:4:1763914500000",
              "time" => "2026-11-23T16:15:00Z",
              "class_uid" => 1008,
              "category_uid" => 1,
              "type_uid" => 100_801,
              "activity_id" => 1,
              "severity_id" => 3,
              "log_name" => "horizon.path_hop",
              "log_provider" => "horizon.path_hops",
              "unmapped" => %{
                "round_id" => "round-99",
                "target_id" => "target-failopen",
                "pop_id" => "vantage-failopen",
                "hop_ttl" => 4,
                "hop_ip" => "198.51.100.44",
                "asn" => 64_512,
                "is_cloud" => false,
                "forwarding_loss_pct" => 2.5,
                "avg_rtt_ms" => 11.4,
                "mtu_blackhole_detected" => false
              }
            }
          ],
          fn payload ->
            %Message{
              data: Jason.encode!(payload),
              metadata: %{subject: "events.ocsf.processed"},
              acknowledger: {Pipeline, :ack_ref, %{}}
            }
          end
        )

      routed = Enum.map(raw_messages, &Pipeline.handle_message(:default, &1, %{}))
      assert Enum.all?(routed, &(&1.batcher == :events))
      assert Pipeline.processor_for_batcher(:events) == Events

      rows = Events.build_rows(routed)
      assert length(rows) == 2

      log =
        capture_log(fn ->
          assert {:ok, 2} = Events.store_event_rows(rows)
        end)

      assert log =~ "Horizon StarRocks projection failed for horizon_path_hops (fail-open)"
      assert_receive {:wire_table, "events", event_rows}, 5_000
      assert_receive {:wire_table, "horizon_outages", outage_rows}, 5_000
      assert_receive {:wire_table, "horizon_path_hops", failed_hop_rows}, 5_000

      assert length(event_rows) == 2
      assert [%{"outage_id" => "out-hop-failopen", "origin_asn" => 64_512}] = outage_rows

      assert [
               %{
                 "round_id" => "round-99",
                 "target_id" => "target-failopen",
                 "pop_id" => "vantage-failopen",
                 "hop_ttl" => 4,
                 "hop_ip" => "198.51.100.44",
                 "asn" => 64_512,
                 "is_cloud" => false,
                 "mtu_blackhole_detected" => false
               } = wire_hop
             ] = failed_hop_rows

      assert wire_hop |> Map.keys() |> Enum.sort() == path_hops_ddl_columns()
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

  describe "JetStream EventWriter -> Mint HTTP Stream Load live-broker flow" do
    @tag :tmp_dir
    test "ingests horizon.path_hop via JetStream, Producer, Pipeline, Mint HTTP, PubSub, and SRQL NIF",
         %{tmp_dir: tmp_dir} do
      ensure_pubsub!()
      :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, EventsPubSub.topic())
      :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, EventsPubSub.rows_topic())

      configure_starrocks_fe!(start_recording_fe!())

      ExposureBroker.with_broker(tmp_dir, fn conn, port ->
        config = jetstream_events_config(port, :horizon_live_producer)
        [stream] = config.streams
        assert :ok = ConsumerReconciler.ensure_stream(conn, config, stream)

        payloads = live_jetstream_payloads()
        expected_count = length(payloads)

        run_jetstream_consumer(config, expected_count, fn ->
          publish_jetstream_events!(conn, payloads)

          assert_receive {:jetstream_batch, batch}, 20_000
          assert batch.processor == Events
          assert Enum.all?(batch.batchers, &(&1 == :events))
          assert batch.row_count == expected_count
          assert batch.store_result == {:ok, expected_count}

          loads = collect_wire_loads(5)

          assert loads |> Map.keys() |> Enum.sort() == [
                   "events",
                   "horizon_bgp_events",
                   "horizon_bgp_zombies",
                   "horizon_outages",
                   "horizon_path_hops"
                 ]

          assert length(loads["events"].rows) == expected_count
          assert [%{"outage_id" => "out-js-1"}] = loads["horizon_outages"].rows
          assert [%{"event_id" => "bgp-js-1"}] = loads["horizon_bgp_events"].rows
          assert [%{"episode_id" => "ep-js-1"}] = loads["horizon_bgp_zombies"].rows

          hop_load = loads["horizon_path_hops"]
          assert hop_load.path == "/api/serviceradar/horizon_path_hops/_stream_load"
          assert hop_load.headers["format"] == "json"
          assert hop_load.headers["strip_outer_array"] == "true"
          assert hop_load.headers["expect"] == "100-continue"
          assert hop_load.headers["content-type"] == "application/json"
          assert String.starts_with?(hop_load.headers["label"], "sr-")
          assert length(hop_load.rows) == 5

          ddl_columns = path_hops_ddl_columns()
          not_null_columns = path_hops_not_null_columns()

          for wire_hop <- hop_load.rows do
            assert wire_hop |> Map.keys() |> Enum.sort() == ddl_columns

            for col <- not_null_columns do
              refute is_nil(Map.fetch!(wire_hop, col)),
                     "NOT NULL column #{col} must not encode as nil over wire"
            end
          end

          by_key =
            Map.new(hop_load.rows, &{{&1["round_id"], &1["pop_id"], &1["hop_ttl"]}, &1})

          assert %{
                   "time" => "2026-11-23T16:15:00Z",
                   "target_id" => "tgt-js-web",
                   "hop_ip" => "198.51.100.5",
                   "router_alias_id" => "rtr-edge-01",
                   "alias_confidence" => 0.85,
                   "asn" => 64_512,
                   "as_org" => "Example Transit",
                   "is_cloud" => true,
                   "cloud_provider" => "example_cloud",
                   "cloud_region" => "us-east-1",
                   "forwarding_loss_pct" => 12.5,
                   "avg_rtt_ms" => 9.1,
                   "effective_path_mtu" => 1500,
                   "mtu_blackhole_detected" => true,
                   "blackhole_hop_ttl" => 6
                 } = by_key[{"round-js-42", "pop-alpha", 5}]

          assert %{
                   "hop_ip" => "198.51.100.15",
                   "avg_rtt_ms" => 11.2,
                   "asn" => 64_513
                 } = by_key[{"round-js-42", "pop-beta", 5}]

          assert %{
                   "hop_ip" => nil,
                   "router_alias_id" => nil,
                   "alias_confidence" => nil,
                   "asn" => nil,
                   "as_org" => nil,
                   "is_cloud" => false,
                   "forwarding_loss_pct" => 100.0,
                   "avg_rtt_ms" => 0.0,
                   "effective_path_mtu" => nil,
                   "mtu_blackhole_detected" => false,
                   "blackhole_hop_ttl" => nil
                 } = by_key[{"round-js-42", "pop-alpha", 6}]

          assert %{
                   "time" => "2026-11-23T16:15:00Z",
                   "alias_confidence" => nil,
                   "raw_data" => %{"alias_confidence" => "high"},
                   "asn" => 64_512,
                   "forwarding_loss_pct" => 0.5,
                   "avg_rtt_ms" => 4.0
                 } = by_key[{"round-js-43", "pop-gamma", 2}]

          assert %{"hop_ttl" => 0} = by_key[{"round-js-43", "pop-gamma", 0}]

          # Redelivering the same rows emits the exact deterministic Stream Load label.
          assert :ok = HorizonProjection.project_rows(batch.rows)
          redelivery_loads = collect_wire_loads(4)

          assert redelivery_loads["horizon_path_hops"].headers["label"] ==
                   hop_load.headers["label"]

          # Real Phoenix.PubSub broadcasts for stored OCSF rows.
          assert_receive {:ocsf_event, %{count: ^expected_count}}, 5_000
          assert_receive {:ocsf_event_rows, summaries}, 5_000
          assert Enum.any?(summaries, &(&1["log_name"] == "horizon.path_hop"))

          # JetStream durable consumer settled with zero pending or unacked messages.
          await_jetstream_settled!(conn, config, expected_count)

          # Compiled Rust SRQL NIF compiles in:horizon_paths against the loaded table & columns.
          assert {:ok, translated_json} =
                   Native.translate(
                     "in:horizon_paths target_id:tgt-js-web is_cloud:true sort:hop_ttl:asc limit:20",
                     nil,
                     nil,
                     nil,
                     "starrocks"
                   )

          translated = Jason.decode!(translated_json)
          assert translated["sql"] =~ "FROM serviceradar.horizon_path_hops"
          assert translated["sql"] =~ "`target_id` = 'tgt-js-web'"
          assert translated["sql"] =~ "`is_cloud` = TRUE"

          for col <- ddl_columns do
            assert translated["sql"] =~ "`#{col}`"
          end

          assert {:error, reason} =
                   Native.translate("in:horizon_paths limit:5", nil, nil, nil, nil)

          assert to_string(reason) =~ "StarRocks"
        end)
      end)
    end

    @tag :tmp_dir
    test "fails open on horizon_path_hops HTTP error over JetStream and skips HTTP when disabled",
         %{tmp_dir: tmp_dir} do
      configure_starrocks_fe!(start_recording_fe!(fail_table: "horizon_path_hops"))

      ExposureBroker.with_broker(tmp_dir, fn conn, port ->
        config = jetstream_events_config(port, :horizon_failopen_producer)
        [stream] = config.streams
        assert :ok = ConsumerReconciler.ensure_stream(conn, config, stream)

        payloads = [
          %{
            "id" => "horizon.outages:out-js-failopen:1763913600000",
            "time" => "2026-11-23T16:00:00Z",
            "class_uid" => 1008,
            "category_uid" => 1,
            "type_uid" => 100_801,
            "activity_id" => 1,
            "severity_id" => 5,
            "log_name" => "horizon.outage",
            "log_provider" => "horizon.outages",
            "unmapped" => %{
              "outage_id" => "out-js-failopen",
              "status" => "active",
              "severity" => "major",
              "entity_type" => "asn",
              "entity_key" => "AS64512",
              "affected_asn" => "AS64512",
              "corroborating_pop_count" => 3
            }
          },
          %{
            "id" => "horizon.path_hops:round-js-fail:pop-fail:4:1763914500000",
            "time" => "2026-11-23T16:15:00Z",
            "class_uid" => 1008,
            "category_uid" => 1,
            "type_uid" => 100_801,
            "activity_id" => 1,
            "severity_id" => 3,
            "log_name" => "horizon.path_hop",
            "log_provider" => "horizon.path_hops",
            "unmapped" => %{
              "round_id" => "round-js-fail",
              "target_id" => "tgt-js-failopen",
              "pop_id" => "pop-fail",
              "hop_ttl" => 4,
              "hop_ip" => "198.51.100.44",
              "asn" => 64_512,
              "is_cloud" => false,
              "forwarding_loss_pct" => 2.5,
              "avg_rtt_ms" => 11.4,
              "mtu_blackhole_detected" => false
            }
          }
        ]

        run_jetstream_consumer(config, length(payloads), fn ->
          log =
            capture_log(fn ->
              publish_jetstream_events!(conn, payloads)
              assert_receive {:jetstream_batch, batch}, 20_000
              assert batch.store_result == {:ok, 2}
              send(self(), {:captured_rows, batch.rows})
            end)

          assert log =~ "Horizon StarRocks projection failed for horizon_path_hops (fail-open)"
          loads = collect_wire_loads(3)
          assert length(loads["events"].rows) == 2
          assert [%{"outage_id" => "out-js-failopen"}] = loads["horizon_outages"].rows
          assert [failed_hop] = loads["horizon_path_hops"].rows
          assert failed_hop |> Map.keys() |> Enum.sort() == path_hops_ddl_columns()

          await_jetstream_settled!(conn, config, 2)

          # When StarRocks is disabled, projection short-circuits with zero HTTP requests.
          assert_received {:captured_rows, rows}

          Application.put_env(:serviceradar_core, StarRocks,
            enabled: false,
            fe_http: Destination.client_config().fe_http
          )

          assert Readers.mode_for("horizon_paths") == {:error, :starrocks_required}
          assert :ok = HorizonProjection.project_rows(rows)
          refute_receive {:wire_load, _}, 300
        end)
      end)
    end
  end

  defp ensure_pubsub! do
    if Process.whereis(ServiceRadar.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end
  end

  defp jetstream_events_config(port, producer_name) do
    %Config{
      enabled: true,
      producer_name: producer_name,
      nats: %{
        host: "127.0.0.1",
        port: port,
        tls: false,
        user: nil,
        password: nil,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "horizon-live-writer",
      max_ack_pending: 64,
      consumer_pull_batch_size: 32,
      ack_wait_ns: 30_000_000_000,
      workers: 1,
      retired_consumers: [],
      streams: [
        %{
          name: "EVENTS",
          stream_name: "events",
          subject: "events.>",
          processor: Events,
          stream_replicas: 1,
          stream_max_bytes: 16_777_216
        }
      ]
    }
  end

  defp run_jetstream_consumer(config, expected_count, fun) do
    producer_id = {:producer, config.producer_name}
    sink_id = {:sink, config.producer_name}
    producer = start_supervised!({Producer, config}, id: producer_id)
    start_supervised!({JetStreamEventsSink, {producer, self(), expected_count}}, id: sink_id)
    await_producer_ready!(config.producer_name)

    try do
      fun.()
    after
      stop_supervised!(sink_id)
      stop_supervised!(producer_id)
    end
  end

  defp await_producer_ready!(name, attempts \\ 200) do
    cond do
      Producer.status(name).ready ->
        :ok

      attempts == 0 ->
        flunk("EventWriter producer #{inspect(name)} did not become ready")

      true ->
        Process.sleep(50)
        await_producer_ready!(name, attempts - 1)
    end
  end

  defp publish_jetstream_events!(conn, payloads) do
    Enum.each(payloads, fn payload ->
      {:ok, %{body: body}} =
        Gnat.request(conn, "events.ocsf.processed", Jason.encode!(payload),
          receive_timeout: 5_000
        )

      assert %{"stream" => "events", "seq" => seq} = Jason.decode!(body)
      assert is_integer(seq) and seq > 0
    end)
  end

  defp await_jetstream_settled!(conn, config, expected_seq, attempts \\ 60) do
    durable = Config.durable_name(config.consumer_name, "EVENTS")
    info = ExposureBroker.request(conn, "$JS.API.CONSUMER.INFO.events.#{durable}", %{})

    cond do
      match?(
        %{
          "num_pending" => 0,
          "num_ack_pending" => 0,
          "ack_floor" => %{"stream_seq" => ^expected_seq}
        },
        info
      ) ->
        :ok

      attempts == 0 ->
        flunk("JetStream durable #{durable} did not settle: #{inspect(info)}")

      true ->
        Process.sleep(100)
        await_jetstream_settled!(conn, config, expected_seq, attempts - 1)
    end
  end

  defp collect_wire_loads(count) do
    Enum.reduce(1..count, %{}, fn _, acc ->
      assert_receive {:wire_load, load}, 5_000
      Map.put(acc, load.table, load)
    end)
  end

  defp live_jetstream_payloads do
    base_hop = fn id, unmapped ->
      %{
        "id" => id,
        "time" => "2026-11-23T16:15:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "severity_id" => 3,
        "log_name" => "horizon.path_hop",
        "log_provider" => "horizon.path_hops",
        "unmapped" => unmapped
      }
    end

    [
      # Duplicate PK pair with ordered UUIDs: second wins (avg_rtt_ms: 9.1, alias_confidence: 0.85)
      base_hop.("00000000-0000-0000-0000-000000000001", %{
        "source" => "horizon.path_hops",
        "round_id" => "round-js-42",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha",
        "hop_ttl" => 5,
        "hop_ip" => "198.51.100.5",
        "router_alias_id" => "rtr-edge-01",
        "alias_confidence" => 0.75,
        "asn" => 64_512,
        "as_org" => "Example Transit",
        "is_cloud" => true,
        "cloud_provider" => "example_cloud",
        "cloud_region" => "us-east-1",
        "forwarding_loss_pct" => 12.5,
        "avg_rtt_ms" => 8.4,
        "effective_path_mtu" => 1500,
        "mtu_blackhole_detected" => true,
        "blackhole_hop_ttl" => 6
      }),
      base_hop.("00000000-0000-0000-0000-000000000002", %{
        "source" => "horizon.path_hops",
        "round_id" => "round-js-42",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha",
        "hop_ttl" => 5,
        "hop_ip" => "198.51.100.5",
        "router_alias_id" => "rtr-edge-01",
        "alias_confidence" => "0.85",
        "asn" => 64_512,
        "as_org" => "Example Transit",
        "is_cloud" => true,
        "cloud_provider" => "example_cloud",
        "cloud_region" => "us-east-1",
        "forwarding_loss_pct" => 12.5,
        "avg_rtt_ms" => 9.1,
        "effective_path_mtu" => 1500,
        "mtu_blackhole_detected" => true,
        "blackhole_hop_ttl" => 6
      }),
      # Multipath distinct pop_id at same (time, round_id, target_id, hop_ttl)
      base_hop.("00000000-0000-0000-0000-000000000003", %{
        "round_id" => "round-js-42",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-beta",
        "hop_ttl" => 5,
        "hop_ip" => "198.51.100.15",
        "asn" => 64_513,
        "is_cloud" => false,
        "avg_rtt_ms" => 11.2,
        "mtu_blackhole_detected" => false
      }),
      # Timeout hop with nullable columns omitted
      base_hop.("00000000-0000-0000-0000-000000000004", %{
        "round_id" => "round-js-42",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha",
        "hop_ttl" => 6,
        "is_cloud" => false,
        "forwarding_loss_pct" => 100,
        "avg_rtt_ms" => 0,
        "mtu_blackhole_detected" => false
      }),
      # Coerced string fields, non-numeric alias_confidence -> nil, OCSF time over unix_ms
      base_hop.("00000000-0000-0000-0000-000000000005", %{
        "observed_at_unix_ms" => 1_700_000_000_000,
        "round_id" => "round-js-43",
        "target_id" => "tgt-js-dns",
        "pop_id" => "pop-gamma",
        "hop_ttl" => "2",
        "hop_ip" => "203.0.113.2",
        "alias_confidence" => "high",
        "asn" => "AS64512",
        "forwarding_loss_pct" => "0.5",
        "avg_rtt_ms" => "4"
      }),
      # Boundary hop_ttl = 0
      base_hop.("00000000-0000-0000-0000-000000000006", %{
        "round_id" => "round-js-43",
        "target_id" => "tgt-js-dns",
        "pop_id" => "pop-gamma",
        "hop_ttl" => 0
      }),
      # Adversarial: log_provider-only (no log_name)
      %{
        "id" => "00000000-0000-0000-0000-000000000007",
        "time" => "2026-11-23T16:15:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "log_provider" => "horizon.path_hops",
        "unmapped" => %{
          "round_id" => "round-js-bad",
          "target_id" => "tgt-js-web",
          "pop_id" => "pop-alpha",
          "hop_ttl" => 1
        }
      },
      # Adversarial: control event, plural log_name, negative TTL, missing TTL, blank PKs
      Map.put(
        base_hop.("00000000-0000-0000-0000-000000000008", %{
          "round_id" => "round-js-ctrl",
          "target_id" => "tgt-js-web",
          "pop_id" => "pop-alpha",
          "hop_ttl" => 1
        }),
        "log_name",
        "horizon.path_hop.snapshot_complete"
      ),
      Map.put(
        base_hop.("00000000-0000-0000-0000-000000000009", %{
          "round_id" => "round-js-plural",
          "target_id" => "tgt-js-web",
          "pop_id" => "pop-alpha",
          "hop_ttl" => 1
        }),
        "log_name",
        "horizon.path_hops"
      ),
      base_hop.("00000000-0000-0000-0000-000000000010", %{
        "round_id" => "round-js-neg",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha",
        "hop_ttl" => -1
      }),
      base_hop.("00000000-0000-0000-0000-000000000011", %{
        "round_id" => "round-js-nottl",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha"
      }),
      base_hop.("00000000-0000-0000-0000-000000000012", %{
        "round_id" => "   ",
        "target_id" => "tgt-js-web",
        "pop_id" => "pop-alpha",
        "hop_ttl" => 1
      }),
      base_hop.("00000000-0000-0000-0000-000000000013", %{
        "round_id" => "round-js-notgt",
        "target_id" => "",
        "pop_id" => "pop-alpha",
        "hop_ttl" => 1
      }),
      base_hop.("00000000-0000-0000-0000-000000000014", %{
        "round_id" => "round-js-nopop",
        "target_id" => "tgt-js-web",
        "pop_id" => nil,
        "hop_ttl" => 1
      }),
      # Sibling Horizon tables in the same JetStream batch
      %{
        "id" => "00000000-0000-0000-0000-000000000015",
        "time" => "2026-11-23T16:00:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "log_name" => "horizon.outage",
        "log_provider" => "horizon.outages",
        "unmapped" => %{
          "outage_id" => "out-js-1",
          "status" => "active",
          "severity" => "major",
          "entity_type" => "asn",
          "entity_key" => "AS64512",
          "affected_asn" => "AS64512",
          "corroborating_pop_count" => 4
        }
      },
      %{
        "id" => "00000000-0000-0000-0000-000000000016",
        "time" => "2026-11-23T16:05:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "log_name" => "horizon.bgp_anomaly",
        "log_provider" => "horizon.bgp_anomalies",
        "unmapped" => %{
          "event_id" => "bgp-js-1",
          "kind" => "hijack",
          "level" => "critical",
          "covering_prefix" => "198.51.100.0/24",
          "origin_asn" => 64_512
        }
      },
      %{
        "id" => "00000000-0000-0000-0000-000000000017",
        "time" => "2026-11-23T16:10:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "log_name" => "horizon.bgp_zombie",
        "log_provider" => "horizon.bgp_zombies",
        "unmapped" => %{
          "episode_id" => "ep-js-1",
          "status" => "active",
          "covering_prefix" => "203.0.113.0/24",
          "origin_asn" => 64_513
        }
      }
    ]
  end

  defp start_partial_fail_fe!(fail_table) do
    start_recording_fe!(fail_table: fail_table, notify: :wire_table)
  end

  defp start_recording_fe!(opts \\ []) do
    fail_table = Keyword.get(opts, :fail_table)
    notify = Keyword.get(opts, :notify, :wire_load)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_recording_fe(listener, parent, fail_table, notify) end})
    "http://127.0.0.1:#{port}"
  end

  defp serve_recording_fe(listener, parent, fail_table, notify) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {:ok, {:http_request, :PUT, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = recv_http_headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        [_, table] = Regex.run(~r|^/api/[^/]+/([^/]+)/_stream_load$|, path)

        case notify do
          :wire_table ->
            send(parent, {:wire_table, table, rows})

          :wire_load ->
            send(parent, {:wire_load, %{table: table, path: path, headers: headers, rows: rows}})
        end

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
        serve_recording_fe(listener, parent, fail_table, notify)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_recording_fe(listener, parent, fail_table, notify)
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

  defp configure_starrocks_fe!(fe_http) do
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

    Application.put_env(:serviceradar_core, StarRocks,
      enabled: true,
      cutover_datasets: [:events],
      fe_http: fe_http
    )
  end

  defp path_hops_ddl_columns do
    scan_ddl_columns(~r/^\s+`?(\w+)`? [A-Z]/m)
  end

  defp path_hops_not_null_columns do
    scan_ddl_columns(~r/^\s+`?(\w+)`? [A-Z][^\n]*\bNOT NULL\b/m)
  end

  defp scan_ddl_columns(pattern) do
    prefix = "CREATE TABLE IF NOT EXISTS serviceradar.horizon_path_hops ("

    create =
      Schema.migrations()
      |> Enum.flat_map(& &1.statements)
      |> Enum.find(&String.starts_with?(&1, prefix))

    pattern
    |> Regex.scan(create)
    |> Enum.map(&List.last/1)
    |> Enum.sort()
  end
end
