defmodule ServiceRadar.Camera.VisualCaptionUnitTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.SemanticSearch
  alias ServiceRadar.Camera.VisualCaptionBackfill
  alias ServiceRadar.Camera.VisualCaptionClient
  alias ServiceRadar.Camera.VisualCaptionWorker

  @cam_a "00000000-0000-4000-8000-000000001101"
  @prof_a "00000000-0000-4000-8000-000000001201"
  @entry_1 "00000000-0000-7000-8000-000000001301"
  @entry_2 "00000000-0000-7000-8000-000000001302"
  @block_1 "00000000-0000-4000-8000-000000001401"
  @frame_1 "00000000-0000-7000-8000-000000001501"
  @frame_2 "00000000-0000-7000-8000-000000001502"

  describe "VisualCaptionClient" do
    test "uniform_sample/2 preserves endpoints and caps at 6 frames" do
      items = Enum.to_list(1..12)
      sampled = VisualCaptionClient.uniform_sample(items, 6)

      assert length(sampled) == 6
      assert hd(sampled) == 1
      assert List.last(sampled) == 12
      assert VisualCaptionClient.uniform_sample([1, 2, 3], 6) == [1, 2, 3]
    end

    test "caption_frames/2 sends OpenAI vision payload and parses fenced JSON response" do
      test_pid = self()
      frames = [<<0xFF, 0xD8, 0xFF, 0xE0, 1>>, <<0xFF, 0xD8, 0xFF, 0xE0, 2>>]

      http_client = fn url, payload, headers, timeout ->
        send(test_pid, {:vlm_request, url, payload, headers, timeout})

        body = %{
          "choices" => [
            %{
              "message" => %{
                "content" => """
                ```json
                {
                  "caption": "A child is doing pushups on the living room rug.",
                  "action_tags": ["Pushups", "Exercise", "pushups", "child"]
                }
                ```
                """
              }
            }
          ]
        }

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, result} =
               VisualCaptionClient.caption_frames(frames,
                 url: "http://vlm.internal:8080/v1/chat/completions",
                 model_id: "qwen2.5-vl-7b-instruct",
                 prompt_version: "v1",
                 timeout_ms: 25_000,
                 http_client: http_client
               )

      assert result.caption_text == "A child is doing pushups on the living room rug."
      assert result.action_tags == ["pushups", "exercise", "child"]
      assert result.vlm_model_id == "qwen2.5-vl-7b-instruct"
      assert result.prompt_version == "v1"

      assert_received {:vlm_request, "http://vlm.internal:8080/v1/chat/completions", payload,
                       _headers, 25_000}

      assert payload["model"] == "qwen2.5-vl-7b-instruct"
      [_sys, %{"role" => "user", "content" => content_parts}] = payload["messages"]
      image_parts = Enum.filter(content_parts, &(&1["type"] == "image_url"))
      assert length(image_parts) == 2

      assert Enum.all?(
               image_parts,
               &String.starts_with?(&1["image_url"]["url"], "data:image/jpeg;base64,")
             )
    end

    test "caption_frames/2 rejects empty frames and malformed VLM JSON" do
      assert {:error, :no_frames} = VisualCaptionClient.caption_frames([])

      bad_client = fn _url, _payload, _headers, _timeout ->
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "not json"}}]}}}
      end

      assert {:error, :invalid_vlm_json} =
               VisualCaptionClient.caption_frames([<<1, 2, 3>>], http_client: bad_client)
    end
  end

  describe "VisualCaptionWorker" do
    test "has_smart_detection?/1 matches Smart categories only" do
      assert VisualCaptionWorker.has_smart_detection?([%{"object_class" => "person"}])
      assert VisualCaptionWorker.has_smart_detection?([%{object_class: "Animal"}])
      assert VisualCaptionWorker.has_smart_detection?([%{"object_class" => "vehicle"}])
      assert VisualCaptionWorker.has_smart_detection?([%{"object_class" => "package"}])
      refute VisualCaptionWorker.has_smart_detection?([%{"object_class" => "motion"}])
      refute VisualCaptionWorker.has_smart_detection?([])
      refute VisualCaptionWorker.has_smart_detection?(nil)
    end

    test "enqueue_for_entry/3 is a no-op when disabled and inserts string-keyed args when enabled" do
      assert :noop =
               VisualCaptionWorker.enqueue_for_entry(@entry_1, @frame_1,
                 enabled_fn: fn -> false end,
                 insert_fn: fn _cs -> flunk("should not insert when disabled") end
               )

      test_pid = self()

      assert {:ok, :inserted} =
               VisualCaptionWorker.enqueue_for_entry(@entry_1, @frame_1,
                 enabled_fn: fn -> true end,
                 insert_fn: fn cs ->
                   send(test_pid, {:oban_changeset, cs})
                   {:ok, :inserted}
                 end
               )

      assert_received {:oban_changeset, cs}
      assert cs.changes.args == %{"catalog_entry_id" => @entry_1, "visual_frame_id" => @frame_1}
    end

    test "caption_entry/3 captions Smart frames, falls back cleanly when embedder is busy, and upserts" do
      test_pid = self()

      entry = %{
        id: @entry_1,
        recording_block_id: @block_1,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        local_state: :present,
        archive_state: :not_required,
        quarantine_reason: nil,
        timeline_start_us: 10_000_000,
        timeline_end_us: 20_000_000,
        time_basis: :received
      }

      frames = [
        %{
          id: @frame_1,
          timeline_ts_us: 12_000_000,
          detections: [%{"object_class" => "person"}],
          thumbnail_jpeg: <<0xFF, 0xD8, 1>>
        },
        %{
          id: @frame_2,
          timeline_ts_us: 16_000_000,
          detections: [%{"object_class" => "person"}],
          thumbnail_jpeg: <<0xFF, 0xD8, 2>>
        }
      ]

      assert :ok =
               VisualCaptionWorker.caption_entry(@entry_1, @frame_1,
                 entry_loader: fn _id -> {:ok, entry} end,
                 frames_loader: fn _id -> {:ok, frames} end,
                 caption_fn: fn jpegs, _opts ->
                   assert length(jpegs) == 2

                   {:ok,
                    %{
                      caption_text: "A delivery driver places a cardboard box near the door.",
                      action_tags: ["delivery", "leaving box"],
                      vlm_model_id: "qwen2.5-vl-7b-instruct",
                      prompt_version: "v1"
                    }}
                 end,
                 text_embedder: fn _q, _ctx -> {:error, :timeout} end,
                 upsert_fn: fn attrs ->
                   send(test_pid, {:upserted_caption, attrs})
                   {:ok, attrs}
                 end
               )

      assert_received {:upserted_caption, attrs}
      assert attrs.catalog_entry_id == @entry_1
      assert attrs.visual_frame_id == @frame_1
      assert attrs.start_us == 12_000_000
      assert attrs.end_us == 16_000_000
      assert attrs.caption_text == "A delivery driver places a cardboard box near the door."
      assert attrs.action_tags == ["delivery", "leaving box"]
      assert attrs.caption_embedding == nil
      assert attrs.embedding_dim == nil
    end

    test "caption_entry/3 skips quarantined entries without calling VLM" do
      quarantined = %{
        id: @entry_1,
        recording_block_id: @block_1,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        local_state: :quarantined,
        archive_state: :not_required,
        quarantine_reason: "corrupt_fragment"
      }

      assert :ok =
               VisualCaptionWorker.caption_entry(@entry_1, nil,
                 entry_loader: fn _id -> {:ok, quarantined} end,
                 frames_loader: fn _id ->
                   flunk("should not load frames for quarantined entry")
                 end,
                 caption_fn: fn _jpegs, _opts ->
                   flunk("should not call VLM for quarantined entry")
                 end
               )
    end
  end

  describe "VisualCaptionBackfill" do
    test "enqueue_missing/2 enqueues jobs for missing Smart clips and enforces RBAC" do
      viewer_scope = %{
        user: %{id: "viewer-1"},
        permissions: MapSet.new(["devices.view"])
      }

      assert {:error, %Forbidden{}} =
               VisualCaptionBackfill.enqueue_missing(%{}, scope: viewer_scope)

      operator_scope = %{
        user: %{id: "operator-1"},
        permissions: MapSet.new(["settings.recording.operate"])
      }

      assert {:ok, summary} =
               VisualCaptionBackfill.enqueue_missing(
                 %{limit: 2},
                 scope: operator_scope,
                 candidates_loader: fn spec ->
                   assert spec.limit == 2

                   {:ok,
                    [
                      %{catalog_entry_id: @entry_1, visual_frame_id: @frame_1},
                      %{catalog_entry_id: @entry_2, visual_frame_id: @frame_2}
                    ]}
                 end,
                 enqueue_fn: fn entry_id, _frame_id -> {:ok, %{entry_id: entry_id}} end
               )

      assert summary.scanned_count == 2
      assert summary.enqueued_count == 2
      assert summary.catalog_entry_ids == [@entry_1, @entry_2]
      assert summary.next_cursor_id == @entry_2
    end
  end

  describe "SemanticSearch Hybrid RRF fusion and embed_text/2" do
    test "embed_text/2 returns normalized Ash.Vector with active model metadata" do
      assert {:ok, embedded} =
               SemanticSearch.embed_text(
                 "child doing pushups",
                 bypass_cache: true,
                 text_embedder: fn _q, _ctx -> {:ok, unit_vec(768)} end
               )

      assert %Ash.Vector{dimensions: 768} = embedded.vector
      assert embedded.embedding_dim == 768
      assert is_binary(embedded.model_id)
    end

    test "fuses caption FTS + caption vector + visual vector via RRF and retrieves caption-only action hits" do
      caller = %{
        user: %{id: "investigator-rrf"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      visual_hit = %{
        embedding_id: "emb-1",
        visual_frame_id: @frame_1,
        catalog_entry_id: @entry_1,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        timeline_ts_us: 10_000_000,
        region_kind: "scene",
        region_index: 0,
        object_class: "person",
        confidence: 0.72,
        bbox: nil,
        dominant_colors: [],
        time_basis: "received",
        detections: [],
        catalog_start_us: 8_000_000,
        catalog_end_us: 14_000_000,
        time_uncertainty_us: nil,
        score: 0.25
      }

      caption_hit = %{
        id: "cap-2",
        catalog_entry_id: @entry_2,
        visual_frame_id: @frame_2,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        start_us: 30_000_000,
        end_us: 36_000_000,
        time_basis: "received",
        caption_text: "A child is doing pushups on the living room floor.",
        action_tags: ["pushups", "exercise"],
        catalog_start_us: 28_000_000,
        catalog_end_us: 40_000_000,
        time_uncertainty_us: nil,
        fts_rank: 0.85,
        caption_similarity: 0.31
      }

      assert {:ok, resp} =
               SemanticSearch.search(
                 %{query: "child doing pushups", from_us: 0, to_us: 60_000_000},
                 scope: caller,
                 now: ~U[2026-11-24 00:01:00Z],
                 bypass_cache: true,
                 text_embedder: fn _q, _ctx -> {:ok, unit_vec(768)} end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Living Room Cam", device_uid: "dev-lr"}],
                   embeddings_loader: fn _vec, _spec -> {:ok, [visual_hit]} end,
                   captions_loader: fn _vec, spec ->
                     assert spec.query == "child doing pushups"
                     assert spec.camera_source_ids == [@cam_a]
                     {:ok, [caption_hit]}
                   end,
                   audit_writer: fn audit -> {:ok, audit} end
                 }
               )

      assert [top_clip, second_clip] = resp.results
      # Caption FTS + Caption Vector match ranks strictly above visual-only match
      assert top_clip.catalog_entry_id == @entry_2
      assert top_clip.visual_frame_id == @frame_2
      assert top_clip.caption_text == "A child is doing pushups on the living room floor."
      assert top_clip.action_tags == ["pushups", "exercise"]
      assert "caption_fts" in top_clip.match_sources
      assert "caption_vector" in top_clip.match_sources
      assert top_clip.score > second_clip.score

      assert second_clip.catalog_entry_id == @entry_1
      assert second_clip.match_sources == ["visual_vector"]
    end
  end

  defp unit_vec(dim) do
    [1.0 | List.duplicate(0.0, dim - 1)]
  end
end
