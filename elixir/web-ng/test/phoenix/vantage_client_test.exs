defmodule ServiceRadarWebNG.Vantage.ClientTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Vantage.Client
  alias ServiceRadarWebNGWeb.CameraSemanticSearch

  @moduletag :db_free

  @camera_a "00000000-0000-4000-8000-000000000901"
  @camera_b "00000000-0000-4000-8000-000000000902"
  @frame_id "00000000-0000-4000-8000-000000000903"
  @entry_id "00000000-0000-4000-8000-000000000904"

  setup do
    prev_enabled = Application.get_env(:serviceradar_web_ng, :vantage_rpc_enabled)
    prev_request_fn = Application.get_env(:serviceradar_web_ng, :vantage_rpc_request_fn)
    Client.clear_capabilities_cache()

    on_exit(fn ->
      Client.clear_capabilities_cache()
      restore_env(:vantage_rpc_enabled, prev_enabled)
      restore_env(:vantage_rpc_request_fn, prev_request_fn)
    end)

    :ok
  end

  describe "enabled?/0" do
    test "defaults to false and reflects :vantage_rpc_enabled app env" do
      Application.delete_env(:serviceradar_web_ng, :vantage_rpc_enabled)
      refute Client.enabled?()

      Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, true)
      assert Client.enabled?()
    end
  end

  describe "capabilities/1" do
    test "caches responses in ETS for 30s and refreshes after TTL expires" do
      counter = :counters.new(1, [])

      request_fn = fn "vantage.rpc.capabilities.v1", "{}", _opts ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "version" => "1.0.#{count}",
               "capabilities" => %{"semantic_search" => true, "frame_overlay" => true}
             })
         }}
      end

      first = Client.capabilities(request_fn: request_fn, now_ms: 1_000)
      assert first.available == true
      assert first.version == "1.0.1"
      assert first.capabilities == %{"semantic_search" => true, "frame_overlay" => true}

      # Within 30s TTL: returns cached value without invoking request_fn again.
      second = Client.capabilities(request_fn: request_fn, now_ms: 29_999)
      assert second == first
      assert :counters.get(counter, 1) == 1

      # At or past 30s TTL: re-fetches from Vantage.
      third = Client.capabilities(request_fn: request_fn, now_ms: 31_000)
      assert third.available == true
      assert third.version == "1.0.2"
      assert :counters.get(counter, 1) == 2
    end

    test "fails closed to %{available: false} on timeout, no-responders, and malformed JSON" do
      assert %{available: false} =
               Client.capabilities(
                 bypass_cache: true,
                 request_fn: fn _, _, _ -> {:error, :timeout} end
               )

      assert %{available: false} =
               Client.capabilities(
                 bypass_cache: true,
                 request_fn: fn _, _, _ -> {:error, :no_responders} end
               )

      assert %{available: false} =
               Client.capabilities(
                 bypass_cache: true,
                 request_fn: fn _, _, _ -> {:ok, %{headers: [{"status", "503"}], body: ""}} end
               )

      assert %{available: false} =
               Client.capabilities(
                 bypass_cache: true,
                 request_fn: fn _, _, _ -> {:ok, %{body: "not-json"}} end
               )
    end
  end

  describe "semantic_search/2" do
    test "forwards authorized_camera_source_ids, camera_sources, and maps ok response" do
      test_pid = self()

      request_fn = fn subject, json_body, opts ->
        send(test_pid, {:rpc_call, subject, Jason.decode!(json_body), opts})

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "time_basis" => "received",
               "time_uncertainty" => "unmeasured",
               "results" => [
                 %{
                   "catalog_entry_id" => @entry_id,
                   "visual_frame_id" => @frame_id,
                   "camera_source_id" => @camera_a,
                   "camera_display_name" => "Synthetic Entry",
                   "clip_start_us" => 1_700_000_010_000_000,
                   "clip_end_us" => 1_700_000_016_000_000,
                   "best_timeline_ts_us" => 1_700_000_012_000_000,
                   "score" => 0.85,
                   "object_class" => "person",
                   "dominant_colors" => ["red"]
                 }
               ],
               "audit_meta" => %{
                 "model_id" => "siglip-b16-384",
                 "model_version" => "v1",
                 "query_sha256" => "abcdef1234"
               }
             })
         }}
      end

      assert {:ok, result} =
               Client.semantic_search(
                 %{
                   q: "person in red jacket",
                   query: "person in red jacket",
                   authorized_camera_source_ids: [@camera_a],
                   camera_sources: %{
                     @camera_a => %{display_name: "Synthetic Entry", device_uid: "sr:cam-a"}
                   },
                   limit: 10,
                   object_class: "person"
                 },
                 request_fn: request_fn,
                 timeout_ms: 3_500
               )

      assert_received {:rpc_call, "vantage.rpc.semantic_search.v1", payload, [receive_timeout: 3_500]}

      assert payload["authorized_camera_source_ids"] == [@camera_a]

      assert payload["camera_sources"] == %{
               @camera_a => %{"display_name" => "Synthetic Entry", "device_uid" => "sr:cam-a"}
             }

      assert payload["q"] == "person in red jacket"
      assert payload["object_class"] == "person"
      assert payload["limit"] == 10

      assert result.time_basis == "received"
      assert length(result.results) == 1
      assert result.audit_meta["model_id"] == "siglip-b16-384"
    end

    test "maps error responses and transport failures to expected error atoms" do
      assert {:error, :search_embedder_unavailable} =
               Client.semantic_search(%{q: "van"},
                 request_fn: fn _, _, _ ->
                   {:ok,
                    %{
                      body:
                        Jason.encode!(%{
                          "status" => "error",
                          "error" => "search_embedder_unavailable"
                        })
                    }}
                 end
               )

      assert {:error, :forbidden} =
               Client.semantic_search(%{q: "van"},
                 request_fn: fn _, _, _ ->
                   {:ok, %{body: Jason.encode!(%{"status" => "error", "error" => "forbidden"})}}
                 end
               )

      assert {:error, :semantic_search_unavailable} =
               Client.semantic_search(%{q: "van"},
                 request_fn: fn _, _, _ ->
                   {:ok,
                    %{
                      body:
                        Jason.encode!(%{
                          "status" => "error",
                          "error" => "unrecognized_vendor_code"
                        })
                    }}
                 end
               )

      assert {:error, :vantage_unavailable} =
               Client.semantic_search(%{q: "van"},
                 request_fn: fn _, _, _ -> {:error, :timeout} end
               )
    end
  end

  describe "frame_overlay/2 and frame_overlay/3" do
    test "fetches and normalizes overlay detections" do
      test_pid = self()

      request_fn = fn subject, json_body, _opts ->
        send(test_pid, {:overlay_rpc, subject, Jason.decode!(json_body)})

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "detections" => [
                 %{
                   "visual_frame_id" => @frame_id,
                   "timeline_ts_us" => 1_700_000_012_000_000,
                   "start_us" => 1_700_000_010_500_000,
                   "end_us" => 1_700_000_013_500_000,
                   "bbox" => [0.1, 0.2, 0.4, 0.8],
                   "object_class" => "person",
                   "score" => 0.91,
                   "dominant_colors" => ["red"],
                   "time_basis" => "received"
                 }
               ]
             })
         }}
      end

      assert {:ok, [det]} =
               Client.frame_overlay(%{camera_source_id: @camera_a, visual_frame_id: @frame_id},
                 request_fn: request_fn
               )

      assert_received {:overlay_rpc, "vantage.rpc.frame_overlay.v1",
                       %{"camera_source_id" => @camera_a, "visual_frame_id" => @frame_id}}

      assert det.visual_frame_id == @frame_id
      assert det.bbox == [0.1, 0.2, 0.4, 0.8]
      assert det.object_class == "person"
      assert det.score == 0.91
    end
  end

  describe "CameraSemanticSearch Vantage RPC integration" do
    test "enforces RBAC & camera scope, forwards to Vantage RPC, and records audit_meta" do
      scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])
      test_pid = self()

      request_fn = fn "vantage.rpc.semantic_search.v1", json_body, _opts ->
        send(test_pid, {:vantage_payload, Jason.decode!(json_body)})

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "time_basis" => "received",
               "time_uncertainty" => "unmeasured",
               "results" => [
                 %{
                   "catalog_entry_id" => @entry_id,
                   "visual_frame_id" => @frame_id,
                   "camera_source_id" => @camera_a,
                   "camera_display_name" => "Synthetic Gate A",
                   "device_uid" => "sr:synthetic-a",
                   "clip_start_us" => 1_700_000_010_000_000,
                   "clip_end_us" => 1_700_000_016_000_000,
                   "best_timeline_ts_us" => 1_700_000_012_000_000,
                   "score" => 0.88,
                   "object_class" => "vehicle",
                   "dominant_colors" => ["white"]
                 }
               ],
               "audit_meta" => %{
                 "model_id" => "siglip-b16-384",
                 "model_version" => "v1",
                 "query_sha256" => "deadbeef"
               }
             })
         }}
      end

      assert {:ok, formatted} =
               CameraSemanticSearch.execute(
                 scope,
                 %{"q" => "white van", "from" => "1700000000000000", "to" => "1700003600000000"},
                 vantage_rpc_enabled: true,
                 authorize_fn: fn s -> {:ok, s} end,
                 source_reader: fn _scope ->
                   {:ok,
                    [
                      %{
                        id: @camera_a,
                        display_name: "Synthetic Gate A",
                        device_uid: "sr:synthetic-a"
                      }
                    ]}
                 end,
                 vantage_opts: [request_fn: request_fn],
                 audit_writer: fn attrs ->
                   send(test_pid, {:audit_recorded, attrs})
                   {:ok, attrs}
                 end
               )

      assert_received {:vantage_payload, payload}
      assert payload["authorized_camera_source_ids"] == [@camera_a]

      assert payload["camera_sources"] == %{
               @camera_a => %{
                 "display_name" => "Synthetic Gate A",
                 "device_uid" => "sr:synthetic-a"
               }
             }

      assert_received {:audit_recorded, audit_attrs}
      assert audit_attrs.event_kind == :semantic_search
      assert audit_attrs.actor_id == scope.user.id
      assert audit_attrs.window_start_us == 1_700_000_000_000_000
      assert audit_attrs.window_end_us == 1_700_003_600_000_000
      assert audit_attrs.details["model_id"] == "siglip-b16-384"
      assert audit_attrs.details["query_sha256"] == "deadbeef"
      assert audit_attrs.details["result_count"] == 1
      assert audit_attrs.details["provider"] == "vantage_rpc"

      assert formatted.query == "white van"
      assert [hit] = formatted.results
      assert hit.camera_source_id == @camera_a
      assert hit.timeline_path =~ "/cameras/#{@camera_a}/recordings?mode=timeline"
    end

    test "rejects unauthorized camera_source_id before calling Vantage RPC" do
      scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])
      test_pid = self()

      request_fn = fn _subject, _body, _opts ->
        send(test_pid, :unexpected_vantage_rpc)
        {:ok, %{body: Jason.encode!(%{"status" => "ok", "results" => []})}}
      end

      assert {:error, :forbidden} =
               CameraSemanticSearch.execute(
                 scope,
                 %{"q" => "white van", "camera_source_id" => @camera_b},
                 vantage_rpc_enabled: true,
                 authorize_fn: fn s -> {:ok, s} end,
                 source_reader: fn _scope ->
                   {:ok,
                    [
                      %{
                        id: @camera_a,
                        display_name: "Synthetic Gate A",
                        device_uid: "sr:synthetic-a"
                      }
                    ]}
                 end,
                 vantage_opts: [request_fn: request_fn]
               )

      refute_received :unexpected_vantage_rpc
    end

    test "get_frame_overlay/4 enforces RBAC and camera scope before calling Vantage RPC" do
      scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])
      test_pid = self()

      request_fn = fn "vantage.rpc.frame_overlay.v1", _body, _opts ->
        send(test_pid, :overlay_rpc_called)

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "detections" => [%{"visual_frame_id" => @frame_id, "bbox" => [0.1, 0.2, 0.3, 0.4]}]
             })
         }}
      end

      # Unauthorized camera is rejected without invoking RPC
      assert {:error, :forbidden} =
               CameraSemanticSearch.get_frame_overlay(scope, @camera_b, @frame_id,
                 vantage_rpc_enabled: true,
                 authorize_fn: fn s -> {:ok, s} end,
                 source_reader: fn _scope ->
                   {:ok,
                    [
                      %{
                        id: @camera_a,
                        display_name: "Synthetic Gate A",
                        device_uid: "sr:synthetic-a"
                      }
                    ]}
                 end,
                 vantage_opts: [request_fn: request_fn]
               )

      refute_received :overlay_rpc_called

      # Authorized camera calls Vantage RPC and returns detections
      assert {:ok, [det]} =
               CameraSemanticSearch.get_frame_overlay(scope, @camera_a, @frame_id,
                 vantage_rpc_enabled: true,
                 authorize_fn: fn s -> {:ok, s} end,
                 source_reader: fn _scope ->
                   {:ok,
                    [
                      %{
                        id: @camera_a,
                        display_name: "Synthetic Gate A",
                        device_uid: "sr:synthetic-a"
                      }
                    ]}
                 end,
                 vantage_opts: [request_fn: request_fn]
               )

      assert_received :overlay_rpc_called
      assert det.visual_frame_id == @frame_id
    end
  end

  defp synthetic_scope(perms) do
    %Scope{
      user: %{
        id: "00000000-0000-4000-8000-000000000999",
        email: "vantage-client-test@example.test",
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(perms)
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, val), do: Application.put_env(:serviceradar_web_ng, key, val)
end
