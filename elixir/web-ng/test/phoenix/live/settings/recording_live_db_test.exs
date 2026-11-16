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
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
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

  test "freeze_and_catalog surfaces real catalog copy states and received time basis on ?tab=cameras and multi-generation same-bucket vs other-bucket usage on ?tab=retention",
       %{conn: conn, actor: actor} do
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
end
