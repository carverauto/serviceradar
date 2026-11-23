defmodule ServiceRadarWebNGWeb.CameraRecordingsEventClipsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Camera.RecordingEventClips
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents

  @moduletag :db_free

  @source_id "11111111-1111-4111-8111-111111111111"
  @base_us 1_760_000_000_000_000

  test "renders empty clip state when no clips exist in coverage window" do
    doc =
      %{timeline_event_clips: []}
      |> base_assigns()
      |> render_recordings_doc()

    assert has_selector?(doc, "#camera-timeline-event-clips-section")
    assert has_selector?(doc, "#camera-clips-empty")
    refute has_selector?(doc, "#camera-clips-grid")
    refute has_selector?(doc, "#camera-clips-reset-filters")
  end

  test "renders filter chips with counts, smart detection cards with thumbnails, recorded segment fallback, and coverage markers" do
    clips = sample_clips()

    doc =
      clips
      |> page_assigns(%{timeline_selected_clip_id: "evt-person-1"})
      |> base_assigns()
      |> render_recordings_doc()

    assert has_selector?(doc, "#camera-clips-grid")
    assert text_of(doc, "#camera-clips-total-badge") == "3"
    assert text_of(doc, "#camera-clips-category-count-all") == "3"
    assert text_of(doc, "#camera-clips-category-count-person") == "1"
    assert text_of(doc, "#camera-clips-category-count-vehicle") == "1"
    assert text_of(doc, "#camera-clips-category-count-animal") == "0"
    assert text_of(doc, "#camera-clips-category-count-motion") == "0"

    # Smart person clip has lazy-loaded thumbnail image without fetchpriority="low" and active selected state
    assert attr_of(doc, "#camera-clip-card-evt-person-1", "aria-pressed") == ["true"]
    assert attr_of(doc, "#camera-clip-card-evt-person-1 img", "loading") == ["lazy"]
    assert attr_of(doc, "#camera-clip-card-evt-person-1 img", "fetchpriority") == []

    assert attr_of(doc, "#camera-clip-card-evt-person-1 img", "src") == [
             "https://thumbnails.example.com/frame-1.jpg"
           ]

    # Card without thumbnail_url renders icon placeholder without <img>
    refute has_selector?(doc, "#camera-clip-card-evt-vehicle-1 img")

    # Recorded segment fallback card renders without <img> under basic smart_type
    assert attr_of(doc, "#camera-clip-card-rec-seg-1", "data-clip-category") == ["recording"]
    assert attr_of(doc, "#camera-clip-card-rec-seg-1", "data-clip-smart-type") == ["basic"]
    refute has_selector?(doc, "#camera-clip-card-rec-seg-1 img")

    # Coverage buckets are non-interactive elements so rail click-to-seek is the single click target
    refute has_selector?(doc, "#camera-timeline-coverage-bar button[data-bucket-state]")
    assert attr_of(doc, "#camera-timeline-bucket-0", "phx-click") == []
    assert attr_of(doc, "#camera-timeline-bucket-0", "data-bucket-state") == ["local_and_archived"]

    # Coverage timeline renders event tick markers for smart/motion events only (not :recording segments)
    markers = LazyHTML.query(doc, "#camera-timeline-coverage-bar [data-role='event-clip-marker']")
    assert Enum.count(markers) == 2
    assert LazyHTML.attribute(markers, "phx-click") == ["select_event_clip", "select_event_clip"]
  end

  test "renders server-filtered Smart/Basic mode and category states, showing reset button when filter yields zero matches" do
    clips = sample_clips()

    smart_doc =
      clips
      |> page_assigns(%{timeline_clips_mode: "smart"})
      |> base_assigns()
      |> render_recordings_doc()

    assert attr_of(smart_doc, "#camera-clips-mode-smart", "aria-pressed") == ["true"]
    assert has_selector?(smart_doc, "#camera-clip-card-evt-person-1")
    assert has_selector?(smart_doc, "#camera-clip-card-evt-vehicle-1")
    refute has_selector?(smart_doc, "#camera-clip-card-rec-seg-1")

    basic_doc =
      clips
      |> page_assigns(%{timeline_clips_mode: "basic"})
      |> base_assigns()
      |> render_recordings_doc()

    assert attr_of(basic_doc, "#camera-clips-mode-basic", "aria-pressed") == ["true"]
    refute has_selector?(basic_doc, "#camera-clip-card-evt-person-1")
    assert has_selector?(basic_doc, "#camera-clip-card-rec-seg-1")

    empty_filtered_doc =
      clips
      |> page_assigns(%{timeline_clips_category: "package"})
      |> base_assigns()
      |> render_recordings_doc()

    assert attr_of(empty_filtered_doc, "#camera-clips-category-package", "aria-pressed") == ["true"]
    assert has_selector?(empty_filtered_doc, "#camera-clips-empty")
    assert has_selector?(empty_filtered_doc, "#camera-clips-reset-filters")
    refute has_selector?(empty_filtered_doc, "#camera-clips-grid")
  end

  test "renders server-paginated slice with full window chip counts and off-page rail markers" do
    older_person = %{
      id: "evt-old-person",
      camera_source_id: @source_id,
      started_at: DateTime.from_unix!(@base_us + 10_000_000, :microsecond),
      ended_at: DateTime.from_unix!(@base_us + 20_000_000, :microsecond),
      start_us: @base_us + 10_000_000,
      end_us: @base_us + 20_000_000,
      peak_ts_us: @base_us + 12_000_000,
      duration_seconds: 10,
      category: :person,
      smart_type: :smart,
      label: "Person",
      confidence: 0.91,
      attributes: %{dominant_colors: ["blue"], frame_count: 1},
      visual_frame_id: "frame-old-person",
      catalog_entry_id: "entry-old",
      archive_state: :not_required,
      local_state: :present,
      copy_state: :local_only,
      thumbnail_url: nil
    }

    newer_recordings =
      for idx <- 1..105 do
        start_us = @base_us + (200 - idx) * 15_000_000

        %{
          id: "rec-seg-#{idx}",
          camera_source_id: @source_id,
          started_at: DateTime.from_unix!(start_us, :microsecond),
          ended_at: DateTime.from_unix!(start_us + 10_000_000, :microsecond),
          start_us: start_us,
          end_us: start_us + 10_000_000,
          peak_ts_us: start_us,
          duration_seconds: 10,
          category: :recording,
          smart_type: :basic,
          label: "Recording",
          confidence: nil,
          attributes: %{dominant_colors: [], fragment_count: 1},
          visual_frame_id: nil,
          catalog_entry_id: "entry-#{idx}",
          archive_state: :not_required,
          local_state: :present,
          copy_state: :local_only,
          thumbnail_url: nil
        }
      end

    clips = newer_recordings ++ [older_person]

    all_doc =
      clips
      |> page_assigns(%{})
      |> base_assigns()
      |> render_recordings_doc()

    assert text_of(all_doc, "#camera-clips-total-badge") == "106"
    assert text_of(all_doc, "#camera-clips-category-count-all") == "106"
    assert text_of(all_doc, "#camera-clips-category-count-person") == "1"
    assert text_of(all_doc, "#camera-clips-page-indicator") == "Page 1 / 9"
    assert Enum.count(LazyHTML.query(all_doc, "#camera-clips-grid [data-role='event-clip-card']")) == 12
    assert has_selector?(all_doc, "#camera-timeline-coverage-bar [data-role='event-clip-marker']")

    person_doc =
      clips
      |> page_assigns(%{timeline_clips_category: "person"})
      |> base_assigns()
      |> render_recordings_doc()

    assert text_of(person_doc, "#camera-clips-total-badge") == "1"
    assert text_of(person_doc, "#camera-clips-page-indicator") == "Page 1 / 1"
    assert has_selector?(person_doc, "#camera-clip-card-evt-old-person")
  end

  test "renders 3-pane scalable workspace with camera switcher, vertical timeline scrubber, transport controls, and manage drawer" do
    cam_2 = %{
      id: "22222222-2222-4222-8222-222222222222",
      display_name: "Synthetic North Gate",
      vendor: "unifi",
      vendor_camera_id: "cam-north",
      availability_status: "online",
      metadata: %{"site" => "lab-a"}
    }

    doc =
      %{
        switcher_cameras: [cam_2],
        switcher_total_count: 42,
        switcher_page: 1,
        switcher_total_pages: 3,
        timeline_manage_drawer_open?: true,
        timeline_playlist_path: "/api/cameras/#{@source_id}/timeline/playlist.m3u8?from=1&to=2"
      }
      |> base_assigns()
      |> render_recordings_doc()

    # Left rail: scalable camera switcher (search + pagination, no status filter)
    assert has_selector?(doc, "#camera-switcher-rail")
    assert has_selector?(doc, "#camera-switcher-search[phx-debounce='250']")
    refute has_selector?(doc, "#camera-switcher-filters")
    assert has_selector?(doc, "#camera-switcher-active")
    assert has_selector?(doc, "#camera-switcher-item-#{cam_2.id}")
    assert text_of(doc, "#camera-switcher-total") == "42"
    assert text_of(doc, "#camera-switcher-page") == "1/3"

    # Middle rail: vertical timeline scrubber with LIVE button, zoom +/-, and hook
    assert has_selector?(doc, "#camera-timeline-live-button")
    assert has_selector?(doc, "#camera-timeline-zoom-in")
    assert has_selector?(doc, "#camera-timeline-zoom-out")
    assert has_selector?(doc, "#camera-timeline-span-15m")
    assert has_selector?(doc, "#camera-timeline-coverage-bar[phx-hook='CameraVerticalTimeline']")

    # Main stage: compact transport controls + Manage/Holds drawer
    assert has_selector?(doc, "#camera-timeline-back-10[data-role='transport-back-10']")
    assert has_selector?(doc, "#camera-timeline-play-pause[data-role='transport-play-pause']")
    assert has_selector?(doc, "#camera-timeline-fwd-10[data-role='transport-fwd-10']")
    assert has_selector?(doc, "#camera-timeline-mute[data-role='transport-mute']")
    assert has_selector?(doc, "#camera-timeline-fullscreen[data-role='transport-fullscreen']")
    assert has_selector?(doc, "#camera-timeline-manage-drawer-toggle")
    assert attr_of(doc, "#camera-timeline-manage-drawer", "aria-hidden") == ["false"]
  end

  test "clears clip card highlight when selected clip id is cleared and playback window moves elsewhere" do
    clips = sample_clips()

    moved_doc =
      clips
      |> page_assigns(%{
        timeline_selected_clip_id: nil,
        timeline_play_from_us: @base_us + 1_800_000_000,
        timeline_play_to_us: @base_us + 3_600_000_000
      })
      |> base_assigns()
      |> render_recordings_doc()

    assert attr_of(moved_doc, "#camera-clip-card-evt-person-1", "aria-pressed") == ["false"]
    assert attr_of(moved_doc, "#camera-clip-card-evt-vehicle-1", "aria-pressed") == ["false"]
    assert attr_of(moved_doc, "#camera-clip-card-rec-seg-1", "aria-pressed") == ["false"]
  end

  defp page_assigns(all_clips, overrides) do
    mode = Map.get(overrides, :timeline_clips_mode, "all")
    category = Map.get(overrides, :timeline_clips_category, "all")
    page = Map.get(overrides, :timeline_clips_page, 1)
    paged = RecordingEventClips.paginate_clips(all_clips, %{mode: mode, category: category, page: page, per_page: 12})

    markers =
      all_clips
      |> Enum.reject(&(&1.category == :recording))
      |> Enum.map(fn clip ->
        %{
          id: clip.id,
          category: clip.category,
          smart_type: clip.smart_type,
          label: clip.label,
          confidence: clip.confidence,
          start_us: clip.start_us,
          end_us: clip.end_us,
          peak_ts_us: clip.peak_ts_us,
          visual_frame_id: clip.visual_frame_id
        }
      end)

    Map.merge(
      %{
        timeline_event_clips: paged.clips,
        timeline_event_markers: markers,
        timeline_clips_counts: paged.counts,
        timeline_clips_total_count: paged.total_count,
        timeline_clips_page: paged.page,
        timeline_clips_total_pages: paged.total_pages
      },
      overrides
    )
  end

  defp render_recordings_doc(assigns) do
    (&RecordingsComponents.recordings/1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp has_selector?(doc, selector) do
    doc |> LazyHTML.query(selector) |> Enum.any?()
  end

  defp attr_of(doc, selector, attr) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
  end

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        source: %{
          id: @source_id,
          device_uid: "sr:synthetic-cam-clips",
          display_name: "Synthetic Entry Camera"
        },
        mode: :timeline,
        items: [],
        next_cursor: nil,
        selected: nil,
        error: nil,
        loading: false,
        timezone: "Etc/UTC",
        can_view_recording_settings: false,
        can_manage_holds: false,
        stream_profiles: [],
        timeline_profile_id: "",
        timeline_span: "1h",
        timeline_source: "auto",
        timeline_coverage: %{
          from_us: @base_us,
          to_us: @base_us + 3_600_000_000,
          time_basis: "received",
          time_uncertainty: "unmeasured",
          buckets: [
            %{
              start_us: @base_us,
              end_us: @base_us + 3_600_000_000,
              state: :local_and_archived,
              provisional?: false
            }
          ],
          blocks: [],
          gaps: [],
          reanchors: []
        },
        timeline_playlist_path: nil,
        timeline_play_from_us: @base_us,
        timeline_play_to_us: @base_us + 600_000_000,
        timeline_event_clips: [],
        timeline_clips_mode: "all",
        timeline_clips_category: "all",
        timeline_selected_clip_id: nil
      },
      overrides
    )
  end

  defp sample_clips do
    [
      %{
        id: "evt-person-1",
        camera_source_id: @source_id,
        started_at: DateTime.from_unix!(@base_us + 300_000_000, :microsecond),
        ended_at: DateTime.from_unix!(@base_us + 312_000_000, :microsecond),
        start_us: @base_us + 300_000_000,
        end_us: @base_us + 312_000_000,
        peak_ts_us: @base_us + 304_000_000,
        duration_seconds: 12,
        category: :person,
        smart_type: :smart,
        label: "Person",
        confidence: 0.94,
        attributes: %{dominant_colors: ["red", "black"], frame_count: 3},
        visual_frame_id: "frame-1",
        catalog_entry_id: "entry-1",
        archive_state: :verified,
        local_state: :present,
        copy_state: :local_and_archived,
        thumbnail_url: "https://thumbnails.example.com/frame-1.jpg"
      },
      %{
        id: "evt-vehicle-1",
        camera_source_id: @source_id,
        started_at: DateTime.from_unix!(@base_us + 600_000_000, :microsecond),
        ended_at: DateTime.from_unix!(@base_us + 615_000_000, :microsecond),
        start_us: @base_us + 600_000_000,
        end_us: @base_us + 615_000_000,
        peak_ts_us: @base_us + 605_000_000,
        duration_seconds: 15,
        category: :vehicle,
        smart_type: :smart,
        label: "Vehicle",
        confidence: 0.87,
        attributes: %{dominant_colors: ["white"], frame_count: 2},
        visual_frame_id: "frame-2",
        catalog_entry_id: "entry-1",
        archive_state: :not_required,
        local_state: :present,
        copy_state: :local_only,
        thumbnail_url: nil
      },
      %{
        id: "rec-seg-1",
        camera_source_id: @source_id,
        started_at: DateTime.from_unix!(@base_us + 1_200_000_000, :microsecond),
        ended_at: DateTime.from_unix!(@base_us + 1_260_000_000, :microsecond),
        start_us: @base_us + 1_200_000_000,
        end_us: @base_us + 1_260_000_000,
        peak_ts_us: @base_us + 1_200_000_000,
        duration_seconds: 60,
        category: :recording,
        smart_type: :basic,
        label: "Recording",
        confidence: nil,
        attributes: %{dominant_colors: [], fragment_count: 10},
        visual_frame_id: nil,
        catalog_entry_id: "entry-2",
        archive_state: :not_required,
        local_state: :present,
        copy_state: :local_only,
        thumbnail_url: nil
      }
    ]
  end
end
