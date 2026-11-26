defmodule ServiceRadar.Camera.RecordingEventClipsTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.RecordingEventClips

  @camera_id "11111111-1111-4111-8111-111111111111"
  @profile_id "22222222-2222-4222-8222-222222222222"
  @entry_1_id "33333333-3333-4333-8333-333333333333"
  @entry_2_id "44444444-4444-4444-8444-444444444444"
  @quarantined_entry_id "55555555-5555-4555-8555-555555555555"
  @block_1_id "66666666-6666-4666-8666-666666666666"
  @block_2_id "77777777-7777-4777-8777-777777777777"
  @frame_1_id "88888888-8888-4888-8888-888888888881"
  @frame_2_id "88888888-8888-4888-8888-888888888882"
  @frame_3_id "88888888-8888-4888-8888-888888888883"
  @frame_4_id "88888888-8888-4888-8888-888888888884"
  @frame_q_id "88888888-8888-4888-8888-888888888885"

  @base_us 1_760_000_000_000_000

  describe "list_clips/3 coalescing, classification, and fallback" do
    test "coalesces adjacent detections, excludes quarantined entries, and adds recording fallback segments" do
      entries = [
        playable_entry(
          @entry_1_id,
          @block_1_id,
          @base_us,
          @base_us + 120_000_000,
          :present,
          :verified
        ),
        playable_entry(
          @entry_2_id,
          @block_2_id,
          @base_us + 180_000_000,
          @base_us + 300_000_000,
          :present,
          :not_required
        ),
        %{
          id: @quarantined_entry_id,
          recording_block_id: nil,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          timeline_start_us: @base_us + 310_000_000,
          timeline_end_us: @base_us + 360_000_000,
          local_state: :quarantined,
          archive_state: :not_required,
          quarantine_reason: :unrecoverable_journal
        }
      ]

      frames = [
        # Two adjacent person frames within 4s -> coalesced into one :person smart clip
        %{
          id: @frame_1_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 1,
          timeline_ts_us: @base_us + 10_000_000,
          scene_suppressed: false,
          detections: [
            %{
              "object_class" => "person",
              "confidence" => 0.82,
              "bbox" => %{"x1" => 0.1, "y1" => 0.1, "x2" => 0.4, "y2" => 0.8},
              "dominant_colors" => ["blue"]
            }
          ]
        },
        %{
          id: @frame_2_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 2,
          timeline_ts_us: @base_us + 14_000_000,
          scene_suppressed: false,
          detections: [
            %{
              "object_class" => "person",
              "confidence" => 0.95,
              "bbox" => %{"x1" => 0.15, "y1" => 0.1, "x2" => 0.45, "y2" => 0.85},
              "dominant_colors" => ["red", "blue"]
            },
            %{
              "object_class" => "car",
              "confidence" => 0.88,
              "bbox" => %{"x1" => 0.5, "y1" => 0.3, "x2" => 0.9, "y2" => 0.8},
              "dominant_colors" => ["white"]
            }
          ]
        },
        # Non-suppressed frame with empty detections -> :motion (:basic) clip
        %{
          id: @frame_3_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 5,
          timeline_ts_us: @base_us + 60_000_000,
          scene_suppressed: false,
          detections: []
        },
        # Scene-suppressed frame with empty detections -> ignored
        %{
          id: @frame_4_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 6,
          timeline_ts_us: @base_us + 70_000_000,
          scene_suppressed: true,
          detections: []
        },
        # Frame belonging to quarantined entry -> excluded
        %{
          id: @frame_q_id,
          catalog_entry_id: @quarantined_entry_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 1,
          timeline_ts_us: @base_us + 320_000_000,
          scene_suppressed: false,
          detections: [
            %{"object_class" => "package", "confidence" => 0.91, "dominant_colors" => []}
          ]
        }
      ]

      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, entries} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, frames} end
      }

      assert {:ok, result} =
               RecordingEventClips.list_clips(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 400_000_000},
                 loaders: loaders
               )

      # Expect: 1 coalesced :person, 1 :vehicle, 1 :motion (all from entry_1),
      # and 1 :recording fallback segment for entry_2 (uncovered by detections).
      # Quarantined entry + its package frame are strictly excluded.
      assert length(result.clips) == 4

      assert RecordingEventClips.category_counts(result.clips) == %{
               all: 4,
               smart: 2,
               basic: 2,
               person: 1,
               vehicle: 1,
               animal: 0,
               package: 0,
               motion: 1,
               recording: 1
             }

      person_clip = Enum.find(result.clips, &(&1.category == :person))
      assert person_clip.smart_type == :smart
      assert person_clip.label == "Person"
      assert person_clip.confidence == 0.95
      assert person_clip.visual_frame_id == @frame_2_id
      assert person_clip.attributes.frame_count == 2
      assert Enum.sort(person_clip.attributes.dominant_colors) == ["blue", "red"]
      assert person_clip.archive_state == :verified
      assert person_clip.thumbnail_url == nil

      vehicle_clip = Enum.find(result.clips, &(&1.category == :vehicle))
      assert vehicle_clip.smart_type == :smart
      assert vehicle_clip.confidence == 0.88
      assert vehicle_clip.attributes.dominant_colors == ["white"]

      motion_clip = Enum.find(result.clips, &(&1.category == :motion))
      assert motion_clip.smart_type == :basic
      assert motion_clip.confidence == nil

      rec_clip = Enum.find(result.clips, &(&1.category == :recording))
      assert rec_clip.id == "rec-#{@entry_2_id}"
      assert rec_clip.smart_type == :basic
      assert rec_clip.catalog_entry_id == @entry_2_id
      assert rec_clip.duration_seconds == 120
      assert rec_clip.thumbnail_url == nil

      # Ordered most-recent first
      starts = Enum.map(result.clips, & &1.start_us)
      assert starts == Enum.sort(starts, :desc)
    end

    test "supports in-memory mode and category filtering via filter_clips/2" do
      entries = [
        playable_entry(
          @entry_1_id,
          @block_1_id,
          @base_us,
          @base_us + 60_000_000,
          :present,
          :not_required
        ),
        playable_entry(
          @entry_2_id,
          @block_2_id,
          @base_us + 70_000_000,
          @base_us + 130_000_000,
          :present,
          :not_required
        )
      ]

      frames = [
        %{
          id: @frame_1_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 1,
          timeline_ts_us: @base_us + 10_000_000,
          scene_suppressed: false,
          detections: [
            %{"object_class" => "dog", "confidence" => 0.9, "dominant_colors" => ["brown"]},
            %{"object_class" => "parcel", "confidence" => 0.77, "dominant_colors" => []}
          ]
        }
      ]

      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, entries} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, frames} end
      }

      {:ok, %{clips: clips}} =
        RecordingEventClips.list_clips(
          @camera_id,
          %{from_us: @base_us, to_us: @base_us + 200_000_000},
          loaders: loaders
        )

      smart_only = RecordingEventClips.filter_clips(clips, %{mode: :smart})
      assert smart_only |> Enum.map(& &1.category) |> Enum.sort() == [:animal, :package]

      basic_only = RecordingEventClips.filter_clips(clips, %{mode: :basic})
      assert Enum.map(basic_only, & &1.category) == [:recording]

      animal_only = RecordingEventClips.filter_clips(clips, %{category: "animal"})
      assert Enum.map(animal_only, & &1.category) == [:animal]
    end

    test "returns full uncapped coalesced clips so older smart clips remain countable and filterable" do
      older_entry =
        playable_entry(
          @entry_1_id,
          @block_1_id,
          @base_us,
          @base_us + 60_000_000,
          :present,
          :not_required
        )

      newer_entries =
        for idx <- 1..110 do
          start_us = @base_us + idx * 120_000_000

          playable_entry(
            Ecto.UUID.generate(),
            Ecto.UUID.generate(),
            start_us,
            start_us + 60_000_000,
            :present,
            :not_required
          )
        end

      older_person_frame = %{
        id: @frame_1_id,
        catalog_entry_id: @entry_1_id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        fragment_sequence: 1,
        timeline_ts_us: @base_us + 10_000_000,
        scene_suppressed: false,
        detections: [
          %{"object_class" => "person", "confidence" => 0.93, "dominant_colors" => ["navy"]}
        ]
      }

      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, [older_entry | newer_entries]} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, [older_person_frame]} end
      }

      window = %{from_us: @base_us, to_us: @base_us + 15_000_000_000}

      assert {:ok, %{clips: clips}} =
               RecordingEventClips.list_clips(@camera_id, window, loaders: loaders)

      assert length(clips) == 111

      counts = RecordingEventClips.category_counts(clips)
      assert counts.all == 111
      assert counts.smart == 1
      assert counts.basic == 110
      assert counts.person == 1
      assert counts.recording == 110

      smart_clips = RecordingEventClips.filter_clips(clips, %{mode: :smart})
      assert Enum.map(smart_clips, & &1.visual_frame_id) == [@frame_1_id]

      person_clips = RecordingEventClips.filter_clips(clips, %{category: :person})
      assert Enum.map(person_clips, & &1.visual_frame_id) == [@frame_1_id]
    end

    test "list_page/3 returns bounded server-side pages, clamped page numbers, full counts, and markers" do
      entries =
        for idx <- 1..30 do
          start_us = @base_us + idx * 60_000_000

          playable_entry(
            Ecto.UUID.generate(),
            Ecto.UUID.generate(),
            start_us,
            start_us + 45_000_000,
            :present,
            :verified
          )
        end

      first_entry = hd(entries)

      person_frame = %{
        id: @frame_1_id,
        catalog_entry_id: first_entry.id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        fragment_sequence: 1,
        timeline_ts_us: first_entry.timeline_start_us + 5_000_000,
        scene_suppressed: false,
        detections: [
          %{"object_class" => "person", "confidence" => 0.91, "dominant_colors" => ["black"]}
        ]
      }

      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, entries} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, [person_frame]} end
      }

      window = %{from_us: @base_us, to_us: @base_us + 3_600_000_000}

      # Default per_page is 12 -> 30 clips total -> 3 pages (12, 12, 6)
      assert {:ok, page1} = RecordingEventClips.list_page(@camera_id, window, loaders: loaders)
      assert length(page1.clips) == 12
      assert page1.total_count == 30
      assert page1.page == 1
      assert page1.per_page == 12
      assert page1.total_pages == 3
      assert page1.counts.all == 30
      assert page1.counts.smart == 1
      assert page1.counts.basic == 29
      assert page1.counts.person == 1
      assert length(page1.markers) == 1
      assert hd(page1.markers).category == :person
      assert hd(page1.markers).visual_frame_id == @frame_1_id

      # Page 3 returns remaining 6 clips
      assert {:ok, page3} =
               RecordingEventClips.list_page(@camera_id, Map.put(window, :page, 3),
                 loaders: loaders
               )

      assert length(page3.clips) == 6
      assert page3.page == 3
      assert page3.total_pages == 3

      # Out-of-bounds page clamps to total_pages; per_page caps at 48
      assert {:ok, clamped} =
               RecordingEventClips.list_page(
                 @camera_id,
                 Map.merge(window, %{page: 99, per_page: 200}),
                 loaders: loaders
               )

      assert clamped.per_page == 48
      assert clamped.page == 1
      assert clamped.total_pages == 1
      assert length(clamped.clips) == 30

      # Filtered smart page preserves full window counts while slicing filtered results
      assert {:ok, smart_page} =
               RecordingEventClips.list_page(
                 @camera_id,
                 Map.merge(window, %{mode: :smart, page: 1, per_page: 12}),
                 loaders: loaders
               )

      assert smart_page.total_count == 1
      assert smart_page.total_pages == 1
      assert smart_page.counts.all == 30
      assert smart_page.counts.smart == 1
      assert Enum.map(smart_page.clips, & &1.category) == [:person]
    end

    test "uses a provider thumbnail URL or the block thumbnail, never loading bytea blobs" do
      entries = [
        @entry_1_id
        |> playable_entry(
          @block_1_id,
          @base_us,
          @base_us + 120_000_000,
          :present,
          :verified
        )
        |> Map.put(:has_thumbnail, true),
        @entry_2_id
        |> playable_entry(
          @block_2_id,
          @base_us + 180_000_000,
          @base_us + 300_000_000,
          :present,
          :not_required
        )
        |> Map.put(:has_thumbnail, true)
      ]

      frames = [
        # Frame with a provider-supplied thumbnail URL -> uses it
        %{
          id: @frame_1_id,
          thumbnail_url: "/vantage/thumbnails/#{@frame_1_id}.jpg",
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 1,
          timeline_ts_us: @base_us + 10_000_000,
          scene_suppressed: false,
          has_thumbnail: true,
          detections: [
            %{"object_class" => "person", "confidence" => 0.92, "dominant_colors" => []}
          ]
        },
        # Frame without a provider thumbnail -> falls back to parent block URL
        %{
          id: @frame_3_id,
          catalog_entry_id: @entry_1_id,
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          fragment_sequence: 5,
          timeline_ts_us: @base_us + 60_000_000,
          scene_suppressed: false,
          has_thumbnail: false,
          detections: []
        }
      ]

      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, entries} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, frames} end
      }

      assert {:ok, %{clips: clips}} =
               RecordingEventClips.list_clips(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 400_000_000},
                 loaders: loaders
               )

      person_clip = Enum.find(clips, &(&1.category == :person))

      assert person_clip.thumbnail_url == "/vantage/thumbnails/#{@frame_1_id}.jpg"

      motion_clip = Enum.find(clips, &(&1.category == :motion))

      assert motion_clip.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/block/#{@entry_1_id}.jpg"

      rec_clip = Enum.find(clips, &(&1.category == :recording))

      assert rec_clip.thumbnail_url ==
               "/api/cameras/#{@camera_id}/timeline/thumbnails/block/#{@entry_2_id}.jpg"
    end
  end

  describe "authorization and validation" do
    test "rejects unauthorized actors and allows recordings viewers" do
      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, []} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, []} end
      }

      params = %{from_us: @base_us, to_us: @base_us + 60_000_000}

      denied_actor = %{
        id: Ecto.UUID.generate(),
        role: :viewer,
        permissions: MapSet.new(["devices.view"])
      }

      assert {:error, %Forbidden{}} =
               RecordingEventClips.list_clips(@camera_id, params,
                 actor: denied_actor,
                 loaders: loaders
               )

      assert {:error, %Forbidden{}} =
               RecordingEventClips.list_clips(@camera_id, params,
                 actor: nil,
                 loaders: loaders
               )

      allowed_actor = %{
        id: Ecto.UUID.generate(),
        role: :viewer,
        permissions: MapSet.new(["devices.cameras.recordings.view"])
      }

      assert {:ok, %{clips: []}} =
               RecordingEventClips.list_clips(@camera_id, params,
                 actor: allowed_actor,
                 loaders: loaders
               )
    end

    test "validates camera UUID, stream profile UUID, and canonical window params" do
      loaders = %{
        catalog_loader: fn _cam, _prof, _from, _to -> {:ok, []} end,
        visual_frames_loader: fn _cam, _prof, _from, _to -> {:ok, []} end
      }

      assert {:error, :invalid_camera_source_id} =
               RecordingEventClips.list_clips("not-a-uuid", %{from_us: 1, to_us: 2},
                 loaders: loaders
               )

      assert {:error, :invalid_stream_profile_id} =
               RecordingEventClips.list_clips(
                 @camera_id,
                 %{from_us: 1, to_us: 2, stream_profile_id: "not-a-uuid"},
                 loaders: loaders
               )

      assert {:error, :invalid_timeline_window} =
               RecordingEventClips.list_clips(@camera_id, %{from_us: 100, to_us: 100},
                 loaders: loaders
               )

      assert {:error, :invalid_timeline_window} =
               RecordingEventClips.list_clips(@camera_id, %{from: 1, to: 2}, loaders: loaders)

      assert {:error, :timeline_window_too_large} =
               RecordingEventClips.list_clips(
                 @camera_id,
                 %{from_us: 0, to_us: 32 * 86_400 * 1_000_000},
                 loaders: loaders
               )
    end
  end

  defp playable_entry(id, block_id, start_us, end_us, local_state, archive_state) do
    %{
      id: id,
      recording_block_id: block_id,
      camera_source_id: @camera_id,
      stream_profile_id: @profile_id,
      timeline_start_us: start_us,
      timeline_end_us: end_us,
      local_state: local_state,
      archive_state: archive_state,
      quarantine_reason: nil,
      fragment_count: 10
    }
  end
end
