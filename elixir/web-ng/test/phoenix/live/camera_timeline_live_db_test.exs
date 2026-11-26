defmodule ServiceRadarWebNGWeb.CameraTimelineLiveDBTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingControl.RecoveryGate
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @registered_storage_id "00000000-0000-4000-8000-000000000061"
  @provisional_storage_id "00000000-0000-4000-8000-000000000062"

  setup %{tmp_dir: directory} do
    open_synthetic_recovery_gate!(directory)
    actor = system_actor()
    insert_local_storage_binding(@registered_storage_id)

    {viewer, _} =
      user_with_permissions(["devices.view", "devices.cameras.recordings.view"], actor)

    {hold_operator, hold_profile} =
      user_with_permissions(
        [
          "devices.view",
          "devices.cameras.recordings.view",
          "devices.cameras.recordings.hold"
        ],
        actor
      )

    %{
      viewer: viewer,
      hold_operator: hold_operator,
      hold_profile: hold_profile,
      actor: actor
    }
  end

  test "disconnected mount performs zero camera/recording DB queries and loading state renders cleanly",
       %{viewer: viewer, actor: actor} do
    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-disc-#{Ecto.UUID.generate()}",
          vendor: "synthetic",
          vendor_camera_id: Ecto.UUID.generate(),
          display_name: "Synthetic Disconnected Camera"
        },
        actor: actor
      )

    handler_id = "camera-timeline-disconnected-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :repo, :query],
      fn _event, _measurements, metadata, _cfg ->
        query = Map.get(metadata, :query, "")

        if query =~ "camera_" do
          send(test_pid, {:unexpected_camera_query, query})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    resp =
      viewer
      |> authed_conn()
      |> get(~p"/cameras/#{source.id}/recordings?mode=timeline")

    html = html_response(resp, 200)
    assert html =~ "camera-recordings-loading"
    refute_received {:unexpected_camera_query, _}
  end

  test "opens timeline automatically when timeline data exists, renders all coverage copy states, time basis, reanchors, and advances adjacent playback windows",
       %{viewer: viewer, actor: actor} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_rich_timeline_camera(actor, now)
    conn = authed_conn(viewer)

    # Omitting ?mode= opens directly into Timeline because catalog/policy/gap data exists
    {:ok, view, html} = live(conn, ~p"/cameras/#{ctx.source.id}/recordings")

    assert has_element?(view, "#camera-timeline-view")
    assert has_element?(view, "#camera-timeline-time-basis", "Time basis: received (uncertainty: unmeasured)")
    assert has_element?(view, "#camera-timeline-provisional-badge", "provisional")
    assert has_element?(view, "#camera-timeline-reanchor-badge")
    assert has_element?(view, "#camera-timeline-reanchors")
    assert has_element?(view, "#camera-timeline-local-only-after-archive-note")
    assert html =~ "never counted as unarchived"

    # Verify all copy states appear on block badges and legend
    for copy_state <- [
          "local_and_archived",
          "archive_only",
          "pending_archive",
          "local_only",
          "local_only_after_archive",
          "deleted_by_retention"
        ] do
      assert has_element?(view, "#camera-timeline-blocks [data-copy-state='#{copy_state}']")
    end

    assert has_element?(view, "#camera-timeline-coverage-bar [data-bucket-state='not_scheduled']")
    assert has_element?(view, "#camera-timeline-gaps [data-gap-reason='handover_overflow']")
    assert has_element?(view, "#camera-timeline-gaps [data-gap-reason='quarantined']")
    refute html =~ ctx.quarantined_entry.id

    # Mode switcher toggles cleanly to Published and back to Timeline
    view |> element("#camera-recordings-mode-published") |> render_click()
    assert has_element?(view, "#camera-recordings-empty")
    refute has_element?(view, "#camera-timeline-view")

    view |> element("#camera-recordings-mode-timeline") |> render_click()
    assert has_element?(view, "#camera-timeline-view")

    # Source selector updates playlist query string (?source=local / ?source=archive)
    view |> element("#camera-timeline-source-local") |> render_click()
    local_html = render(view)
    assert local_html =~ "source=local"

    # Forcing the archive copy builds no playlist while no archive reader is
    # installed (D.2); the page says so instead of offering footage that cannot play.
    view |> element("#camera-timeline-source-archive") |> render_click()
    archive_html = render(view)
    refute archive_html =~ "source=archive"
    assert has_element?(view, "#camera-timeline-archive-only")

    view |> element("#camera-timeline-source-auto") |> render_click()
    assert player_playlist_path(view) =~ "source=local"
    refute player_playlist_path(view) =~ "source=auto"

    # Profile filter selects specific relay profile
    view
    |> element("#camera-timeline-profile-form")
    |> render_change(%{"stream_profile_id" => ctx.profile.id})

    assert render(view) =~ "profile=#{ctx.profile.id}"

    # Multi-hour span (6h) caps playlist window to <= 60m and marks has-adjacent-window="true",
    # then advance_timeline_window advances the playlist window forward!
    view |> element("#camera-timeline-span-6h") |> render_click()

    assert has_element?(
             view,
             "#camera-timeline-player[data-has-adjacent-window='true']"
           )

    before_path = player_playlist_path(view)
    assert is_binary(before_path) and before_path != ""

    render_hook(view, "advance_timeline_window", %{"window_end_us" => "0"})
    after_path = player_playlist_path(view)
    assert after_path != before_path
  end

  test "enforces devices.cameras.recordings.hold RBAC for placing and releasing holds, displays PD5 pinned copy and archive-missing fallback, and writes access audits",
       %{
         viewer: viewer,
         hold_operator: hold_operator,
         hold_profile: hold_profile,
         actor: actor
       } do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_rich_timeline_camera(actor, now)

    # 1. Read-only viewer cannot see hold form and direct event is rejected
    {:ok, viewer_lv, _} = live(authed_conn(viewer), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")
    refute has_element?(viewer_lv, "#place-timeline-hold-form")

    render_hook(viewer_lv, "place_timeline_hold", %{
      "hold" => %{
        "kind" => "investigation",
        "start_us" => Integer.to_string(ctx.archived_entry.timeline_start_us - 1_000_000),
        "end_us" => Integer.to_string(ctx.archived_entry.timeline_end_us + 1_000_000),
        "reason" => "Unauthorized hold attempt"
      }
    })

    assert has_element?(viewer_lv, "#camera-recordings-error", "permission")

    # 2. Hold operator places an investigation hold covering the verified archive block -> Pinned: archive
    {:ok, op_lv, _} =
      live(authed_conn(hold_operator), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")

    assert has_element?(op_lv, "#place-timeline-hold-form")

    hold_start = ctx.local_and_archived_entry.timeline_start_us - 500_000
    hold_end = ctx.local_and_archived_entry.timeline_end_us + 500_000

    op_lv
    |> element("#place-timeline-hold-form")
    |> render_submit(%{
      "hold" => %{
        "kind" => "investigation",
        "start_us" => Integer.to_string(hold_start),
        "end_us" => Integer.to_string(hold_end),
        "reason" => "Synthetic incident hold INC-404"
      }
    })

    {:ok, [hold]} = RecordingHolds.list_holds(ctx.source.id, actor: actor)
    assert hold.state == :accepted
    assert has_element?(op_lv, "#timeline-hold-#{hold.id}")
    assert has_element?(op_lv, "#timeline-hold-pin-#{hold.id}", "Pinned: archive")

    # Mark covered entry's archive copy :missing -> hold pin moves back to :local with warning!
    {:ok, _} =
      RecordingHolds.mark_archive_missing_and_fallback_pin(
        ctx.local_and_archived_entry.id,
        %{error_class: "head_404"},
        actor: actor
      )

    op_lv |> element("#camera-timeline-refresh") |> render_click()
    assert has_element?(op_lv, "#timeline-hold-pin-#{hold.id}", "Pinned: local")
    assert has_element?(op_lv, "#timeline-hold-archive-missing-#{hold.id}")

    # Release the hold via the release form
    op_lv
    |> element("#release-timeline-hold-form-#{hold.id}")
    |> render_submit(%{
      "hold_id" => hold.id,
      "release_reason" => "Investigation closed"
    })

    assert has_element?(op_lv, "#timeline-hold-#{hold.id}[data-hold-state='released']")

    # Verify both :hold_placed and :hold_released RecordingAccessAudit rows were recorded!
    {:ok, audits} = RecordingAccessAudit.list_for_hold(hold.id, actor: actor)
    assert Enum.map(audits, & &1.event_kind) == [:hold_placed, :hold_released]
    assert Enum.all?(audits, &(&1.actor_id == hold_operator.id))

    # 3. Revoking hold permission mid-session blocks subsequent hold placement on handle_event
    hold_profile
    |> Ash.Changeset.for_update(
      :update,
      %{permissions: ["devices.view", "devices.cameras.recordings.view"]},
      actor: actor,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.update!()

    Cache.put(
      hold_operator.id,
      MapSet.new([
        "devices.view",
        "devices.cameras.recordings.view",
        "devices.cameras.recordings.hold"
      ])
    )

    render_hook(op_lv, "place_timeline_hold", %{
      "hold" => %{
        "kind" => "export",
        "start_us" => Integer.to_string(hold_start),
        "end_us" => Integer.to_string(hold_end),
        "reason" => "Post-revocation attempt"
      }
    })

    assert has_element?(op_lv, "#camera-recordings-error", "permission")
  end

  test "timeline renders datetime-local hold inputs in user timezone, converts local time to UTC microseconds, supports presets & jump picker, and shows empty state when no blocks play",
       %{actor: actor} do
    now = ~U[2026-11-16 20:00:00Z]
    seeded = seed_rich_timeline_camera(actor, now)

    {chicago_op, _} =
      user_with_permissions(
        [
          "devices.view",
          "devices.cameras.recordings.view",
          "devices.cameras.recordings.hold",
          "settings.recording.view"
        ],
        actor
      )

    {:ok, _} =
      SQL.query(
        Repo,
        "UPDATE platform.ng_users SET timezone = 'America/Chicago' WHERE id = $1",
        [Ecto.UUID.dump!(chicago_op.id)]
      )

    chicago_op = %{chicago_op | timezone: "America/Chicago"}

    {:ok, lv, html} =
      live(authed_conn(chicago_op), ~p"/cameras/#{seeded.source.id}/recordings")

    # #261: datetime-local inputs & presets, zero raw microsecond prompts
    refute html =~ "Start (us UTC)"
    refute html =~ "End (us UTC)"
    assert has_element?(lv, "#timeline-hold-start-at[type='datetime-local']")
    assert has_element?(lv, "#timeline-hold-end-at[type='datetime-local']")
    assert has_element?(lv, "#camera-timeline-jump-at[type='datetime-local']")
    assert has_element?(lv, "#timeline-hold-preset-15m")

    lv |> element("#timeline-hold-preset-15m") |> render_click()

    # Submit hold using America/Chicago wall-clock time (2026-11-16 13:30:00 CST == 2026-11-16 19:30:00 UTC)
    lv
    |> form("#place-timeline-hold-form", %{
      "hold" => %{
        "kind" => "investigation",
        "start_at" => "2026-11-16T13:30:00",
        "end_at" => "2026-11-16T13:45:00",
        "reason" => "Chicago local datetime hold verification"
      }
    })
    |> render_submit()

    expected_start_us = DateTime.to_unix(~U[2026-11-16 19:30:00Z], :microsecond)
    expected_end_us = DateTime.to_unix(~U[2026-11-16 19:45:00Z], :microsecond)

    {:ok, holds} =
      RecordingHolds.list_holds(seeded.source.id, actor: actor)

    placed = Enum.find(holds, &(&1.reason == "Chicago local datetime hold verification"))
    assert placed
    assert placed.start_us == expected_start_us
    assert placed.end_us == expected_end_us

    # Jump to an earlier empty window (2026-11-15T06:00:00 CST) -> #262 empty state renders instead of blank video
    lv
    |> form("#camera-timeline-jump-form", %{"jump_at" => "2026-11-15T06:00:00"})
    |> render_submit()

    assert has_element?(
             lv,
             "#camera-timeline-empty-state",
             "No playable footage in selected window"
           )

    assert has_element?(lv, "#camera-timeline-player.hidden")
  end

  test "auto mode requests source=local in mixed local and archive-only windows until an archive reader is installed",
       %{viewer: viewer, actor: actor} do
    previous_readers = Application.get_env(:serviceradar_web_ng, :camera_timeline_readers)

    on_exit(fn ->
      if is_nil(previous_readers) do
        Application.delete_env(:serviceradar_web_ng, :camera_timeline_readers)
      else
        Application.put_env(:serviceradar_web_ng, :camera_timeline_readers, previous_readers)
      end
    end)

    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_rich_timeline_camera(actor, now)

    Application.put_env(:serviceradar_web_ng, :camera_timeline_readers, [])

    {:ok, view, _html} = live(authed_conn(viewer), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")

    assert has_element?(view, "#camera-timeline-blocks [data-copy-state='archive_only']")
    assert has_element?(view, "#camera-timeline-blocks [data-copy-state='local_and_archived']")

    mixed_local_path = player_playlist_path(view)
    assert playlist_query_source(mixed_local_path) == "local"

    mixed_local_playlist = viewer |> authed_conn() |> get(mixed_local_path) |> response(200)
    assert mixed_local_playlist =~ ctx.local_and_archived_entry.id
    refute mixed_local_playlist =~ ctx.archived_entry.id

    archive_from = ctx.archived_entry.timeline_start_us - 1_000_000
    archive_to = ctx.archived_entry.timeline_end_us + 1_000_000

    {:ok, archive_only_view, _html} =
      live(
        authed_conn(viewer),
        ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline&from=#{archive_from}&to=#{archive_to}"
      )

    assert player_playlist_path(archive_only_view) == ""
    assert has_element?(archive_only_view, "#camera-timeline-archive-only")

    archive_reader = fn _plan, _deadline -> {:ok, <<>>} end
    Application.put_env(:serviceradar_web_ng, :camera_timeline_readers, archive: archive_reader)

    view |> element("#camera-timeline-refresh") |> render_click()

    mixed_auto_path = player_playlist_path(view)
    assert playlist_query_source(mixed_auto_path) == "auto"

    mixed_auto_playlist = viewer |> authed_conn() |> get(mixed_auto_path) |> response(200)
    assert mixed_auto_playlist =~ ctx.local_and_archived_entry.id
    assert mixed_auto_playlist =~ ctx.archived_entry.id

    view |> element("#camera-timeline-source-archive") |> render_click()
    assert playlist_query_source(player_playlist_path(view)) == "archive"
    refute has_element?(view, "#camera-timeline-archive-only")

    view |> element("#camera-timeline-source-local") |> render_click()
    assert playlist_query_source(player_playlist_path(view)) == "local"

    archive_only_view |> element("#camera-timeline-refresh") |> render_click()
    assert playlist_query_source(player_playlist_path(archive_only_view)) == "auto"
    refute has_element?(archive_only_view, "#camera-timeline-archive-only")
  end

  test "without a detection provider the event clip strip lists recorded fallback cards that open clip playback",
       %{viewer: viewer, actor: actor} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_rich_timeline_camera(actor, now)
    entry = ctx.local_and_archived_entry
    rec_clip_id = "rec-#{entry.id}"

    {:ok, view, _html} = live(authed_conn(viewer), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")

    assert has_element?(view, "#camera-timeline-event-clips-section")
    view |> element("#camera-clips-mode-all") |> render_click()
    assert has_element?(view, "#camera-clip-card-#{rec_clip_id}")
    refute has_element?(view, "#camera-clips-grid [data-clip-smart-type='smart']")

    # Smart detections come only from the Vantage addon, so the Smart view is empty here
    view |> element("#camera-clips-mode-smart") |> render_click()
    refute has_element?(view, "#camera-clips-grid [data-clip-category='recording']")

    view |> element("#camera-clips-mode-all") |> render_click()
    view |> element("#camera-clip-card-#{rec_clip_id}") |> render_click()
    assert has_element?(view, "#camera-clip-card-#{rec_clip_id}[aria-pressed='true']")
    assert has_element?(view, "#camera-clip-playback-modal")
    assert is_binary(player_playlist_path(view))
  end

  test "window detection overlays come from the Vantage provider and are absent without it",
       %{viewer: viewer, actor: actor} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    ctx = seed_rich_timeline_camera(actor, now)
    entry = ctx.local_and_archived_entry
    frame_id = Ecto.UUID.generate()
    source_id = to_string(ctx.source.id)
    test_pid = self()

    previous_enabled = Application.get_env(:serviceradar_web_ng, :vantage_rpc_enabled)
    previous_request_fn = Application.get_env(:serviceradar_web_ng, :vantage_rpc_request_fn)

    on_exit(fn ->
      restore_web_env(:vantage_rpc_enabled, previous_enabled)
      restore_web_env(:vantage_rpc_request_fn, previous_request_fn)
    end)

    # Without the provider: no overlays
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, false)
    {:ok, off_view, _html} = live(authed_conn(viewer), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")
    assert player_overlay_detections(off_view) == []

    # With the provider: the window request carries only the authorized camera
    Application.put_env(:serviceradar_web_ng, :vantage_rpc_enabled, true)

    Application.put_env(:serviceradar_web_ng, :vantage_rpc_request_fn, fn
      "vantage.rpc.frame_overlay.v1", json, _opts ->
        request = Jason.decode!(json)
        send(test_pid, {:window_overlay_request, request})

        {:ok,
         %{
           body:
             Jason.encode!(%{
               "status" => "ok",
               "camera_source_id" => request["camera_source_id"],
               "detections" => [
                 %{
                   "visual_frame_id" => frame_id,
                   "timeline_ts_us" => entry.timeline_start_us + 1_000_000,
                   "start_us" => entry.timeline_start_us,
                   "end_us" => entry.timeline_start_us + 2_500_000,
                   "bbox" => [0.1, 0.1, 0.4, 0.8],
                   "object_class" => "person",
                   "score" => 0.92,
                   "dominant_colors" => ["navy"],
                   "time_basis" => "received"
                 }
               ]
             })
         }}

      _subject, _json, _opts ->
        {:error, :no_responders}
    end)

    {:ok, view, _html} = live(authed_conn(viewer), ~p"/cameras/#{ctx.source.id}/recordings?mode=timeline")

    assert_receive {:window_overlay_request, request}
    assert request["camera_source_id"] == source_id
    assert is_integer(request["from_us"]) and request["to_us"] > request["from_us"]

    assert [%{"visual_frame_id" => ^frame_id, "object_class" => "person"}] = player_overlay_detections(view)
  end

  defp restore_web_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_web_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp player_overlay_detections(view, selector \\ "#camera-timeline-player") do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-overlay-detections")
    |> List.first()
    |> case do
      json when is_binary(json) and json != "" -> Jason.decode!(json)
      _ -> []
    end
  end

  defp player_playlist_path(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#camera-timeline-player")
    |> LazyHTML.attribute("data-playlist-path")
    |> List.first()
  end

  defp playlist_query_source(path) do
    path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.get("source")
  end

  defp authed_conn(user), do: log_in_user(build_conn(), user)

  defp seed_rich_timeline_camera(actor, now) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "tl-live-dest-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-tl-live-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-tl-live-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Timeline Live Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-hd",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, _policy} =
      CameraRecordingPolicy
      |> Ash.Changeset.for_create(
        :create,
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          mode: :continuous,
          nvr_member: "serviceradar-nvr-0"
        },
        opts
      )
      |> Ash.create(opts)

    # First enable archiving so archived/pending/reaped blocks record binding.id
    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{active_archive_binding_id: binding.id, archive_enabled: true},
        opts
      )

    {:ok, sub_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "sub-provisional",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    live_reg =
      open_claim_for_storage(source, profile, @registered_storage_id, "live-reg-#{key}", opts)

    live_prov =
      open_claim_for_storage(
        source,
        sub_profile,
        @provisional_storage_id,
        "live-prov-#{key}",
        opts
      )

    # 0. Earlier block at now - 95m so 6h span starts at -95m (has_adjacent_window = true)
    #    while default 1h span ([now - 60m, now)) covers all t0 = -35m blocks below.
    {b_early, e_early} = freeze_block(live_reg, 0, DateTime.shift(now, minute: -95), false, opts)
    r_early = record_receipt(binding, b_early, @registered_storage_id, actor)

    _e_early =
      e_early
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: r_early.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)

    # Place blocks inside the last 40 minutes so default 1h span covers all of them
    t0 = DateTime.shift(now, minute: -35)

    # 1. local_and_archived (t0)
    {b_la, e_la} = freeze_block(live_reg, 1, t0, false, opts)
    r_la = record_receipt(binding, b_la, @registered_storage_id, actor)

    e_la =
      e_la
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: r_la.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)

    # 2. archive_only (reclaimed locally, verified in archive, reanchored: true without gap! t0 + 3m)
    {b_ao, e_ao} = freeze_block(live_reg, 2, DateTime.shift(t0, minute: 3), true, opts)
    r_ao = record_receipt(binding, b_ao, @registered_storage_id, actor)

    e_ao =
      e_ao
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: r_ao.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)
      |> Ash.Changeset.for_update(
        :transition_local_state,
        %{local_state: :reclaimed, local_state_at: now},
        opts
      )
      |> Ash.update!(opts)

    # 3. pending_archive on provisional storage (t0 + 6m)
    {_b_pa, _e_pa} = freeze_block(live_prov, 0, DateTime.shift(t0, minute: 6), false, opts)

    # 4. local_only_after_archive (local present, archive deleted by object_retention, t0 + 9m)
    {_b_loaa, e_loaa} = freeze_block(live_reg, 3, DateTime.shift(t0, minute: 9), false, opts)

    _e_loaa =
      e_loaa
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :deleted,
          archive_state_at: now,
          archive_deleted_reason: :object_retention
        },
        opts
      )
      |> Ash.update!(opts)

    # 5. deleted_by_retention (local reclaimed, archive deleted, t0 + 12m)
    {_b_del, e_del} = freeze_block(live_reg, 4, DateTime.shift(t0, minute: 12), false, opts)

    _e_del =
      e_del
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :deleted,
          archive_state_at: now,
          archive_deleted_reason: :object_retention
        },
        opts
      )
      |> Ash.update!(opts)
      |> Ash.Changeset.for_update(
        :transition_local_state,
        %{local_state: :reclaimed, local_state_at: now},
        opts
      )
      |> Ash.update!(opts)

    # 6. Turn archiving off -> newly sealed block has archive_state = :not_required
    #    and archive_binding_id = nil -> local_only! (t0 + 15m)
    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{active_archive_binding_id: nil, archive_enabled: false},
        opts
      )

    {_b_lo, _e_lo} = freeze_block(live_reg, 5, DateTime.shift(t0, minute: 15), false, opts)

    # 7. Recorded gap (handover_overflow at t0 + 18m) + quarantined entry & quarantined gap (t0 + 21m)
    gap_start_us = DateTime.to_unix(DateTime.shift(t0, minute: 18), :microsecond)

    RecordingGap.record(
      %{
        camera_source_id: source.id,
        stream_profile_id: profile.id,
        storage_id: @registered_storage_id,
        start_us: gap_start_us,
        end_us: gap_start_us + 15_000_000,
        time_basis: :received,
        reason: :handover_overflow
      },
      opts
    )

    q_start_us = DateTime.to_unix(DateTime.shift(t0, minute: 21), :microsecond)
    q_key = sha256_hex("synth-live-quarantine-#{key}")

    {:ok, q_entry} =
      RecordingCatalogEntry.register_quarantined(
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          storage_id: @registered_storage_id,
          block_key: q_key,
          timeline_start_us: q_start_us,
          timeline_end_us: q_start_us + 10_000_000,
          media_start_ns: 0,
          media_end_ns: 10_000_000_000,
          time_basis: :received,
          quarantine_reason: :unattributable,
          quarantine_receipt: %{"partition" => "_quarantine/#{q_key}"},
          quarantined_bytes: 2_048,
          archive_state: :not_required
        },
        opts
      )

    RecordingGap.record(
      %{
        camera_source_id: source.id,
        stream_profile_id: profile.id,
        storage_id: @registered_storage_id,
        start_us: q_start_us,
        end_us: q_start_us + 10_000_000,
        time_basis: :received,
        reason: :quarantined
      },
      opts
    )

    %{
      source: source,
      profile: profile,
      local_and_archived_entry: e_la,
      archived_entry: e_ao,
      quarantined_entry: q_entry
    }
  end

  defp freeze_block(live_ctx, seq, received_at, reanchored?, opts) do
    clock = %{
      "clock_epoch" => "epoch-live-tl-1",
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    attrs = %{
      camera_source_id: live_ctx.owner.camera_source_id,
      stream_profile_id: live_ctx.owner.stream_profile_id,
      ingest_owner_id: live_ctx.owner.id,
      ingest_epoch: live_ctx.owner.epoch,
      recorder_claim_id: live_ctx.claim.id,
      recorder_epoch: live_ctx.claim.recorder_epoch,
      block_sequence: seq,
      relay_session_id: live_ctx.claim.relay_session_id,
      media_ingest_id: live_ctx.claim.media_ingest_id,
      storage_id: live_ctx.claim.storage_id,
      clock: clock
    }

    identity = RecordingBlock.identity(attrs)

    block =
      RecordingBlock
      |> Ash.Changeset.for_create(
        :reserve,
        Map.put(attrs, :block_key, Descriptor.block_key(identity)),
        opts
      )
      |> Ash.create!(opts)

    init_sha = sha256_hex("live-init-#{block.id}")
    frag_sha = sha256_hex("live-frag-#{block.id}")

    desc = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{"length" => 256, "sha256" => init_sha},
      "media" => %{"length" => 4_096, "sha256" => frag_sha},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 4_096,
          "start_ns" => seq * 10_000_000_000,
          "duration_ns" => 10_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block,
        desc,
        %{
          first_unit_pts: seq * 900_000,
          first_unit_received_at: received_at,
          reanchored: reanchored?,
          contiguous_with_previous: seq > 0
        },
        opts
      )

    {block, entry}
  end

  defp record_receipt(binding, block, storage_id, actor) do
    init_sha = sha256_hex("live-init-#{block.id}")
    frag_sha = sha256_hex("live-frag-#{block.id}")

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => storage_id,
        "block_key" => block.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond),
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "#{binding.namespace}/#{storage_id}/#{block.block_key}/init.mp4",
            "length" => 256,
            "sha256" => init_sha,
            "etag" => "\"etag-i-#{block.id}\"",
            "version_id" => "v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{storage_id}/#{block.block_key}/media.m4s",
            "length" => 4_096,
            "sha256" => frag_sha,
            "etag" => "\"etag-m-#{block.id}\"",
            "version_id" => "v1"
          }
        ]
      })

    {:ok, receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: block.id},
        actor: actor
      )

    receipt
  end

  defp open_claim_for_storage(source, profile, storage_id, tag, opts) do
    actor = opts[:actor]

    {:ok, session} =
      RelaySessionManager.request_open(source.id, profile.id,
        actor: actor,
        control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
        dispatch_open: fn _agent, _payload, open_opts, _requester ->
          {:ok, open_opts[:command_id]}
        end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      RelaySessionLifecycle.activate_session(session.id, "synth-live-#{tag}", assignment, opts)

    {:ok, owner} = IngestOwnership.for_relay(session.id, opts)
    claim_token = Ecto.UUID.generate()
    {:ok, consumer} = IngestOwnership.acquire_consumer(owner, :recorder, claim_token, 60_000, opts)

    initial_claim =
      case RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id)
           |> Ash.read_one!(opts) do
        nil ->
          RecorderClaim
          |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
          |> Ash.create!(opts)

        existing ->
          existing
      end

    claim =
      initial_claim
      |> Ash.Changeset.for_update(
        :transition,
        %{
          claim_token: claim_token,
          ingest_epoch: owner.epoch,
          recorder_epoch: initial_claim.recorder_epoch + 1,
          next_block_sequence: 10,
          relay_session_id: owner.relay_session_id,
          media_ingest_id: session.media_ingest_id,
          storage_id: storage_id,
          consumer_id: consumer.id,
          lease_expires_at: consumer.expires_at,
          state: :active
        },
        opts
      )
      |> Ash.update!(opts)

    %{owner: owner, claim: claim}
  end

  defp insert_local_storage_binding(storage_id) do
    now = DateTime.utc_now()

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_local_storage_bindings (
        id, schema_version, storage_id, generation, provider_resource_ref,
        profile_sha256, binding_sha256, provisioned_by, inserted_at
      ) VALUES ($1, 1, $2, 1, $3, $4, $5, 'synthetic-provisioner', $6)
      ON CONFLICT DO NOTHING
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(storage_id),
        "pvc://synthetic-nvr-live-0",
        sha256_hex("synth-profile-#{storage_id}"),
        sha256_hex("synth-binding-#{storage_id}"),
        now
      ]
    )
  end

  defp user_with_permissions(permissions, actor) do
    user = user_fixture()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Synthetic timeline live #{Ecto.UUID.generate()}", permissions: permissions},
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    user =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: actor)
      |> Ash.update!()

    Cache.put(user.id, MapSet.new(permissions))
    on_exit(fn -> Cache.invalidate(user.id) end)
    {user, profile}
  end

  defp open_synthetic_recovery_gate!(tmp_dir) do
    prior = Application.fetch_env(:serviceradar_core, :nvr_recovery_gate)
    path = Path.join(tmp_dir, "recovery.json")
    generation = Ecto.UUID.generate()
    File.write!(path, ~s({"generation":"#{generation}","state":"ready"}))

    {:ok, gate} =
      RecoveryGate.load(
        %{
          "SERVICERADAR_NVR_RECOVERY_GENERATION" => generation,
          "SERVICERADAR_NVR_RECOVERY_STATE_FILE" => Path.expand(path)
        },
        nil
      )

    Application.put_env(:serviceradar_core, :nvr_recovery_gate, gate)

    on_exit(fn ->
      case prior do
        {:ok, val} -> Application.put_env(:serviceradar_core, :nvr_recovery_gate, val)
        :error -> Application.delete_env(:serviceradar_core, :nvr_recovery_gate)
      end
    end)
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
