defmodule ServiceRadarWebNGWeb.CameraSemanticSearchUnitTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNGWeb.Api.CameraSemanticSearchController
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
  alias ServiceRadarWebNGWeb.CameraSemanticSearch
  alias ServiceRadarWebNGWeb.Settings.RecordingLive.HealthComponents
  alias ServiceRadarWebNGWeb.Settings.RecordingLive.PolicyComponents

  @moduletag :db_free

  @camera_id "00000000-0000-4000-8000-000000000701"
  @profile_id "00000000-0000-4000-8000-000000000702"
  @frame_id "00000000-0000-4000-8000-000000000703"
  @entry_id "00000000-0000-4000-8000-000000000704"

  setup do
    previous_opts = Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts)

    on_exit(fn ->
      if is_nil(previous_opts) do
        Application.delete_env(:serviceradar_web_ng, :camera_semantic_search_opts)
      else
        Application.put_env(:serviceradar_web_ng, :camera_semantic_search_opts, previous_opts)
      end
    end)

    :ok
  end

  describe "CameraSemanticSearch validation and RBAC" do
    test "can_search?/1 requires both devices.view and devices.cameras.recordings.view" do
      full_scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])
      live_only_scope = synthetic_scope(["devices.view", "devices.cameras.view"])

      assert CameraSemanticSearch.can_search?(full_scope)
      refute CameraSemanticSearch.can_search?(live_only_scope)
      refute CameraSemanticSearch.can_search?(nil)
    end

    test "validate_params/1 enforces query length, limit, object_class, color, and time window bounds" do
      assert {:ok, valid} =
               CameraSemanticSearch.validate_params(%{
                 "q" => "  person in red dress  ",
                 "camera_source_id" => @camera_id,
                 "from" => "1700000000000000",
                 "to" => "1700003600000000",
                 "object_class" => "person",
                 "color" => "red",
                 "limit" => "15"
               })

      assert valid.q == "person in red dress"
      assert valid.camera_source_id == @camera_id
      assert valid.from_us == 1_700_000_000_000_000
      assert valid.to_us == 1_700_003_600_000_000
      assert valid.object_class == "person"
      assert valid.color == "red"
      assert valid.limit == 15

      assert {:error, :invalid_query} = CameraSemanticSearch.validate_params(%{"q" => "   "})

      assert {:error, :invalid_query} =
               CameraSemanticSearch.validate_params(%{"q" => String.duplicate("a", 257)})

      assert {:error, :invalid_limit} =
               CameraSemanticSearch.validate_params(%{"q" => "van", "limit" => "51"})

      assert {:error, :invalid_object_class} =
               CameraSemanticSearch.validate_params(%{"q" => "van", "object_class" => "spaceship"})

      assert {:error, :invalid_color} =
               CameraSemanticSearch.validate_params(%{"q" => "van", "color" => "red;drop"})

      assert {:error, :invalid_time_window} =
               CameraSemanticSearch.validate_params(%{
                 "q" => "van",
                 "from" => "2000",
                 "to" => "1000"
               })
    end

    test "format_response/2 normalizes hits and builds timeline deep-link paths" do
      formatted =
        CameraSemanticSearch.format_response("person in red dress", [
          %{
            catalog_entry_id: @entry_id,
            visual_frame_id: @frame_id,
            camera_source_id: @camera_id,
            camera_display_name: "Synthetic Gate Camera",
            clip_start_us: 1_700_000_010_000_000,
            clip_end_us: 1_700_000_016_000_000,
            best_timeline_ts_us: 1_700_000_012_000_000,
            time_basis: :received,
            time_uncertainty: :unmeasured,
            score: 0.87321,
            region_kind: :crop,
            object_class: "person",
            dominant_colors: ["red"],
            bbox: [0.1, 0.2, 0.4, 0.8],
            caption_text: "A person in a red dress walks past the gate.",
            action_tags: ["walking"],
            match_sources: ["visual_vector", "caption_fts"]
          }
        ])

      assert formatted.query == "person in red dress"
      assert formatted.time_basis == "received"
      assert formatted.time_uncertainty == "unmeasured"
      assert [hit] = formatted.results
      assert hit.score == 0.8732
      assert hit.caption_text == "A person in a red dress walks past the gate."
      assert hit.action_tags == ["walking"]
      assert hit.match_sources == ["visual_vector", "caption_fts"]

      assert hit.timeline_path ==
               "/cameras/#{@camera_id}/recordings?mode=timeline&from=1700000010000000&to=1700000016000000&seek=1700000012000000&highlight_frame=#{@frame_id}"

      assert hit.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/frame/#{@frame_id}.jpg"
    end

    test "format_response/2 preserves Vantage observation fields and authenticated crop_url" do
      obs_id = "00000000-0000-7000-8000-000000000799"

      formatted =
        CameraSemanticSearch.format_response("SR-0100", [
          %{
            catalog_entry_id: @entry_id,
            vantage_observation_id: obs_id,
            camera_source_id: @camera_id,
            camera_display_name: "Gate West 01",
            clip_start_us: 1_700_000_010_000_000,
            clip_end_us: 1_700_000_016_000_000,
            best_timeline_ts_us: 1_700_000_012_000_000,
            time_basis: :received,
            time_uncertainty: :unmeasured,
            score: 0.91,
            region_kind: "vantage_observation",
            object_class: "license_plate",
            observation_category: "license_plate",
            observation_label: "SR-0100",
            signal_schema_id: "alpr_plate_read",
            display_contract_id: "alpr_plate_read",
            attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
            has_crop: true,
            bbox: [0.32, 0.58, 0.48, 0.66],
            match_sources: ["observation_fts"]
          }
        ])

      assert [hit] = formatted.results
      assert hit.vantage_observation_id == obs_id
      assert hit.observation_category == "license_plate"
      assert hit.observation_label == "SR-0100"
      assert hit.signal_schema_id == "alpr_plate_read"
      assert hit.display_contract_id == "alpr_plate_read"
      assert hit.attributes == %{"plate_text" => "SR-0100", "region" => "US-CO"}
      assert hit.has_crop == true
      assert hit.crop_url == "/api/cameras/#{@camera_id}/timeline/thumbnails/vantage/#{obs_id}.jpg"
      assert hit.thumbnail_url == hit.crop_url
    end

    test "normalize_hit/1 resolves frame, block fallback, legacy fallback, and nil thumbnail_url" do
      base = %{
        catalog_entry_id: @entry_id,
        visual_frame_id: @frame_id,
        camera_source_id: @camera_id,
        best_timeline_ts_us: 1_700_000_012_000_000
      }

      frame_hit =
        CameraSemanticSearch.normalize_hit(Map.merge(base, %{has_frame_thumbnail: true, has_block_thumbnail: true}))

      assert frame_hit.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/frame/#{@frame_id}.jpg"

      block_fallback_hit =
        CameraSemanticSearch.normalize_hit(Map.merge(base, %{has_frame_thumbnail: false, has_block_thumbnail: true}))

      assert block_fallback_hit.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/block/#{@entry_id}.jpg"

      none_hit =
        CameraSemanticSearch.normalize_hit(Map.merge(base, %{has_frame_thumbnail: false, has_block_thumbnail: false}))

      assert is_nil(none_hit.thumbnail_url)

      legacy_block_only =
        CameraSemanticSearch.normalize_hit(Map.put(base, :visual_frame_id, nil))

      assert legacy_block_only.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/block/#{@entry_id}.jpg"
    end
  end

  describe "CameraSemanticSearchController (:db_free)" do
    test "returns 200 JSON with timeline_path and private, no-store cache header" do
      scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])

      Application.put_env(:serviceradar_web_ng, :camera_semantic_search_opts,
        authorize_fn: fn _ -> {:ok, scope} end,
        search_fn: fn params, _opts ->
          assert params.query == "white van"

          {:ok,
           [
             %{
               catalog_entry_id: @entry_id,
               visual_frame_id: @frame_id,
               camera_source_id: @camera_id,
               camera_display_name: "Synthetic Loading Bay",
               clip_start_us: 1_700_000_100_000_000,
               clip_end_us: 1_700_000_108_000_000,
               best_timeline_ts_us: 1_700_000_104_000_000,
               time_basis: "received",
               score: 0.91,
               object_class: "vehicle",
               dominant_colors: ["white"],
               bbox: [0.2, 0.3, 0.7, 0.85]
             }
           ]}
        end
      )

      conn =
        :get
        |> conn("/api/cameras/search?q=white+van")
        |> assign(:current_scope, scope)
        |> CameraSemanticSearchController.index(%{"q" => "white van"})

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      body = Jason.decode!(conn.resp_body)
      assert body["data"]["query"] == "white van"
      assert body["data"]["time_basis"] == "received"
      assert [result] = body["data"]["results"]
      assert result["timeline_path"] =~ "/cameras/#{@camera_id}/recordings?mode=timeline"
      assert result["timeline_path"] =~ "seek=1700000104000000"
      assert result["timeline_path"] =~ "highlight_frame=#{@frame_id}"
    end

    test "returns 503 search_embedder_unavailable with Retry-After: 5 when workers time out" do
      scope = synthetic_scope(["devices.view", "devices.cameras.recordings.view"])

      Application.put_env(:serviceradar_web_ng, :camera_semantic_search_opts,
        authorize_fn: fn _ -> {:ok, scope} end,
        search_fn: fn _params, _opts -> {:error, :embedder_timeout} end
      )

      conn =
        :get
        |> conn("/api/cameras/search?q=person")
        |> assign(:current_scope, scope)
        |> CameraSemanticSearchController.index(%{"q" => "person"})

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert Jason.decode!(conn.resp_body) == %{"error" => "search_embedder_unavailable"}
    end

    test "returns 403 before invoking search_fn when caller lacks recordings.view" do
      scope = synthetic_scope(["devices.view", "devices.cameras.view"])
      test_pid = self()

      Application.put_env(:serviceradar_web_ng, :camera_semantic_search_opts,
        authorize_fn: fn _ -> {:error, :forbidden} end,
        search_fn: fn _params, _opts ->
          send(test_pid, :unexpected_search_call)
          {:ok, []}
        end
      )

      conn =
        :get
        |> conn("/api/cameras/search?q=person")
        |> assign(:current_scope, scope)
        |> CameraSemanticSearchController.index(%{"q" => "person"})

      assert conn.status == 403
      refute_received :unexpected_search_call
    end
  end

  describe "RecordingsComponents timeline search, hit markers, and bbox overlay (:db_free)" do
    test "preserves backward compatibility for minimal published-mode callers" do
      html =
        render_component(&RecordingsComponents.recordings/1,
          source: %{id: @camera_id, device_uid: "sr:synthetic-cam-1", display_name: "Synthetic Cam"},
          items: [],
          next_cursor: nil,
          selected: nil,
          error: nil,
          loading: false,
          timezone: "Etc/UTC"
        )

      assert html =~ "Synthetic Cam"
      assert html =~ "camera-recordings-empty"
    end

    test "renders inline search form, coverage hit markers, and non-destructive bbox overlay attributes" do
      from_us = 1_700_000_000_000_000
      to_us = 1_700_003_600_000_000
      hit_ts_us = 1_700_001_800_000_000

      hit =
        CameraSemanticSearch.normalize_hit(%{
          catalog_entry_id: @entry_id,
          visual_frame_id: @frame_id,
          camera_source_id: @camera_id,
          camera_display_name: "Synthetic North Gate",
          clip_start_us: hit_ts_us - 2_000_000,
          clip_end_us: hit_ts_us + 2_000_000,
          best_timeline_ts_us: hit_ts_us,
          time_basis: "received",
          score: 0.89,
          object_class: "person",
          dominant_colors: ["red"],
          bbox: [0.15, 0.2, 0.35, 0.85],
          caption_text: "A person in a red jacket crosses the driveway."
        })

      overlay_detections = [
        %{
          visual_frame_id: @frame_id,
          timeline_ts_us: hit_ts_us,
          bbox: [0.15, 0.2, 0.35, 0.85],
          object_class: "person",
          score: 0.89,
          time_basis: "received"
        }
      ]

      html =
        render_component(&RecordingsComponents.recordings/1,
          source: %{id: @camera_id, device_uid: "sr:synthetic-cam-1", display_name: "Synthetic North Gate"},
          mode: :timeline,
          items: [],
          timezone: "Etc/UTC",
          timeline_coverage: %{
            from_us: from_us,
            to_us: to_us,
            time_basis: "received",
            time_uncertainty: "unmeasured",
            buckets: [%{start_us: from_us, end_us: to_us, state: :local_and_archived}],
            blocks: [],
            gaps: [],
            reanchors: []
          },
          timeline_playlist_path:
            "/api/cameras/#{@camera_id}/timeline/playlist.m3u8?from=#{from_us}&to=#{to_us}&source=auto",
          timeline_play_from_us: from_us,
          timeline_play_to_us: to_us,
          timeline_playlist_origin_us: from_us,
          timeline_seek_offset_seconds: 1800.0,
          timeline_highlight_frame_id: @frame_id,
          timeline_search_query: "person in red dress",
          timeline_search_results: [hit],
          timeline_search_executed?: true,
          timeline_overlay_detections: overlay_detections
        )

      assert html =~ ~s(id="camera-timeline-search-form")
      assert html =~ ~s(data-role="semantic-hit-marker")
      assert html =~ ~s(data-seek-offset-seconds="1800.0")
      assert html =~ ~s(data-highlight-frame-id="#{@frame_id}")
      assert html =~ ~s(data-role="semantic-bbox-overlay")
      assert html =~ ~s(data-role="toggle-bbox-overlay")
      assert html =~ "data-overlay-detections="
      assert html =~ ~s(data-role="semantic-hit-caption")
      assert html =~ "A person in a red jacket crosses the driveway."
    end
  end

  describe "Stage 4.4 Policy visual_index_mode and Health visual_indexing card (:db_free)" do
    test "validates visual_index_mode, interval bounds, max_frames bounds, and StorageEntitlement limits" do
      scope = synthetic_scope(["settings.recording.manage"])

      assert {:ok, saved} =
               CameraRecordingSettings.save_policy(
                 scope,
                 %{
                   "camera_source_id" => @camera_id,
                   "stream_profile_id" => @profile_id,
                   "mode" => "continuous",
                   "nvr_member" => "nvr-0",
                   "storage" => "local_and_archive",
                   "visual_index_mode" => "keyframes",
                   "visual_index_min_interval_ms" => "4000",
                   "visual_index_max_frames_per_block" => "32"
                 },
                 entitlement: %{applied?: false},
                 save_fn: fn attrs -> {:ok, attrs} end
               )

      assert saved.visual_index_mode == :keyframes
      assert saved.visual_index_min_interval_ms == 4000
      assert saved.visual_index_max_frames_per_block == 32

      assert {:error, bad_bounds} =
               CameraRecordingSettings.save_policy(
                 scope,
                 %{
                   "camera_source_id" => @camera_id,
                   "stream_profile_id" => @profile_id,
                   "mode" => "off",
                   "visual_index_mode" => "keyframes",
                   "visual_index_min_interval_ms" => "100",
                   "visual_index_max_frames_per_block" => "999"
                 },
                 entitlement: %{applied?: false},
                 save_fn: fn attrs -> {:ok, attrs} end
               )

      assert bad_bounds[:visual_index_min_interval_ms] =~ "500"
      assert bad_bounds[:visual_index_max_frames_per_block] =~ "512"

      assert {:error, disabled_plan} =
               CameraRecordingSettings.save_policy(
                 scope,
                 %{
                   "camera_source_id" => @camera_id,
                   "stream_profile_id" => @profile_id,
                   "mode" => "off",
                   "visual_index_mode" => "keyframes"
                 },
                 entitlement: %{applied?: true, visual_indexing_enabled: false},
                 save_fn: fn attrs -> {:ok, attrs} end
               )

      assert disabled_plan[:visual_index_mode] =~ "not enabled on your plan"
    end

    test "renders visual indexing controls in PolicyComponents and #health-visual-indexing-card in HealthComponents" do
      policy_html =
        render_component(&PolicyComponents.editor_form_card/1,
          can_manage?: true,
          sources: [],
          sources_forbidden?: false,
          policy_profiles: [],
          policy_form: %{
            CameraRecordingSettings.default_policy_form()
            | "visual_index_mode" => "keyframes",
              "visual_index_min_interval_ms" => "3000",
              "visual_index_max_frames_per_block" => "48"
          }
        )

      assert policy_html =~ ~s(id="policy-visual-index-mode-select")
      assert policy_html =~ ~s(id="policy-visual-min-interval-input")
      assert policy_html =~ ~s(id="policy-visual-max-frames-input")
      assert policy_html =~ "keyframes (sampled IDR frames)"

      health_html =
        render_component(&HealthComponents.visual_indexing_card/1,
          visual_indexing: %{
            enabled_policy_count: 2,
            model_id: "siglip-b16-384",
            model_version: "v1",
            embedding_dim: 768,
            pending_count: 3,
            dispatched_count: 1,
            completed_count: 42,
            failed_terminal_count: 0,
            worker_health_status: :healthy
          },
          timezone: "Etc/UTC"
        )

      assert health_html =~ ~s(id="health-visual-indexing-card")
      assert health_html =~ "siglip-b16-384 (v1 · 768-d)"
      assert health_html =~ "42"
    end
  end

  defp synthetic_scope(perms) do
    %Scope{
      user: %{
        id: "00000000-0000-4000-8000-000000000799",
        email: "synthetic-operator@example.com",
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(perms)
    }
  end
end
