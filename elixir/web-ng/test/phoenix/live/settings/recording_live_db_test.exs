defmodule ServiceRadarWebNGWeb.Settings.RecordingLiveDBTest do
  @moduledoc """
  Database-backed LiveView regression coverage for `/settings/recording`
  exercising `ServiceRadarWebNG.CameraRecordingSettings` against real Ash and
  Postgres queries without `recording_deps` stubs.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadarRecordingMetadata.Descriptor
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.CameraRecordingSettings

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @storage_id "00000000-0000-4000-8000-000000000041"

  defmodule EnabledRuntimeSupervisorStub do
    @moduledoc false
    def enabled?, do: true
  end

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    actor = system_actor()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: Scope.for_user(user),
      actor: actor
    }
  end

  test "selecting a camera source and stream profile loads relay-eligible profiles, receipts, and paged blocks without stubs",
       %{conn: conn, scope: scope, actor: actor} do
    fixture = create_camera_with_profiles_and_blocks(actor, 26)

    assert [returned_profile] =
             CameraRecordingSettings.list_relay_profiles(scope, fixture.source.id)

    assert returned_profile.id == fixture.eligible_profile.id

    {:ok, view, _html} = live(conn, ~p"/settings/recording?tab=cameras")

    assert has_element?(view, "#recording-camera-picker-form")

    assert has_element?(
             view,
             "#recording-camera-select option[value='#{fixture.source.id}']"
           )

    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => fixture.source.id})

    assert has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.eligible_profile.id}']"
           )

    refute has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.ineligible_profile.id}']"
           )

    assert has_element?(view, "#camera-recording-blocks-section")
    assert has_element?(view, "#next-camera-blocks-page")
    assert has_element?(view, "#block-inserted-#{fixture.receipt_block_id}")
    assert render(view) =~ "version synth-ver-db-01"

    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{
      "camera_source_id" => fixture.source.id,
      "stream_profile_id" => fixture.eligible_profile.id
    })

    assert has_element?(
             view,
             "#recording-profile-select option[value='#{fixture.eligible_profile.id}'][selected]"
           )

    view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => fixture.source.id, "stream_profile_id" => ""})

    assert has_element?(view, "#next-camera-blocks-page")

    view
    |> element("#next-camera-blocks-page")
    |> render_click()

    refute has_element?(view, "#next-camera-blocks-page")
    assert has_element?(view, "#block-inserted-#{fixture.oldest_block_id}")
  end

  test "archive and retention tabs persist E1 retention settings, retention delete credential, and render real CNPG usage and calculated holds figures end-to-end",
       %{conn: conn, user: user, scope: scope, actor: actor} do
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Archive Writer")
    retention_secret = create_synthetic_s3_secret(actor, "Synthetic Archive Retention")
    slug = "synthetic-#{System.unique_integer([:positive])}"

    {:ok, view, html} = live(conn, ~p"/settings/recording?tab=archive")

    assert has_element?(view, "#register-archive-destination-form")
    assert html =~ "Local only: no object storage configured"

    view
    |> element("#register-archive-destination-form")
    |> render_submit(%{
      "destination" => %{
        "name" => slug,
        "endpoint" => "https://objects.example.com",
        "region" => "example-1",
        "bucket" => "synthetic-archive",
        "namespace" => "recordings/v1"
      }
    })

    bindings = CameraRecordingSettings.list_archive_bindings(scope)
    binding = Enum.find(bindings, &(&1.provisioning_ref == "operator:#{slug}"))
    assert binding
    assert binding.generation == 1
    assert has_element?(view, "#archive-binding-#{binding.id}")

    # Save with writer credential only first: object retention must report unenforced
    view
    |> element("#recording-archive-settings-form")
    |> render_submit(%{
      "settings" => %{
        "active_archive_binding_id" => binding.id,
        "archive_enabled" => "true",
        "writer_credential_secret_id" => writer_secret.id,
        "reader_credential_secret_id" => "",
        "retention_credential_secret_id" => ""
      }
    })

    assert has_element?(view, "#archive-retention-unenforced-notice")
    assert render(view) =~ "Object retention not enforced: no delete credential"

    {:ok, retention_unenforced_view, retention_unenforced_html} =
      live(conn, ~p"/settings/recording?tab=retention")

    assert has_element?(retention_unenforced_view, "#recording-tab-panel-retention")
    refute has_element?(retention_unenforced_view, "#recording-retention-blocked-panel")
    assert retention_unenforced_html =~ "Object retention not enforced: no delete credential"

    # Now bind the retention delete credential on the Archive tab
    view
    |> element("#recording-archive-settings-form")
    |> render_submit(%{
      "settings" => %{
        "active_archive_binding_id" => binding.id,
        "archive_enabled" => "true",
        "writer_credential_secret_id" => writer_secret.id,
        "reader_credential_secret_id" => "",
        "retention_credential_secret_id" => retention_secret.id
      }
    })

    overview = CameraRecordingSettings.load_archive_settings_view(scope)
    assert overview.storage_mode == :local_and_archive
    assert overview.active_binding_id == binding.id
    assert overview.form["archive_enabled"] == "true"
    assert overview.selected_writer_label == writer_secret.name
    assert overview.selected_retention_label == retention_secret.name
    assert overview.object_retention_enforced? == true
    refute has_element?(view, "#archive-local-only-banner")
    refute has_element?(view, "#archive-retention-unenforced-notice")

    # Seed real recent RecordingBlocks and NVRArchiveReceipts spanning > 24h on the active binding
    seed_recent_blocks_and_receipts(actor, binding)

    {:ok, ret_view, ret_html} = live(conn, ~p"/settings/recording?tab=retention")

    refute has_element?(ret_view, "#retention-unenforced-banner")
    assert ret_html =~ "200 MiB"
    assert ret_html =~ "2 blocks (2 objects)"
    assert ret_html =~ "24h: 100 MiB/day"
    assert ret_html =~ "Object archive holds about 30 days"
    assert ret_html =~ "configured 30 days, effective about 30 days (time binds)"
    assert ret_html =~ "Local storage holds about"
    assert ret_html =~ "at the current rate"

    # Pre-save phx-change what-if with a 1 GiB (1,073,741,824 B) object budget:
    # 80% low water = 858,993,459 B / 104,857,600 B/day = ~8.2 days (capacity binds)
    changed_html =
      ret_view
      |> element("#recording-retention-settings-form")
      |> render_change(%{
        "retention" => %{
          "object_budget_mode" => "limited",
          "object_budget_bytes" => "1073741824",
          "object_high_water_percent" => "90",
          "object_low_water_percent" => "80",
          "object_capacity_policy" => "reap_oldest"
        }
      })

    assert changed_html =~ "Object archive holds about 8.2 days"
    assert changed_html =~ "configured 30 days, effective about 8.2 days (capacity binds)"

    # Persist E1 retention settings with explicit confirmations for overwrite_oldest and reap_oldest
    saved_html =
      ret_view
      |> element("#recording-retention-settings-form")
      |> render_submit(%{
        "retention" => %{
          "local_high_water_percent" => "85",
          "local_low_water_percent" => "75",
          "max_local_age_mode" => "limited",
          "max_local_age_seconds" => "172800",
          "local_window_alert_mode" => "enabled",
          "local_window_alert_seconds" => "1800",
          "local_only_full_policy" => "overwrite_oldest",
          "confirm_local_only_overwrite" => "true",
          "local_only_target_mode" => "target",
          "local_only_retention_target_seconds" => "604800",
          "local_only_max_age_mode" => "limited",
          "local_only_max_age_seconds" => "259200",
          "archive_retention_mode" => "limited",
          "archive_retention_days" => "30",
          "object_budget_mode" => "limited",
          "object_budget_bytes" => "1073741824",
          "object_high_water_percent" => "90",
          "object_low_water_percent" => "80",
          "object_capacity_policy" => "reap_oldest",
          "confirm_reap_oldest" => "true"
        }
      })

    assert saved_html =~ "Confirmed: overwrite_oldest"
    assert saved_html =~ "Confirmed: reap_oldest"
    assert saved_html =~ "configured 30 days, effective about 8.2 days (capacity binds)"

    {:ok, persisted} = RecordingArchiveSettings.get_settings(actor: actor)
    assert persisted.retention_credential_secret_id == retention_secret.id
    assert persisted.local_high_water_percent == 85
    assert persisted.local_low_water_percent == 75
    assert persisted.max_local_age_seconds == 172_800
    assert persisted.local_window_alert_seconds == 1_800
    assert persisted.local_only_full_policy == :overwrite_oldest
    assert persisted.local_only_full_policy_confirmed_by_id == to_string(user.id)
    assert %DateTime{} = persisted.local_only_full_policy_confirmed_at
    assert persisted.local_only_max_age_mode == :limited
    assert persisted.local_only_max_age_seconds == 259_200
    assert persisted.object_budget_mode == :limited
    assert persisted.object_budget_bytes == 1_073_741_824
    assert persisted.object_capacity_policy == :reap_oldest
    assert persisted.object_capacity_policy_confirmed_by_id == to_string(user.id)
    assert %DateTime{} = persisted.object_capacity_policy_confirmed_at
  end

  @tag :tmp_dir
  test "freeze_and_catalog and RecordingHolds surface real catalog copy states, PD5 hold-pin badges, and held/non-reapable bytes across ?tab=cameras and ?tab=retention",
       %{conn: conn, scope: scope, actor: actor, tmp_dir: tmp_dir} do
    open_synthetic_recovery_gate!(tmp_dir)
    opts = [actor: actor]
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Stage B Writer")
    retention_secret = create_synthetic_s3_secret(actor, "Synthetic Stage B Retention")
    slug_same_1 = "same-v1-#{System.unique_integer([:positive])}"
    slug_same_2 = "same-v2-#{System.unique_integer([:positive])}"
    slug_other = "other-bkt-#{System.unique_integer([:positive])}"

    {:ok, binding_gen1} =
      ArchiveDestinations.register_operator(
        %{
          name: slug_same_1,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-shared-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, binding_gen2} =
      ArchiveDestinations.register_operator(
        %{
          name: slug_same_2,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-shared-archive",
          namespace: "recordings/v2"
        },
        opts
      )

    {:ok, binding_other} =
      ArchiveDestinations.register_operator(
        %{
          name: slug_other,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-other-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    # Activate binding_gen1 first so block_verified is registered under binding_gen1
    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding_gen1.id,
          archive_enabled: true,
          writer_credential_secret_id: writer_secret.id,
          retention_credential_secret_id: retention_secret.id
        },
        opts
      )

    live_ctx = setup_live_recorder_fence(actor)

    block_verified = reserve_fenced_block(live_ctx, 0, opts)
    block_pending = reserve_fenced_block(live_ctx, 1, opts)
    block_uncataloged = reserve_fenced_block(live_ctx, 2, opts)
    block_other_bucket = reserve_fenced_block(live_ctx, 3, opts)

    descriptor_verified = build_synthetic_descriptor(block_verified, 33_554_432)

    {:ok, entry_verified} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_verified,
        descriptor_verified,
        %{
          first_unit_pts: 0,
          first_unit_received_at: ~U[2026-11-16 11:50:00.000000Z],
          reanchored: false
        },
        opts
      )

    assert entry_verified.archive_state == :pending
    assert entry_verified.archive_binding_id == binding_gen1.id
    assert entry_verified.local_state == :present
    assert entry_verified.time_basis == :received
    assert is_nil(entry_verified.time_uncertainty_us)

    receipt_verified =
      record_synthetic_receipt(
        binding_gen1,
        block_verified,
        33_554_432,
        "synth-stageb-ver-01",
        actor
      )

    now = DateTime.utc_now()

    {:ok, _entry_verified} =
      entry_verified
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          nvr_archive_receipt_id: receipt_verified.id,
          archived_at: now
        },
        opts
      )
      |> Ash.update(opts)

    # Rotate active binding to binding_gen2 on the SAME {endpoint, bucket} with a different prefix
    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding_gen2.id,
          archive_enabled: true
        },
        opts
      )

    descriptor_pending = build_synthetic_descriptor(block_pending, 16_777_216)

    {:ok, entry_pending} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_pending,
        descriptor_pending,
        %{
          first_unit_pts: 90_000,
          first_unit_received_at: ~U[2026-11-16 12:00:00.000000Z],
          reanchored: true
        },
        opts
      )

    assert entry_pending.archive_state == :pending
    assert entry_pending.archive_binding_id == binding_gen2.id
    assert entry_pending.reanchored == true

    # Also record a retained receipt on a DIFFERENT bucket (excluded from active budget)
    _receipt_other =
      record_synthetic_receipt(
        binding_other,
        block_other_bucket,
        67_108_864,
        "synth-other-bkt-ver-01",
        actor
      )

    # 1. Verify ?tab=cameras renders cataloged states + received time basis alongside uncataloged open_local
    {:ok, cam_view, _cam_html} = live(conn, ~p"/settings/recording?tab=cameras")

    cam_html =
      cam_view
      |> element("#recording-camera-picker-form")
      |> render_change(%{"camera_source_id" => live_ctx.source.id})

    assert has_element?(cam_view, "#block-timeline-start-#{block_verified.id}")
    assert has_element?(cam_view, "#block-timeline-start-#{block_pending.id}")
    refute has_element?(cam_view, "#block-timeline-start-#{block_uncataloged.id}")

    assert cam_html =~ "Cataloged · Sealed"
    assert cam_html =~ "present (provisional)"
    assert cam_html =~ "verified"
    assert cam_html =~ "version synth-stageb-ver-01"
    assert cam_html =~ "pending"
    assert cam_html =~ "received"
    assert cam_html =~ "time re-anchored"
    assert cam_html =~ "Uncertainty: unmeasured"
    assert cam_html =~ "Core reservation"
    assert cam_html =~ "Unknown (NVR lookup unavailable)"
    assert cam_html =~ "Not cataloged"
    refute String.downcase(cam_html) =~ "capture time"
    refute String.downcase(cam_html) =~ "absent"

    # 2. Verify ?tab=retention aggregates gen1 (32 MiB) + gen2 (16 MiB) = 48 MiB on same bucket
    #    and reports binding_other (64 MiB) separately as a non-blocking info line
    {:ok, ret_view, ret_html} = live(conn, ~p"/settings/recording?tab=retention")

    assert has_element?(ret_view, "#retention-same-bucket-scope")
    assert has_element?(ret_view, "#retention-other-buckets-info")
    assert ret_html =~ "48 MiB"
    assert ret_html =~ "+16 MiB in flight (1 uploads)"
    assert ret_html =~ "Counts all"
    assert ret_html =~ "2 retained bindings"
    assert ret_html =~ "synthetic-shared-archive"
    assert ret_html =~ "64 MiB"
    assert ret_html =~ "synthetic-other-archive"
    assert ret_html =~ "excluded from active budget"
    assert has_element?(ret_view, "#retention-active-holds-count", "Active holds: 0")

    # 3. Place real RecordingHolds over entry_verified (PD5 :archive pin, 32 MiB) and
    #    entry_pending (PD5 :local pin, 16 MiB) under admin Scope against Postgres
    {:ok, hold_archive} =
      RecordingHolds.place_hold(
        %{
          camera_source_id: live_ctx.source.id,
          stream_profile_id: live_ctx.profile.id,
          start_us: entry_verified.timeline_start_us,
          end_us: entry_verified.timeline_end_us,
          kind: :investigation,
          reason: "Synthetic DB investigation hold on archive-verified block"
        },
        scope: scope
      )

    assert hold_archive.state == :accepted
    assert hold_archive.unavailable_blocks == []

    {:ok, hold_local} =
      RecordingHolds.place_hold(
        %{
          camera_source_id: live_ctx.source.id,
          stream_profile_id: live_ctx.profile.id,
          start_us: entry_pending.timeline_start_us,
          end_us: entry_pending.timeline_end_us,
          kind: :export,
          reason: "Synthetic DB export hold on unarchived block"
        },
        scope: scope
      )

    assert hold_local.state == :accepted
    assert hold_local.unavailable_blocks == []

    # Verify ?tab=cameras renders exact PD5 hold-pin badges for cataloged rows and omits uncataloged
    {:ok, held_cam_view, _} = live(conn, ~p"/settings/recording?tab=cameras")

    held_cam_view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => live_ctx.source.id})

    assert has_element?(held_cam_view, "#camera-recording-holds-timeline-note")

    assert has_element?(
             held_cam_view,
             "#block-hold-pin-#{block_verified.id}",
             "Hold pins archive copy (local evictable)"
           )

    assert has_element?(
             held_cam_view,
             "#block-hold-pin-#{block_verified.id}",
             "1 active hold (investigation)"
           )

    assert has_element?(
             held_cam_view,
             "#block-hold-pin-#{block_pending.id}",
             "Hold pins local copy"
           )

    assert has_element?(
             held_cam_view,
             "#block-hold-pin-#{block_pending.id}",
             "1 active hold (export)"
           )

    refute has_element?(held_cam_view, "#block-hold-pin-#{block_uncataloged.id}")

    # Verify ?tab=retention aggregates active_hold_count=2, held_archive_bytes=32 MiB,
    # non_reapable_bytes=48 MiB (32 MiB held archive + 16 MiB in-flight), held_local_pinned_bytes=16 MiB
    {:ok, held_ret_view, _} = live(conn, ~p"/settings/recording?tab=retention")

    assert has_element?(held_ret_view, "#retention-active-holds-count", "Active holds: 2")
    assert has_element?(held_ret_view, "#retention-held-archive-bytes", "Held archive: 32 MiB")
    assert has_element?(held_ret_view, "#retention-non-reapable-bytes", "48 MiB")
    assert has_element?(held_ret_view, "#retention-held-local-pinned-bytes", "16 MiB")
    assert has_element?(held_ret_view, "#retention-holds-capacity-summary")

    # Releasing hold_archive updates both ?tab=cameras and ?tab=retention immediately
    {:ok, released_hold} =
      RecordingHolds.release_hold(
        hold_archive.id,
        %{release_reason: "Synthetic DB investigation closed"},
        scope: scope
      )

    assert released_hold.state == :released

    {:ok, after_release_ret_view, _} = live(conn, ~p"/settings/recording?tab=retention")

    assert has_element?(after_release_ret_view, "#retention-active-holds-count", "Active holds: 1")
    assert has_element?(after_release_ret_view, "#retention-held-archive-bytes", "Held archive: 0 B")
    assert has_element?(after_release_ret_view, "#retention-non-reapable-bytes", "16 MiB")
    assert has_element?(after_release_ret_view, "#retention-held-local-pinned-bytes", "16 MiB")
  end

  @tag :tmp_dir
  test "policy tab persists CameraRecordingPolicy revisions and live C1a what-if against Postgres without stubs",
       %{conn: conn, actor: actor, tmp_dir: tmp_dir} do
    opts = [actor: actor]
    configure_synthetic_runtime_members!(tmp_dir)
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Policy Writer")

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "policy-arch-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-policy-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding.id,
          archive_enabled: true,
          writer_credential_secret_id: writer_secret.id
        },
        opts
      )

    live_ctx = setup_live_recorder_fence(actor)

    {:ok, _profile} =
      StreamProfile.update_profile(
        live_ctx.profile,
        %{metadata: %{"observed_bitrate_bps" => 2_000_000}},
        opts
      )

    {:ok, policy_view, policy_html} = live(conn, ~p"/settings/recording?tab=policy")

    refute policy_html =~ "Blocked"
    assert has_element?(policy_view, "#recording-policy-runtime-notice")
    assert has_element?(policy_view, "#recording-policy-form")
    assert has_element?(policy_view, "#recording-policy-what-if-panel")

    # Select camera first to load relay-eligible stream profiles, then enable continuous + limited override
    policy_view
    |> element("#recording-policy-form")
    |> render_change(%{"policy" => %{"camera_source_id" => live_ctx.source.id}})

    policy_view
    |> element("#recording-policy-form")
    |> render_change(%{
      "policy" => %{
        "camera_source_id" => live_ctx.source.id,
        "stream_profile_id" => live_ctx.profile.id,
        "mode" => "continuous",
        "storage" => "local_and_archive",
        "archive_retention_override_mode" => "limited"
      }
    })

    preview_html =
      policy_view
      |> element("#recording-policy-form")
      |> render_change(%{
        "policy" => %{
          "camera_source_id" => live_ctx.source.id,
          "stream_profile_id" => live_ctx.profile.id,
          "mode" => "continuous",
          "nvr_member" => "serviceradar-nvr-0",
          "storage" => "local_and_archive",
          "archive_retention_override_mode" => "limited",
          "archive_retention_days_override" => "14"
        }
      })

    assert preview_html =~ "2000 kbit/s"
    assert preview_html =~ "1 / 16"
    assert preview_html =~ "configured 14d, time binds"

    policy_view
    |> element("#recording-policy-form")
    |> render_submit(%{
      "policy" => %{
        "camera_source_id" => live_ctx.source.id,
        "stream_profile_id" => live_ctx.profile.id,
        "mode" => "continuous",
        "nvr_member" => "serviceradar-nvr-0",
        "storage" => "local_and_archive",
        "archive_retention_override_mode" => "limited",
        "archive_retention_days_override" => "14"
      }
    })

    {:ok, created_policy} =
      CameraRecordingPolicy.get_by_camera_profile(live_ctx.source.id, live_ctx.profile.id, opts)

    assert created_policy.policy_revision == 1
    assert created_policy.mode == :continuous
    assert created_policy.nvr_member == "serviceradar-nvr-0"
    assert has_element?(policy_view, "#recording-policy-row-#{created_policy.id}", "rev 1")

    # Switch override mode back to inherit, then submit update via LiveView form/3
    # (which enforces disabled <select> omission and submits hidden locked identity inputs) -> rev 2
    policy_view
    |> form("#recording-policy-form", %{
      "policy" => %{
        "mode" => "continuous",
        "nvr_member" => "serviceradar-nvr-1",
        "storage" => "local_only",
        "archive_retention_override_mode" => "inherit"
      }
    })
    |> render_change()

    policy_view
    |> form("#recording-policy-form", %{
      "policy" => %{
        "mode" => "continuous",
        "nvr_member" => "serviceradar-nvr-1",
        "storage" => "local_only",
        "archive_retention_override_mode" => "inherit"
      }
    })
    |> render_submit()

    {:ok, updated_policy} =
      CameraRecordingPolicy.get_by_camera_profile(live_ctx.source.id, live_ctx.profile.id, opts)

    assert updated_policy.policy_revision == 2
    assert updated_policy.nvr_member == "serviceradar-nvr-1"
    assert updated_policy.storage == :local_only
    assert has_element?(policy_view, "#recording-policy-row-#{updated_policy.id}", "rev 2")
  end

  @tag :tmp_dir
  test "recorders tab enforces NVRStorageSettings pinned-bytes floor and persists desired budget and reserve",
       %{conn: conn, actor: actor, tmp_dir: tmp_dir} do
    open_synthetic_recovery_gate!(tmp_dir)
    opts = [actor: actor]
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Storage Floor Writer")

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "storage-floor-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-storage-floor",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding.id,
          archive_enabled: true,
          writer_credential_secret_id: writer_secret.id
        },
        opts
      )

    live_ctx = setup_live_recorder_fence(actor)
    block_pending = reserve_fenced_block(live_ctx, 0, opts)
    descriptor_pending = build_synthetic_descriptor(block_pending, 16_777_216)

    {:ok, _entry_pending} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_pending,
        descriptor_pending,
        %{
          first_unit_pts: 0,
          first_unit_received_at: ~U[2026-11-16 12:15:00.000000Z],
          reanchored: false
        },
        opts
      )

    {:ok, rec_view, rec_html} = live(conn, ~p"/settings/recording?tab=recorders")

    assert has_element?(rec_view, "#recording-member-budgets-section")
    assert has_element?(rec_view, "#storage-settings-row-#{@storage_id}")
    assert rec_html =~ "85% of PVC minus max(64 MiB, 1%)"
    assert rec_html =~ "48 MiB"

    # Enable custom budget input, then submit budget below pinned floor (16 MiB + 32 MiB = 48 MiB)
    rec_view
    |> element("#recording-storage-settings-form")
    |> render_change(%{
      "storage_settings" => %{
        "storage_id" => @storage_id,
        "budget_mode" => "custom",
        "reserve_mode" => "install_default"
      }
    })

    rec_view
    |> element("#recording-storage-settings-form")
    |> render_submit(%{
      "storage_settings" => %{
        "storage_id" => @storage_id,
        "budget_mode" => "custom",
        "budget_bytes" => "33554432",
        "reserve_mode" => "install_default"
      }
    })

    assert has_element?(rec_view, "#storage-settings-error-budget-bytes")

    # Enable custom reserve input too, then save valid desired budget (20 GiB) and reserve (512 MiB)
    rec_view
    |> element("#recording-storage-settings-form")
    |> render_change(%{
      "storage_settings" => %{
        "storage_id" => @storage_id,
        "budget_mode" => "custom",
        "reserve_mode" => "custom"
      }
    })

    rec_view
    |> element("#recording-storage-settings-form")
    |> render_submit(%{
      "storage_settings" => %{
        "storage_id" => @storage_id,
        "budget_mode" => "custom",
        "budget_bytes" => "21474836480",
        "reserve_mode" => "custom",
        "reserve_bytes" => "536870912"
      }
    })

    {:ok, persisted} = NVRStorageSettings.get_by_storage_id(@storage_id, opts)
    assert persisted.revision == 1
    assert persisted.budget_mode == :custom
    assert persisted.budget_bytes == 21_474_836_480
    assert persisted.reserve_mode == :custom
    assert persisted.reserve_bytes == 536_870_912
    assert is_nil(persisted.applied_revision)
    assert has_element?(rec_view, "#storage-settings-row-#{@storage_id}", "rev 1")
    assert has_element?(rec_view, "#storage-settings-row-#{@storage_id}", "pending")
  end

  @tag :tmp_dir
  test "health tab renders real CNPG archive backlog, per-storage capacity, quarantine, dispositions, and 24h gaps",
       %{conn: conn, scope: scope, actor: actor, tmp_dir: tmp_dir} do
    open_synthetic_recovery_gate!(tmp_dir)
    seed_health_tab_records(actor, scope)

    {:ok, health_view, health_html} = live(conn, ~p"/settings/recording?tab=health")

    refute health_html =~ "Blocked"
    assert has_element?(health_view, "#recording-health-backlog-card")
    assert has_element?(health_view, "#health-failed-terminal-badge", "Action required")
    assert has_element?(health_view, "#recording-health-storage-card")
    assert health_html =~ "unknown until NVR /v1/status reports"
    assert health_html =~ "Local storage holds about"
    assert has_element?(health_view, "#recording-health-reconciliation-card")
    assert health_html =~ "awaiting reconciler"
    assert health_html =~ "unattributable"
    assert has_element?(health_view, "#recording-health-gaps-alerts-card")
    assert health_html =~ "source_unavailable"
    assert health_html =~ "nvr_refused"
  end

  @tag sandbox: :unboxed
  @tag :tmp_dir
  test "R.10 historical freeze, reservation resolutions, unattributable quarantine operator delete/export, and held missing-archive loss work end-to-end against Postgres",
       %{conn: conn, scope: scope, actor: actor, tmp_dir: tmp_dir} do
    opts = [actor: actor]
    now = DateTime.utc_now()
    open_synthetic_recovery_gate!(tmp_dir)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "r10-arch-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-r10-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    on_exit(fn -> cleanup_unboxed_archive_binding(binding.id) end)

    live_ctx = setup_live_recorder_fence(actor)
    on_exit(fn -> cleanup_unboxed_camera_source(live_ctx.source.id) end)

    block_historical = reserve_fenced_block(live_ctx, 0, opts)
    block_absent = reserve_fenced_block(live_ctx, 1, opts)
    block_unrecoverable = reserve_fenced_block(live_ctx, 2, opts)
    block_unresolved = reserve_fenced_block(live_ctx, 3, opts)

    # Retire the recorder claim so reconciler primitives run under writer retirement (R3)
    live_ctx.claim
    |> Ash.Changeset.for_update(
      :transition,
      %{state: :released, claim_token: nil, consumer_id: nil, lease_expires_at: nil},
      opts
    )
    |> Ash.update!(opts)

    # 1. Reconciler freeze_historical adopts block_historical into RecordingCatalogEntry
    descriptor_hist = build_synthetic_descriptor(block_historical, 16_777_216)

    {:ok, entry_hist} =
      RecordingBlocks.freeze_historical(
        block_historical.id,
        descriptor_hist,
        %{
          first_unit_pts: 0,
          first_unit_received_at: DateTime.shift(now, minute: -20),
          reanchored: false
        },
        opts
      )

    # Transition entry_hist to verified -> missing with an active legal hold covering its window
    {:ok, entry_hist} =
      entry_hist
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update(opts)

    {:ok, _hold} =
      RecordingHolds.place_hold(
        %{
          camera_source_id: live_ctx.source.id,
          stream_profile_id: live_ctx.profile.id,
          start_us: entry_hist.timeline_start_us,
          end_us: entry_hist.timeline_end_us,
          kind: :investigation,
          reason: "Synthetic R10 investigation hold covering missing archive copy"
        },
        scope: scope
      )

    {:ok, entry_missing} =
      entry_hist
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{archive_state: :missing, archive_state_at: now},
        opts
      )
      |> Ash.update(opts)

    # 2. Resolve block_absent and block_unrecoverable via Core reconciler primitives
    {:ok, _} =
      RecordingBlocks.resolve_reservation_absent(
        block_absent.id,
        %{detail_class: "nvr_reported_absent"},
        opts
      )

    {:ok, _} =
      RecordingBlocks.resolve_reservation_unrecoverable(
        block_unrecoverable.id,
        %{detail_class: "corrupt_journal_tail"},
        opts
      )

    # 3. Register an unattributable quarantined block via Core reconciler primitive
    orphan_key =
      :sha256
      |> :crypto.hash("synthetic-r10-orphan-#{System.unique_integer([:positive])}")
      |> Base.encode16(case: :lower)

    {:ok, %{entry: orphan_entry}} =
      RecordingBlocks.quarantine_unattributable_block(
        %{
          storage_id: @storage_id,
          block_key: orphan_key,
          quarantined_bytes: 4_194_304,
          quarantine_receipt: %{"source" => "synthetic_r10_reconciler"},
          quarantine_evidence: %{"reason" => "no_core_reservation"}
        },
        opts
      )

    on_exit(fn -> cleanup_unboxed_quarantined_entry(orphan_entry.id) end)

    # 4. Verify ?tab=cameras displays exact reservation resolution badges
    {:ok, cam_view, _} = live(conn, ~p"/settings/recording?tab=cameras")

    cam_view
    |> element("#recording-camera-picker-form")
    |> render_change(%{"camera_source_id" => live_ctx.source.id})

    assert has_element?(
             cam_view,
             "#block-core-state-#{block_unresolved.id}",
             "Core reservation (unresolved)"
           )

    assert has_element?(
             cam_view,
             "#block-core-state-#{block_absent.id}",
             "Resolved: block absent"
           )

    assert has_element?(
             cam_view,
             "#block-core-state-#{block_unrecoverable.id}",
             "Resolved: unrecoverable journal"
           )

    # 5. Verify ?tab=health renders reservation breakdown and executes audited operator dispositions
    {:ok, health_view, _} = live(conn, ~p"/settings/recording?tab=health")

    assert has_element?(health_view, "#health-reservations-breakdown")
    assert has_element?(health_view, "#health-quarantined-entry-#{orphan_entry.id}")
    assert has_element?(health_view, "#health-missing-entry-#{entry_missing.id}")

    # Export / Preserve intent
    health_view
    |> element("#request-quarantine-export-#{orphan_entry.id}")
    |> render_click()

    {:ok, after_export} = Ash.get(RecordingCatalogEntry, orphan_entry.id, opts)
    assert after_export.operator_disposition_state == :export_requested

    # Audited Delete Intent with explicit confirmation
    health_view
    |> element("#quarantine-delete-form-#{orphan_entry.id}")
    |> render_submit(%{
      "delete" => %{
        "id" => orphan_entry.id,
        "confirm" => "true",
        "note" => "Confirmed synthetic orphan disposal"
      }
    })

    {:ok, after_delete} = Ash.get(RecordingCatalogEntry, orphan_entry.id, opts)
    assert after_delete.local_state == :reclaiming
    assert after_delete.operator_disposition_state == :delete_requested

    # Accept Archive Loss on held missing archive entry (admin holds both operate + hold permissions)
    health_view
    |> element("#accept-missing-loss-form-#{entry_missing.id}")
    |> render_submit(%{"loss" => %{"id" => entry_missing.id, "note" => "Accepted synthetic loss"}})

    {:ok, after_loss} = Ash.get(RecordingCatalogEntry, entry_missing.id, opts)
    assert after_loss.archive_state == :not_required
    assert after_loss.archive_binding_id == binding.id
  end

  test "hosted waiting state, applied StorageEntitlement retention/policy bounds, and Cloud-managed archive credentials work end-to-end against CNPG",
       %{conn: conn, actor: actor} do
    previous_hosted = Application.get_env(:serviceradar_core, :hosted_runtime_contract_version)
    Application.put_env(:serviceradar_core, :hosted_runtime_contract_version, "1")

    on_exit(fn ->
      if previous_hosted,
        do:
          Application.put_env(
            :serviceradar_core,
            :hosted_runtime_contract_version,
            previous_hosted
          ),
        else: Application.delete_env(:serviceradar_core, :hosted_runtime_contract_version)
    end)

    opts = [actor: actor]
    sys_actor = ServiceRadar.Actors.SystemActor.system(:recording_live_entitlement_db_test)
    dep_ref = Ecto.UUID.generate()
    inst = %{deployment_ref: dep_ref, generation: "1"}

    # 1. Hosted install before first entitlement renders waiting banner
    {:ok, waiting_view, _} = live(conn, ~p"/settings/recording?tab=retention")

    assert has_element?(
             waiting_view,
             "#retention-waiting-entitlement-banner",
             "Waiting for a storage entitlement"
           )

    # 2. Seed 400-day archive retention before entitlement push, then apply plan
    #    with max_days: 365, max_recording_cameras: 1, and a pending decrease
    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{archive_retention_mode: :limited, archive_retention_days: 400},
        opts
      )

    {:ok, _delivered_writer} =
      ServiceRadar.Camera.CloudArchiveCredentials.deliver(
        inst,
        "writer",
        %{
          "schema_version" => 1,
          "deployment_ref" => dep_ref,
          "credential_generation" => 1,
          "access_key_id" => "SYNTHENTWRITERKEY001",
          "secret_access_key" => "synth-ent-writer-secret-never-shown-001"
        },
        actor: sys_actor
      )

    effective_at_iso =
      DateTime.utc_now()
      |> DateTime.shift(day: 1)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    {:ok, _} =
      ServiceRadar.Storage.StorageEntitlements.apply_document(
        inst,
        %{
          "schema_version" => 1,
          "deployment_ref" => dep_ref,
          "revision" => 1,
          "issued_at" => "2026-11-17T12:00:00Z",
          "consumers" => %{
            "recordings" => %{
              "enabled" => true,
              "allocation_bytes" => 107_374_182_400,
              "overage" => %{"mode" => "off"},
              "capacity_policy" => "reap_oldest",
              "retention" => %{"max_days" => 365, "default_days" => 30},
              "limits" => %{"max_recording_cameras" => 1},
              "pending" => %{
                "effective_at" => effective_at_iso,
                "allocation_bytes" => 53_687_091_200,
                "retention" => %{"max_days" => 90}
              }
            }
          }
        },
        actor: sys_actor
      )

    # 3. Retention tab displays "Set by plan", exact "configured 400 days, effective 365 days (plan maximum)",
    #    pending banner, and refuses > 365 days
    {:ok, ret_view, ret_html} = live(conn, ~p"/settings/recording?tab=retention")
    refute ret_html =~ "synth-ent-writer-secret-never-shown-001"
    refute has_element?(ret_view, "#retention-waiting-entitlement-banner")
    assert has_element?(ret_view, "#retention-plan-budget-badge", "Set by plan")

    assert has_element?(
             ret_view,
             "#retention-archive-effective-plan-cap",
             "configured 400 days, effective 365 days (plan maximum)"
           )

    assert has_element?(ret_view, "#retention-pending-entitlement-banner", "50 GiB")
    refute has_element?(ret_view, "#retention-archive-mode-select option[value='unlimited']")

    ret_view
    |> element("#recording-retention-settings-form")
    |> render_submit(%{
      "retention" => %{
        "archive_retention_mode" => "limited",
        "archive_retention_days" => "380"
      }
    })

    assert has_element?(ret_view, "#retention-error-archive-retention-days", "limited by your plan")

    # 4. Archive tab shows Cloud-managed writer credential as Managed by ServiceRadar Cloud
    {:ok, arch_view, arch_html} = live(conn, ~p"/settings/recording?tab=archive")
    refute arch_html =~ "synth-ent-writer-secret-never-shown-001"
    assert has_element?(arch_view, "#writer-credential-cloud-managed-badge", "Managed by ServiceRadar Cloud")
    assert has_element?(arch_view, "#writer-credential-disabled-select")

    # 5. Policy tab enforces max_recording_cameras == 1 with "limited by your plan"
    cam1 = setup_live_recorder_fence(actor)
    cam2 = setup_live_recorder_fence(actor)

    {:ok, pol_view, _} = live(conn, ~p"/settings/recording?tab=policy")

    pol_view
    |> element("#recording-policy-form")
    |> render_submit(%{
      "policy" => %{
        "camera_source_id" => cam1.source.id,
        "stream_profile_id" => cam1.profile.id,
        "mode" => "continuous",
        "nvr_member" => "serviceradar-nvr-0",
        "storage" => "local_and_archive",
        "archive_retention_override_mode" => "inherit"
      }
    })

    assert has_element?(
             pol_view,
             "#policy-camera-limit-badge",
             "1 / 1 continuous cameras (limited by your plan)"
           )

    pol_view
    |> element("#recording-policy-form")
    |> render_submit(%{
      "policy" => %{
        "camera_source_id" => cam2.source.id,
        "stream_profile_id" => cam2.profile.id,
        "mode" => "continuous",
        "nvr_member" => "serviceradar-nvr-0",
        "storage" => "local_and_archive",
        "archive_retention_override_mode" => "inherit"
      }
    })

    assert render(pol_view) =~ "limited by your plan"
  end

  defp seed_health_tab_records(actor, scope) do
    opts = [actor: actor]
    now = DateTime.utc_now()
    writer_secret = create_synthetic_s3_secret(actor, "Synthetic Health Writer")

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "health-arch-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-health-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, _} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding.id,
          archive_enabled: true,
          writer_credential_secret_id: writer_secret.id
        },
        opts
      )

    live_ctx = setup_live_recorder_fence(actor)

    {:ok, _policy} =
      CameraRecordingSettings.save_policy(
        scope,
        %{
          "camera_source_id" => live_ctx.source.id,
          "stream_profile_id" => live_ctx.profile.id,
          "mode" => "continuous",
          "nvr_member" => "serviceradar-nvr-0",
          "storage" => "local_and_archive",
          "archive_retention_override_mode" => "inherit"
        }
      )

    block_failed = reserve_fenced_block(live_ctx, 0, opts)
    descriptor_failed = build_synthetic_descriptor(block_failed, 8_388_608)

    {:ok, entry_failed} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_failed,
        descriptor_failed,
        %{
          first_unit_pts: 0,
          first_unit_received_at: DateTime.shift(now, minute: -15),
          reanchored: false
        },
        opts
      )

    {:ok, _} =
      entry_failed
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :failed_terminal,
          archive_state_at: now,
          archive_attempts: 5,
          archive_last_error_class: "http_403"
        },
        opts
      )
      |> Ash.update(opts)

    quarantine_key =
      :sha256
      |> :crypto.hash("synthetic-quarantined-block-#{System.unique_integer([:positive])}")
      |> Base.encode16(case: :lower)

    {:ok, _quarantined} =
      RecordingCatalogEntry
      |> Ash.Changeset.for_create(
        :register_quarantined,
        %{
          storage_id: @storage_id,
          block_key: quarantine_key,
          quarantine_reason: :unattributable,
          quarantine_receipt: %{"source" => "synthetic_reconcile"},
          quarantined_bytes: 4_194_304,
          local_state_at: now,
          archive_state: :not_required,
          archive_state_at: now
        },
        opts
      )
      |> Ash.create(opts)

    {:ok, _disposition} =
      RecordingDisposition
      |> Ash.Changeset.for_create(
        :record,
        %{
          operation_id: Ecto.UUID.generate(),
          catalog_entry_id: entry_failed.id,
          storage_id: @storage_id,
          block_key: block_failed.block_key,
          copy: :local,
          reason: :budget,
          step: :failed,
          error_class: "nvr_unreachable",
          actor_id: "system:synthetic_reaper"
        },
        opts
      )
      |> Ash.create(opts)

    now_us = DateTime.to_unix(now, :microsecond)

    {:ok, _closed_gap} =
      RecordingGap.record(
        %{
          camera_source_id: live_ctx.source.id,
          stream_profile_id: live_ctx.profile.id,
          storage_id: @storage_id,
          start_us: now_us - 60_000_000,
          end_us: now_us - 30_000_000,
          time_basis: :received,
          reason: :source_unavailable
        },
        opts
      )

    {:ok, _open_gap} =
      RecordingGap.record(
        %{
          camera_source_id: live_ctx.source.id,
          stream_profile_id: live_ctx.profile.id,
          storage_id: @storage_id,
          start_us: now_us - 10_000_000,
          time_basis: :received,
          reason: :nvr_refused
        },
        opts
      )
  end

  defp setup_live_recorder_fence(actor) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-stageb-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Stage B Camera #{System.unique_integer([:positive])}",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-stageb",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

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
      RelaySessionLifecycle.activate_session(
        session.id,
        "synthetic-stageb-ingest-#{key}",
        assignment,
        opts
      )

    {:ok, owner} = IngestOwnership.for_relay(session.id, opts)
    claim_token = Ecto.UUID.generate()
    {:ok, consumer} = IngestOwnership.acquire_consumer(owner, :recorder, claim_token, 60_000, opts)

    initial_claim =
      RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
      |> Ash.create!(opts)

    claim =
      initial_claim
      |> Ash.Changeset.for_update(
        :transition,
        %{
          claim_token: claim_token,
          ingest_epoch: owner.epoch,
          recorder_epoch: 1,
          next_block_sequence: 4,
          relay_session_id: owner.relay_session_id,
          media_ingest_id: session.media_ingest_id,
          storage_id: @storage_id,
          consumer_id: consumer.id,
          lease_expires_at: consumer.expires_at,
          state: :active
        },
        opts
      )
      |> Ash.update!(opts)

    %{source: source, profile: profile, session: session, owner: owner, claim: claim}
  end

  defp reserve_fenced_block(live_ctx, sequence, opts) do
    clock = %{
      "clock_epoch" => "synth-stageb-epoch-1",
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
      block_sequence: sequence,
      relay_session_id: live_ctx.claim.relay_session_id,
      media_ingest_id: live_ctx.claim.media_ingest_id,
      storage_id: live_ctx.claim.storage_id,
      clock: clock
    }

    identity = RecordingBlock.identity(attrs)

    RecordingBlock
    |> Ash.Changeset.for_create(
      :reserve,
      Map.put(attrs, :block_key, Descriptor.block_key(identity)),
      opts
    )
    |> Ash.create!(opts)
  end

  defp build_synthetic_descriptor(block, media_bytes) do
    half = div(media_bytes, 2)

    %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{
        "length" => 512,
        "sha256" => Base.encode16(:crypto.hash(:sha256, "synth-init-#{block.id}"), case: :lower)
      },
      "media" => %{
        "length" => media_bytes,
        "sha256" => Base.encode16(:crypto.hash(:sha256, "synth-media-#{block.id}"), case: :lower)
      },
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => half,
          "start_ns" => 0,
          "duration_ns" => 2_000_000_000,
          "sha256" => Base.encode16(:crypto.hash(:sha256, "synth-frag0-#{block.id}"), case: :lower),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 1,
          "offset" => half,
          "length" => media_bytes - half,
          "start_ns" => 2_000_000_000,
          "duration_ns" => 2_000_000_000,
          "sha256" => Base.encode16(:crypto.hash(:sha256, "synth-frag1-#{block.id}"), case: :lower),
          "tail_duration_source" => "previous_sample",
          "motion" => "unknown"
        }
      ]
    }
  end

  defp record_synthetic_receipt(binding, block, length_bytes, version_id, actor) do
    object_sha =
      Base.encode16(:crypto.hash(:sha256, "synth-obj-#{block.block_key}-#{version_id}"),
        case: :lower
      )

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => @storage_id,
        "block_key" => block.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond),
        "objects" => [
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{@storage_id}/#{block.block_key}/media.m4s",
            "length" => length_bytes,
            "sha256" => object_sha,
            "etag" => "\"etag-#{version_id}\"",
            "version_id" => version_id
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

  defp seed_recent_blocks_and_receipts(actor, binding) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-ret-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Retention Camera #{System.unique_integer([:positive])}",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-retention",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

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
      RelaySessionLifecycle.activate_session(
        session.id,
        "synthetic-ret-ingest-#{key}",
        assignment,
        opts
      )

    {:ok, owner} =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^source.id and stream_profile_id == ^profile.id)
      |> Ash.read_one(opts)

    claim =
      RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
      |> Ash.create!(opts)

    old_ts = DateTime.shift(now, hour: -26)
    recent_ts = DateTime.shift(now, minute: -2)

    block_old = insert_synthetic_block_at(source.id, profile.id, owner, session, claim.id, 0, old_ts)
    block_recent = insert_synthetic_block_at(source.id, profile.id, owner, session, claim.id, 1, recent_ts)

    for {blk, verified_dt, idx} <- [{block_old, old_ts, 1}, {block_recent, recent_ts, 2}] do
      object_sha =
        Base.encode16(:crypto.hash(:sha256, "synthetic-ret-payload-#{idx}"), case: :lower)

      receipt_bytes =
        Jason.encode!(%{
          "version" => 2,
          "storage_id" => @storage_id,
          "block_key" => blk.block_key,
          "destination_sha256" => binding.destination_sha256,
          "verified_at_ms" => DateTime.to_unix(verified_dt, :millisecond),
          "objects" => [
            %{
              "name" => "media.m4s",
              "key" => "recordings/v1/#{@storage_id}/#{blk.block_key}/media.m4s",
              "length" => 104_857_600,
              "sha256" => object_sha,
              "etag" => "\"synthetic-ret-etag-#{idx}\"",
              "version_id" => "synth-ret-ver-0#{idx}"
            }
          ]
        })

      {:ok, _receipt} =
        NVRArchiveReceipt.record(
          binding.id,
          receipt_bytes,
          %{recording_block_id: blk.id},
          actor: actor
        )
    end
  end

  defp create_camera_with_profiles_and_blocks(actor, total_blocks) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Yard Camera #{System.unique_integer([:positive])}",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, eligible_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-eligible",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, ineligible_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "aux-disabled",
          codec_hint: "mjpeg",
          relay_eligible: false
        },
        opts
      )

    {:ok, session} =
      RelaySessionManager.request_open(source.id, eligible_profile.id,
        actor: actor,
        control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
        dispatch_open: fn _agent, _payload, open_opts, _requester ->
          {:ok, open_opts[:command_id]}
        end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      RelaySessionLifecycle.activate_session(
        session.id,
        "synthetic-ingest-#{key}",
        assignment,
        opts
      )

    {:ok, owner} =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^source.id and stream_profile_id == ^eligible_profile.id)
      |> Ash.read_one(opts)

    claim =
      RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
      |> Ash.create!(opts)

    inserted =
      for seq <- 0..(total_blocks - 1) do
        insert_synthetic_block_at(
          source.id,
          eligible_profile.id,
          owner,
          session,
          claim.id,
          seq,
          DateTime.shift(~U[2026-11-15 12:00:00.000000Z], second: seq)
        )
      end

    oldest = hd(inserted)
    newest = List.last(inserted)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "cam-receipt-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-cam-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    object_sha = Base.encode16(:crypto.hash(:sha256, "synthetic-fmp4-payload"), case: :lower)

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => @storage_id,
        "block_key" => newest.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => 1_763_200_010_000,
        "objects" => [
          %{
            "name" => "media.fmp4",
            "key" => "recordings/v1/#{@storage_id}/#{newest.block_key}/media.fmp4",
            "length" => 4096,
            "sha256" => object_sha,
            "etag" => "\"synthetic-etag-1\"",
            "version_id" => "synth-ver-db-01"
          }
        ]
      })

    {:ok, _receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: newest.id},
        actor: actor
      )

    %{
      source: source,
      eligible_profile: eligible_profile,
      ineligible_profile: ineligible_profile,
      oldest_block_id: oldest.id,
      receipt_block_id: newest.id
    }
  end

  defp insert_synthetic_block_at(source_id, profile_id, owner, session, claim_id, sequence, inserted_at) do
    block_id = Ash.UUIDv7.generate()

    block_key =
      :sha256
      |> :crypto.hash("synthetic-web-ng-block:#{claim_id}:#{sequence}")
      |> Base.encode16(case: :lower)

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_recording_blocks (
        id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
        recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
        storage_id, clock, state, upload_epoch, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6,
        $7, 1, $8, $9, $10,
        $11, $12::jsonb, 'open_local', 0, $13, $13
      )
      """,
      [
        Ecto.UUID.dump!(block_id),
        block_key,
        Ecto.UUID.dump!(source_id),
        Ecto.UUID.dump!(profile_id),
        Ecto.UUID.dump!(owner.id),
        owner.epoch,
        Ecto.UUID.dump!(claim_id),
        sequence,
        Ecto.UUID.dump!(session.id),
        session.media_ingest_id,
        Ecto.UUID.dump!(@storage_id),
        %{"timescale" => 90_000},
        inserted_at
      ]
    )

    %{id: block_id, block_key: block_key}
  end

  defp create_synthetic_s3_secret(actor, prefix) do
    {:ok, built} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICACCESSKEY02",
          "secret_access_key" => String.duplicate("s", 32)
        },
        %{name: "#{prefix} #{System.unique_integer([:positive])}"}
      )

    NetworkCredentialSecret.create_secret!(built, actor: actor)
  end

  defp configure_synthetic_runtime_members!(tmp_dir) do
    orig_sup = Application.get_env(:serviceradar_web_ng, :camera_recording_remote_supervisor)
    orig_nodes = Application.get_env(:serviceradar_web_ng, :camera_recording_rpc_nodes)
    orig_cfg = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_config_file)
    orig_tok = Application.get_env(:serviceradar_core_elx, :camera_nvr_client_token_file)

    start_supervised!(%{
      id: EnabledRuntimeSupervisorStub,
      start: {Agent, :start_link, [fn -> :ok end, [name: EnabledRuntimeSupervisorStub]]}
    })

    config_path = Path.join(tmp_dir, "nvr-client.json")
    token_path = Path.join(tmp_dir, "nvr-token")
    File.write!(token_path, "synthetic-unused-token")

    File.write!(
      config_path,
      Jason.encode!(%{
        "members" => %{
          "serviceradar-nvr-0" => %{
            "host" => "nvr-0.example.com",
            "port" => 8443,
            "storage_id" => @storage_id
          },
          "serviceradar-nvr-1" => %{
            "host" => "nvr-1.example.com",
            "port" => 8443,
            "storage_id" => "00000000-0000-4000-8000-000000000042"
          }
        }
      })
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_recording_remote_supervisor,
      EnabledRuntimeSupervisorStub
    )

    Application.put_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, [Node.self()])
    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_config_file, config_path)
    Application.put_env(:serviceradar_core_elx, :camera_nvr_client_token_file, token_path)

    on_exit(fn ->
      restore_app_env(:serviceradar_web_ng, :camera_recording_remote_supervisor, orig_sup)
      restore_app_env(:serviceradar_web_ng, :camera_recording_rpc_nodes, orig_nodes)
      restore_app_env(:serviceradar_core_elx, :camera_nvr_client_config_file, orig_cfg)
      restore_app_env(:serviceradar_core_elx, :camera_nvr_client_token_file, orig_tok)
    end)
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, val), do: Application.put_env(app, key, val)

  defp open_synthetic_recovery_gate!(tmp_dir) do
    prior = Application.fetch_env(:serviceradar_core, :nvr_recovery_gate)
    path = Path.join(tmp_dir, "recovery.json")
    generation = Ecto.UUID.generate()
    File.write!(path, ~s({"generation":"#{generation}","state":"ready"}))

    {:ok, gate} =
      ServiceRadarRecordingControl.RecoveryGate.load(
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

  defp cleanup_unboxed_quarantined_entry(entry_id) do
    entry_bin = Ecto.UUID.dump!(entry_id)

    %{rows: op_rows} =
      SQL.query!(
        Repo,
        "SELECT DISTINCT operation_id FROM platform.camera_recording_dispositions WHERE catalog_entry_id = $1",
        [entry_bin]
      )

    for [op_bin] <- op_rows do
      cleanup_unboxed_dispositions_by_operation(op_bin)
    end

    %{rows: cat_rows} =
      SQL.query!(
        Repo,
        "SELECT storage_id, block_key FROM platform.camera_recording_catalog WHERE id = $1",
        [entry_bin]
      )

    for [storage_bin, block_key] <- cat_rows do
      SQL.query!(
        Repo,
        "DELETE FROM platform.camera_recording_operations WHERE storage_id = $1 AND block_key = $2",
        [storage_bin, block_key]
      )
    end

    SQL.query!(Repo, "DELETE FROM platform.camera_recording_catalog WHERE id = $1", [entry_bin])

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM platform.camera_recording_catalog WHERE id = $1",
               [entry_bin]
             )
  end

  defp cleanup_unboxed_camera_source(source_id) do
    id = Ecto.UUID.dump!(source_id)

    %{rows: op_rows} =
      SQL.query!(
        Repo,
        """
        SELECT DISTINCT operation_id FROM platform.camera_recording_dispositions
        WHERE catalog_entry_id IN (
          SELECT id FROM platform.camera_recording_catalog
          WHERE camera_source_id = $1 OR recording_block_id IN (
            SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1
          )
        )
        """,
        [id]
      )

    for [op_bin] <- op_rows do
      cleanup_unboxed_dispositions_by_operation(op_bin)
    end

    cleanup_unboxed_access_audits_by_camera(id)

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_recording_holds_versions WHERE version_source_id IN " <>
        "(SELECT id FROM platform.camera_recording_holds WHERE camera_source_id = $1)",
      [id]
    )

    SQL.query!(Repo, "DELETE FROM platform.camera_recording_holds WHERE camera_source_id = $1", [
      id
    ])

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_recording_operations WHERE camera_source_id = $1",
      [id]
    )

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_recording_catalog WHERE camera_source_id = $1 OR recording_block_id IN " <>
        "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [id]
    )

    SQL.query!(Repo, "DELETE FROM platform.camera_recording_gaps WHERE camera_source_id = $1", [
      id
    ])

    SQL.query!(Repo, "DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1", [
      id
    ])

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_recorder_claims WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_consumer_leases WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    SQL.query!(Repo, "DELETE FROM platform.camera_ingest_owners WHERE camera_source_id = $1", [id])
    SQL.query!(Repo, "DELETE FROM platform.camera_relay_sessions WHERE camera_source_id = $1", [id])
    SQL.query!(Repo, "DELETE FROM platform.camera_stream_profiles WHERE camera_source_id = $1", [id])
    SQL.query!(Repo, "DELETE FROM platform.camera_sources WHERE id = $1", [id])

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM platform.camera_sources WHERE id = $1", [id])
  end

  defp cleanup_unboxed_archive_binding(binding_id) do
    id = Ecto.UUID.dump!(binding_id)

    SQL.query!(
      Repo,
      "UPDATE platform.camera_recording_catalog SET archive_binding_id = NULL WHERE archive_binding_id = $1",
      [id]
    )

    SQL.query!(
      Repo,
      "UPDATE platform.camera_recording_catalog SET quarantine_binding_id = NULL WHERE quarantine_binding_id = $1",
      [id]
    )

    SQL.query!(Repo, "DELETE FROM platform.camera_archive_bindings WHERE id = $1", [id])

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $1",
               [id]
             )
  end

  defp cleanup_unboxed_dispositions_by_operation(op_bin) do
    {:ok, _} =
      Repo.transaction(fn ->
        SQL.query!(
          Repo,
          "ALTER TABLE platform.camera_recording_dispositions DISABLE TRIGGER trg_camera_recording_dispositions_append_only"
        )

        SQL.query!(
          Repo,
          "DELETE FROM platform.camera_recording_dispositions WHERE operation_id = $1",
          [op_bin]
        )

        SQL.query!(
          Repo,
          "ALTER TABLE platform.camera_recording_dispositions ENABLE TRIGGER trg_camera_recording_dispositions_append_only"
        )
      end)
  end

  defp cleanup_unboxed_access_audits_by_camera(camera_bin) do
    {:ok, _} =
      Repo.transaction(fn ->
        SQL.query!(
          Repo,
          "ALTER TABLE platform.camera_recording_access_audits DISABLE TRIGGER camera_recording_access_audits_append_only_trigger"
        )

        SQL.query!(
          Repo,
          "DELETE FROM platform.camera_recording_access_audits WHERE camera_source_id = $1",
          [camera_bin]
        )

        SQL.query!(
          Repo,
          "ALTER TABLE platform.camera_recording_access_audits ENABLE TRIGGER camera_recording_access_audits_append_only_trigger"
        )
      end)
  end
end
