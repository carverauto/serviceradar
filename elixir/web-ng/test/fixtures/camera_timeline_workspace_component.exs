alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
alias ServiceRadarWebNGWeb.Endpoint

# Verified routes read Endpoint configuration; no HTTP server or ServiceRadar app is started.
Application.put_env(:serviceradar_web_ng, Endpoint,
  server: false,
  secret_key_base: String.duplicate("synthetic-component-key-", 4),
  url: [host: "example.test"],
  live_view: [signing_salt: "synthetic-component-salt"]
)

{:ok, _} = Application.ensure_all_started(:phoenix)
{:ok, endpoint} = Endpoint.start_link()

source_id = "11111111-1111-4111-8111-111111111111"
profile_id = "22222222-2222-4222-8222-222222222222"
frame_1_id = "88888888-8888-4888-8888-888888888881"
frame_2_id = "88888888-8888-4888-8888-888888888882"
frame_off_page_id = "88888888-8888-4888-8888-888888888889"

to_us = DateTime.to_unix(~U[2100-01-01 12:00:00Z], :microsecond)
from_us = to_us - 3_600_000_000

bucket_states = [
  :local_only,
  :local_only,
  :pending_archive,
  :local_and_archived,
  :local_and_archived,
  :local_and_archived,
  :gap,
  :local_and_archived,
  :archive_only,
  :archive_only,
  :local_and_archived,
  :local_and_archived,
  :local_and_archived,
  :pending_archive,
  :local_and_archived,
  :local_and_archived,
  :local_only,
  :local_and_archived,
  :local_and_archived,
  :local_and_archived,
  :not_scheduled,
  :local_and_archived,
  :local_and_archived,
  :local_and_archived
]

bucket_span_us = div(to_us - from_us, length(bucket_states))

buckets =
  bucket_states
  |> Enum.with_index()
  |> Enum.map(fn {state, idx} ->
    b_start = from_us + idx * bucket_span_us

    %{
      start_us: b_start,
      end_us: b_start + bucket_span_us,
      state: state,
      provisional?: idx == 2
    }
  end)

blocks = [
  %{
    id: "33333333-3333-4333-8333-333333333301",
    stream_profile_id: profile_id,
    timeline_start_us: from_us + 300_000_000,
    timeline_end_us: from_us + 1_200_000_000,
    local_state: :present,
    archive_state: :verified,
    copy_state: :local_and_archived,
    provisional?: false,
    reanchored?: false
  },
  %{
    id: "33333333-3333-4333-8333-333333333302",
    stream_profile_id: profile_id,
    timeline_start_us: from_us + 1_500_000_000,
    timeline_end_us: from_us + 2_400_000_000,
    local_state: :present,
    archive_state: :pending,
    copy_state: :pending_archive,
    provisional?: true,
    reanchored?: true
  },
  %{
    id: "33333333-3333-4333-8333-333333333303",
    stream_profile_id: profile_id,
    timeline_start_us: from_us + 2_700_000_000,
    timeline_end_us: to_us - 60_000_000,
    local_state: :present,
    archive_state: :not_required,
    copy_state: :local_only,
    provisional?: false,
    reanchored?: false
  }
]

clip_specs = [
  {"evt-person-1", :person, :smart, "Person", 0.94, frame_1_id, 12, to_us - 180_000_000, :verified, :local_and_archived},
  {"evt-vehicle-1", :vehicle, :smart, "Vehicle", 0.89, frame_2_id, 18, to_us - 420_000_000, :verified,
   :local_and_archived},
  {"evt-package-1", :package, :smart, "Package", 0.85, "88888888-8888-4888-8888-888888888883", 9, to_us - 720_000_000,
   :pending, :pending_archive},
  {"evt-animal-1", :animal, :smart, "Animal", 0.81, "88888888-8888-4888-8888-888888888884", 15, to_us - 1_020_000_000,
   :not_required, :local_only},
  {"evt-motion-1", :motion, :basic, "Motion", nil, "88888888-8888-4888-8888-888888888885", 24, to_us - 1_320_000_000,
   :verified, :local_and_archived},
  {"rec-seg-1", :recording, :basic, "Recording", nil, nil, 120, to_us - 1_560_000_000, :verified, :local_and_archived},
  {"rec-seg-2", :recording, :basic, "Recording", nil, nil, 120, to_us - 1_800_000_000, :not_required, :local_only},
  {"rec-seg-3", :recording, :basic, "Recording", nil, nil, 90, to_us - 2_040_000_000, :pending, :pending_archive},
  {"rec-seg-4", :recording, :basic, "Recording", nil, nil, 120, to_us - 2_280_000_000, :verified, :local_and_archived},
  {"rec-seg-5", :recording, :basic, "Recording", nil, nil, 60, to_us - 2_520_000_000, :not_required, :local_only},
  {"rec-seg-6", :recording, :basic, "Recording", nil, nil, 120, to_us - 2_760_000_000, :verified, :local_and_archived},
  {"rec-seg-7", :recording, :basic, "Recording", nil, nil, 120, to_us - 3_000_000_000, :verified, :local_and_archived}
]

event_clips =
  Enum.map(clip_specs, fn {id, cat, smart_type, label, conf, fid, dur, start_us, arch, copy} ->
    end_us = start_us + dur * 1_000_000

    %{
      id: id,
      camera_source_id: source_id,
      started_at: DateTime.from_unix!(start_us, :microsecond),
      ended_at: DateTime.from_unix!(end_us, :microsecond),
      start_us: start_us,
      end_us: end_us,
      peak_ts_us: start_us + div(dur * 1_000_000, 3),
      duration_seconds: dur,
      category: cat,
      smart_type: smart_type,
      label: label,
      confidence: conf,
      attributes: %{dominant_colors: [], frame_count: 1},
      visual_frame_id: fid,
      catalog_entry_id: "33333333-3333-4333-8333-333333333301",
      archive_state: arch,
      local_state: :present,
      copy_state: copy,
      thumbnail_url: nil
    }
  end)

event_markers =
  (event_clips
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
   end)) ++
    [
      %{
        id: "evt-offpage-person",
        category: :person,
        smart_type: :smart,
        label: "Person",
        confidence: 0.91,
        start_us: from_us + 240_000_000,
        end_us: from_us + 252_000_000,
        peak_ts_us: from_us + 245_000_000,
        visual_frame_id: frame_off_page_id
      }
    ]

switcher_cameras = [
  %{
    id: source_id,
    display_name: "Synthetic Entry Gate",
    vendor: "synthetic",
    vendor_camera_id: "cam-gate-01",
    availability_status: "online",
    metadata: %{"site" => "lab-north"}
  },
  %{
    id: "44444444-4444-4444-8444-444444444402",
    display_name: "Synthetic Loading Dock",
    vendor: "synthetic",
    vendor_camera_id: "cam-dock-02",
    availability_status: "online",
    metadata: %{"site" => "lab-north"}
  },
  %{
    id: "44444444-4444-4444-8444-444444444403",
    display_name: "Synthetic Courtyard West",
    vendor: "synthetic",
    vendor_camera_id: "cam-yard-03",
    availability_status: "online",
    metadata: %{"site" => "lab-west"}
  },
  %{
    id: "44444444-4444-4444-8444-444444444404",
    display_name: "Synthetic East Perimeter",
    vendor: "synthetic",
    vendor_camera_id: "cam-east-04",
    availability_status: "offline",
    metadata: %{"site" => "lab-east"}
  },
  %{
    id: "44444444-4444-4444-8444-444444444405",
    display_name: "Synthetic Lobby North",
    vendor: "synthetic",
    vendor_camera_id: "cam-lobby-05",
    availability_status: "online",
    metadata: %{"site" => "lab-south"}
  }
]

holds = [
  %{
    id: "55555555-5555-4555-8555-555555555501",
    state: :accepted,
    kind: :investigation,
    pinned_copy: :archive,
    reason: "Synthetic review hold H-101",
    start_us: from_us + 600_000_000,
    end_us: from_us + 1_200_000_000,
    archive_missing?: false,
    unavailable_blocks: [],
    release_reason: nil
  }
]

hold_form =
  Phoenix.Component.to_form(
    %{
      "kind" => "investigation",
      "start_at" => "2100-01-01T11:30:00",
      "end_at" => "2100-01-01T11:45:00",
      "reason" => ""
    },
    as: :hold
  )

assigns = %{
  __changed__: nil,
  source: %{
    id: source_id,
    device_uid: "sr:synthetic-timeline-camera",
    display_name: "Synthetic Entry Gate",
    vendor: "synthetic",
    availability_status: "online",
    metadata: %{"site" => "lab-north"}
  },
  items: [],
  next_cursor: nil,
  selected: nil,
  error: nil,
  loading: false,
  timezone: "Etc/UTC",
  can_view_recording_settings: true,
  mode: :timeline,
  can_manage_holds: true,
  stream_profiles: [%{id: profile_id, profile_name: "main-hd"}],
  timeline_profile_id: "",
  timeline_span: "1h",
  timeline_source: "auto",
  timeline_coverage: %{
    from_us: from_us,
    to_us: to_us,
    time_basis: "received",
    time_uncertainty: "unmeasured",
    scheduled_continuous?: true,
    continuous_recording_active?: true,
    buckets: buckets,
    blocks: blocks,
    gaps: [
      %{
        id: "gap-1",
        reason: :handover_overflow,
        detail_class: "buffer_full",
        start_us: from_us + 900_000_000,
        end_us: from_us + 915_000_000
      }
    ],
    reanchors: [%{at_us: from_us + 1_500_000_000, entry_id: "33333333-3333-4333-8333-333333333302"}]
  },
  archive_playback_available: false,
  timeline_playlist_path: "/api/cameras/#{source_id}/timeline/playlist.m3u8?from=#{from_us}&to=#{to_us}&source=local",
  timeline_play_from_us: from_us + 1_800_000_000,
  timeline_play_to_us: to_us,
  timeline_playlist_origin_us: from_us + 1_800_000_000,
  timeline_seek_offset_seconds: 0.0,
  timeline_highlight_frame_id: frame_1_id,
  timeline_search_query: "",
  timeline_search_object_class: "",
  timeline_search_results: [],
  timeline_search_executed?: false,
  timeline_search_error: nil,
  timeline_embedder_unavailable?: false,
  timeline_overlay_detections: [
    %{
      visual_frame_id: frame_1_id,
      offset_seconds: 0.5,
      time_basis: "received",
      object_class: "person",
      score: 0.94,
      bbox: [0.2, 0.15, 0.55, 0.85],
      highlighted: true
    }
  ],
  timeline_jump_at: "2100-01-01T11:30:00",
  timeline_has_adjacent_window: false,
  timeline_holds: holds,
  timeline_event_clips: event_clips,
  timeline_event_markers: event_markers,
  timeline_clips_mode: "all",
  timeline_clips_category: "all",
  timeline_clips_page: 1,
  timeline_clips_total_count: 30,
  timeline_clips_total_pages: 3,
  timeline_clips_counts: %{
    all: 30,
    smart: 8,
    basic: 22,
    person: 3,
    vehicle: 2,
    animal: 1,
    package: 2,
    motion: 2,
    recording: 20
  },
  timeline_selected_clip_id: "evt-person-1",
  timeline_manage_drawer_open?: false,
  switcher_cameras: switcher_cameras,
  switcher_search: "",
  switcher_page: 1,
  switcher_total_count: 42,
  switcher_total_pages: 3,
  switcher_open_mobile?: false,
  hold_form: hold_form
}

html = assigns |> RecordingsComponents.recordings() |> Phoenix.HTML.Safe.to_iodata()

File.write!(hd(System.argv()), [
  ~s(<!doctype html><html lang="en" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/app.css"><title>Camera timeline workspace</title></head><body class="bg-sr-canvas text-sr-ink antialiased">),
  html,
  "</body></html>"
])

Supervisor.stop(endpoint)
