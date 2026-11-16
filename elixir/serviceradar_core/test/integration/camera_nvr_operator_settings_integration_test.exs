defmodule ServiceRadar.Camera.NVROperatorSettingsIntegrationTest do
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ash.Page.Keyset
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingOperation
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.CredentialUsage
  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  require Ash.Query

  @moduletag :integration

  @storage_id_primary "00000000-0000-4000-8000-000000000011"
  @storage_id_secondary "00000000-0000-4000-8000-000000000022"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "ArchiveDestinations registers monotonic operator:<name> v2 generations while keeping v1 bindings valid" do
    system_opts = [actor: SystemActor.system(:nvr_operator_settings_test)]

    # Existing schema_version 1 destination registration continues to work.
    v1_input = Fixtures.archive_destination("cloud-#{Ecto.UUID.generate()}")
    assert {:ok, v1_binding} = ArchiveBinding.register(v1_input, system_opts)
    assert v1_binding.schema_version == 1
    assert v1_binding.namespace == "recordings/v1"
    assert v1_binding.capability_state == :unqualified

    admin = %{
      id: "admin-destinations",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    slug = "primary-#{System.unique_integer([:positive])}"

    assert {:ok, gen1} =
             ArchiveDestinations.register_operator(
               %{
                 name: slug,
                 endpoint: "https://objects.example.com",
                 region: "example-1",
                 bucket: "example-archive",
                 namespace: "nvr/archive-v2"
               },
               actor: admin
             )

    assert gen1.schema_version == 2
    assert gen1.provisioning_ref == "operator:#{slug}"
    assert gen1.generation == 1
    assert gen1.namespace == "nvr/archive-v2"
    assert gen1.capability_state == :unqualified

    assert {:ok, gen2} =
             ArchiveDestinations.register_operator(
               %{
                 name: slug,
                 endpoint: "https://objects.example.com",
                 region: "example-1",
                 bucket: "example-archive-next",
                 namespace: "nvr/archive-v2"
               },
               actor: admin
             )

    assert gen2.provisioning_ref == "operator:#{slug}"
    assert gen2.generation == 2
    refute gen2.destination_sha256 == gen1.destination_sha256

    assert {:ok, listed} = ArchiveDestinations.list_bindings(actor: admin)
    listed_ids = MapSet.new(listed, & &1.id)
    assert MapSet.member?(listed_ids, gen1.id)
    assert MapSet.member?(listed_ids, gen2.id)
    assert MapSet.member?(listed_ids, v1_binding.id)
  end

  test "RecordingArchiveSettings enforces split permissions, PaperTrail audit, and secret deletion guard" do
    admin = %{
      id: "admin-archive-settings",
      role: :admin,
      permissions:
        MapSet.new([
          "settings.recording.view",
          "settings.recording.manage",
          "settings.credentials.manage",
          "settings.audit.view"
        ])
    }

    recording_only = %{
      id: "operator-recording-only",
      role: :operator,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    # Code defaults apply before any singleton row exists (normal local-only state).
    assert {:ok, initial} = RecordingArchiveSettings.get_settings(actor: recording_only)
    assert initial.id == "deployment"
    assert initial.archive_enabled == false
    assert is_nil(initial.active_archive_binding_id)

    assert {:ok, initial_overview} = RecordingArchiveSettings.get_overview(actor: recording_only)
    assert initial_overview.storage_mode == :local_only
    assert initial_overview.archive_ready? == false
    assert is_nil(initial_overview.unavailable_reason)

    slug = "settings-#{System.unique_integer([:positive])}"

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: slug,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "example-archive",
          namespace: "recordings/v1"
        },
        actor: admin
      )

    writer = create_s3_secret("Writer S3")
    reader = create_s3_secret("Reader S3")
    non_s3 = create_non_s3_secret("Non-S3 Token")

    # Split-permission user cannot set writer_credential_secret_id.
    assert {:error, split_err} =
             RecordingArchiveSettings.save_settings(
               %{writer_credential_secret_id: writer.id},
               actor: recording_only
             )

    assert Exception.message(split_err) =~ "settings.credentials.manage"

    # Admin cannot select a non-s3_compatible credential.
    assert {:error, bad_provider_err} =
             RecordingArchiveSettings.save_settings(
               %{writer_credential_secret_id: non_s3.id},
               actor: admin
             )

    assert Exception.message(bad_provider_err) =~ "s3_compatible"

    # Admin saves active destination + writer/reader credentials.
    assert {:ok, saved} =
             RecordingArchiveSettings.save_settings(
               %{
                 active_archive_binding_id: binding.id,
                 writer_credential_secret_id: writer.id,
                 reader_credential_secret_id: reader.id,
                 archive_enabled: false
               },
               actor: admin
             )

    assert saved.id == "deployment"
    assert saved.active_archive_binding_id == binding.id
    assert saved.writer_credential_secret_id == writer.id
    assert saved.reader_credential_secret_id == reader.id

    # Split-permission user CAN toggle archive_enabled without changing credentials
    # and can read redacted credential names via get_overview/1.
    assert {:ok, toggled} =
             RecordingArchiveSettings.save_settings(
               %{archive_enabled: true},
               actor: recording_only
             )

    assert toggled.archive_enabled == true

    assert {:ok, overview} = RecordingArchiveSettings.get_overview(actor: recording_only)
    assert overview.storage_mode == :local_and_archive
    assert overview.archive_ready? == true
    assert overview.writer_credential.name == writer.name
    assert overview.reader_credential.name == reader.name

    # AuditHistory includes RecordingArchiveSettings PaperTrail versions with actor attribution.
    entries =
      AuditHistory.list_recent(
        actor: admin,
        resource_types: [RecordingArchiveSettings],
        limit: 10
      )

    assert length(entries) >= 2
    assert Enum.all?(entries, &(&1.resource == RecordingArchiveSettings))

    # CredentialUsage reports both slots and GuardCredentialDestroy refuses deletion.
    assert {:ok, writer_usage} = CredentialUsage.for_secret(writer.id, actor: admin)

    assert writer_usage.consumers == [
             %Consumer{
               kind: :recording_archive_settings,
               id: "deployment",
               label: "Camera archive (writer)",
               slot: :writer
             }
           ]

    assert {:error, delete_err} =
             writer
             |> Ash.Changeset.for_destroy(:destroy_permanently, %{confirm_secret_id: writer.id})
             |> Ash.destroy(actor: admin)

    assert Exception.message(delete_err) =~ "credential_in_use"
  end

  test "NVRArchiveReceipt is append-only, idempotent, refuses conflicts, and restricts FK deletion" do
    system = SystemActor.system(:nvr_receipt_test)
    viewer = %{id: "viewer-1", role: :admin, permissions: MapSet.new(["settings.recording.view"])}

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "receipts-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "example-archive",
          namespace: "recordings/v1"
        },
        actor: system
      )

    block_key = String.duplicate("e", 64)

    receipt_bytes =
      Jason.encode!(%{
        "storage_id" => @storage_id_primary,
        "block_key" => block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => 1_763_200_010_000,
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "recordings/v1/#{@storage_id_primary}/#{block_key}/init.mp4",
            "length" => 2048,
            "sha256" => String.duplicate("1", 64),
            "etag" => "\"etag-1\""
          }
        ]
      })

    assert {:ok, first} = NVRArchiveReceipt.record(binding.id, receipt_bytes, actor: system)
    assert first.storage_id == @storage_id_primary
    assert first.block_key == block_key
    assert first.archive_binding_id == binding.id
    assert first.destination_sha256 == binding.destination_sha256
    assert is_nil(first.recording_block_id)

    # Identical bytes return the existing row idempotently.
    assert {:ok, retry} = NVRArchiveReceipt.record(binding.id, receipt_bytes, actor: system)
    assert retry.id == first.id
    assert retry.recorded_at == first.recorded_at

    # Differing bytes for the same (storage_id, block_key, archive_binding_id) are refused and logged.
    conflicting_bytes =
      Jason.encode!(%{
        "storage_id" => @storage_id_primary,
        "block_key" => block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => 1_763_200_099_000,
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "recordings/v1/#{@storage_id_primary}/#{block_key}/init.mp4",
            "length" => 4096,
            "sha256" => String.duplicate("2", 64),
            "etag" => "\"etag-2\""
          }
        ]
      })

    log =
      capture_log(fn ->
        assert {:error, err} =
                 NVRArchiveReceipt.record(binding.id, conflicting_bytes, actor: system)

        assert Exception.message(err) =~ "conflicts"
      end)

    assert log =~ "NVR archive receipt conflict"

    # Retained row is untouched and readable under settings.recording.view.
    assert {:ok, [retained]} = Ash.read(NVRArchiveReceipt, actor: viewer)
    assert retained.id == first.id
    assert retained.receipt_bytes == receipt_bytes

    # Receipt version 2 persists per-object version_id (both string and nil) cleanly under
    # camera_nvr_archive_receipts_bounds without stripping version_id.
    v2_block_key = String.duplicate("f", 64)

    v2_receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => @storage_id_primary,
        "block_key" => v2_block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => 1_763_200_020_000,
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "recordings/v1/#{@storage_id_primary}/#{v2_block_key}/init.mp4",
            "length" => 2048,
            "sha256" => String.duplicate("3", 64),
            "etag" => "\"etag-v2-init\"",
            "version_id" => "synth-ver-0001"
          },
          %{
            "name" => "media.m4s",
            "key" => "recordings/v1/#{@storage_id_primary}/#{v2_block_key}/media.m4s",
            "length" => 8192,
            "sha256" => String.duplicate("4", 64),
            "etag" => "\"etag-v2-media\"",
            "version_id" => nil
          }
        ]
      })

    assert {:ok, v2_recorded} =
             NVRArchiveReceipt.record(binding.id, v2_receipt_bytes, actor: system)

    assert {:ok, [v2_reloaded]} =
             NVRArchiveReceipt
             |> Ash.Query.filter(id == ^v2_recorded.id)
             |> Ash.read(actor: viewer)

    assert [v2_init, v2_media] = v2_reloaded.objects
    assert v2_init["version_id"] == "synth-ver-0001"
    assert Map.fetch(v2_media, "version_id") == {:ok, nil}

    # Resource exposes no update or destroy actions.
    action_types =
      NVRArchiveReceipt
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.sort()

    assert action_types == [:create, :read]

    # Database restrictive FK prevents deleting a referenced ArchiveBinding.
    assert_raise Postgrex.Error, fn ->
      SQL.query!(
        Repo,
        "DELETE FROM platform.camera_archive_bindings WHERE id = $1",
        [Ecto.UUID.dump!(binding.id)]
      )
    end
  end

  test "RecordingOperation allows one terminal transition and marks expired running rows outcome_unknown" do
    system = SystemActor.system(:nvr_operation_test)

    viewer = %{
      id: "viewer-op",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view"])
    }

    now = DateTime.utc_now()

    assert {:ok, expired_running} =
             RecordingOperation.start(
               %{
                 kind: :capture,
                 actor_id: "admin-1",
                 member_name: "serviceradar-nvr-0",
                 storage_id: @storage_id_primary,
                 started_at: DateTime.shift(now, minute: -1),
                 deadline_at: DateTime.shift(now, second: -5)
               },
               actor: system
             )

    assert {:ok, loaded_expired} = RecordingOperation.get_by_id(expired_running.id, actor: viewer)
    assert loaded_expired.state == :running
    assert loaded_expired.effective_state == :outcome_unknown

    assert {:ok, active_op} =
             RecordingOperation.start(
               %{
                 kind: :destination_test,
                 actor_id: "admin-1",
                 member_name: "serviceradar-nvr-0",
                 started_at: now,
                 deadline_at: DateTime.shift(now, minute: 1)
               },
               actor: system
             )

    assert {:ok, loaded_active} = RecordingOperation.get_by_id(active_op.id, actor: viewer)
    assert loaded_active.effective_state == :running

    # First terminal transition succeeds.
    assert {:ok, completed} =
             RecordingOperation.complete(
               active_op,
               %{state: :succeeded, result_summary: %{"stage" => "readback_verified"}},
               actor: system
             )

    assert completed.state == :succeeded
    assert completed.finished_at

    # Second terminal transition is refused.
    assert {:error, _} =
             RecordingOperation.complete(
               completed,
               %{state: :failed, error_class: "late_overwrite"},
               actor: system
             )
  end

  test "RecordingBlocks.operator_page/3 returns newest-first keyset pages of 25 with projected fields only" do
    ctx = create_camera_with_blocks(28)

    viewer = %{
      id: "viewer-blocks",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view"])
    }

    assert {:ok, %Keyset{} = page1} =
             RecordingBlocks.operator_page(ctx.source.id, [], actor: viewer)

    assert length(page1.results) == 25
    assert page1.more? == true

    first_row = hd(page1.results)
    assert is_binary(first_row.block_key)
    assert first_row.state == :open_local
    assert match?(%Ash.NotLoaded{}, first_row.descriptor)
    assert match?(%Ash.NotLoaded{}, first_row.upload_token)

    after_cursor = List.last(page1.results).__metadata__.keyset

    assert {:ok, %Keyset{} = page2} =
             RecordingBlocks.operator_page(ctx.source.id, after_cursor, actor: viewer)

    assert length(page2.results) == 3
    assert page2.more? == false

    all_ids = Enum.map(page1.results ++ page2.results, & &1.id)
    assert length(Enum.uniq(all_ids)) == 28

    # Optional storage_ids filter and scope.permissions propagation work without explicit actor:.
    scoped_viewer = %{
      user: %{id: "viewer-scoped", role: :operator},
      permissions: MapSet.new(["settings.recording.view"])
    }

    assert {:ok, %Keyset{} = filtered} =
             RecordingBlocks.operator_page(
               ctx.source.id,
               [storage_ids: [@storage_id_secondary]],
               scope: scoped_viewer
             )

    assert length(filtered.results) == 3
    assert Enum.all?(filtered.results, &(&1.storage_id == @storage_id_secondary))
  end

  test "E1 retention settings persist confirmations, enforce SQL check & FK constraints, and compute live usage_summary/1" do
    system = SystemActor.system(:nvr_retention_integration_test)

    admin = %{
      id: "admin-retention-db",
      role: :admin,
      permissions:
        MapSet.new([
          "settings.recording.view",
          "settings.recording.manage",
          "settings.credentials.manage"
        ])
    }

    recording_only = %{
      id: "operator-retention-db",
      role: :operator,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    slug = "ret-db-#{System.unique_integer([:positive])}"

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: slug,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "example-archive",
          namespace: "recordings/v1"
        },
        actor: admin
      )

    writer = create_s3_secret("Retention Writer S3")
    retention = create_s3_secret("Retention Delete S3")

    # Split-permission operator cannot set retention_credential_secret_id.
    assert {:error, split_err} =
             RecordingArchiveSettings.save_settings(
               %{retention_credential_secret_id: retention.id},
               actor: recording_only
             )

    assert Exception.message(split_err) =~ "settings.credentials.manage"

    t_confirm = ~U[2026-11-16 14:00:00.123456Z]

    # Save full E1 settings including shorter archive retention than max_local_age (advisory warning, accepted)
    assert {:ok, saved} =
             RecordingArchiveSettings.save_settings(
               %{
                 active_archive_binding_id: binding.id,
                 writer_credential_secret_id: writer.id,
                 retention_credential_secret_id: retention.id,
                 archive_enabled: true,
                 local_high_water_percent: 88,
                 local_low_water_percent: 75,
                 max_local_age_mode: :limited,
                 max_local_age_seconds: 172_800,
                 local_window_alert_mode: :disabled,
                 local_window_alert_seconds: nil,
                 local_only_full_policy: :overwrite_oldest,
                 local_only_target_mode: :none,
                 local_only_retention_target_seconds: nil,
                 local_only_max_age_mode: :limited,
                 local_only_max_age_seconds: 604_800,
                 archive_retention_mode: :limited,
                 archive_retention_days: 1,
                 object_budget_mode: :limited,
                 object_budget_bytes: 10_737_418_240,
                 object_high_water_percent: 92,
                 object_low_water_percent: 82,
                 object_capacity_policy: :reap_oldest
               },
               actor: admin,
               now: t_confirm
             )

    assert saved.retention_credential_secret_id == retention.id
    assert saved.local_only_full_policy == :overwrite_oldest
    assert saved.local_only_full_policy_confirmed_by_id == "admin-retention-db"
    assert saved.local_only_full_policy_confirmed_at == t_confirm
    assert saved.object_capacity_policy == :reap_oldest
    assert saved.object_capacity_policy_confirmed_by_id == "admin-retention-db"
    assert saved.object_capacity_policy_confirmed_at == t_confirm
    assert RecordingArchiveSettings.shorter_archive_than_local?(saved) == true

    # Updating unrelated fields preserves existing confirmation actor & timestamp.
    assert {:ok, preserved} =
             RecordingArchiveSettings.save_settings(
               %{local_high_water_percent: 90},
               actor: recording_only,
               now: DateTime.shift(t_confirm, minute: 5)
             )

    assert preserved.local_only_full_policy_confirmed_by_id == "admin-retention-db"
    assert preserved.local_only_full_policy_confirmed_at == t_confirm
    assert preserved.object_capacity_policy_confirmed_by_id == "admin-retention-db"
    assert preserved.object_capacity_policy_confirmed_at == t_confirm

    # CredentialUsage + GuardCredentialDestroy + Postgres restrictive FK protect retention secret.
    assert {:ok, ret_usage} = CredentialUsage.for_secret(retention.id, actor: admin)

    assert ret_usage.consumers == [
             %Consumer{
               kind: :recording_archive_settings,
               id: "deployment",
               label: "Camera archive (retention)",
               slot: :retention
             }
           ]

    assert {:error, guard_err} =
             retention
             |> Ash.Changeset.for_destroy(:destroy_permanently, %{confirm_secret_id: retention.id})
             |> Ash.destroy(actor: admin)

    assert Exception.message(guard_err) =~ "credential_in_use"

    assert_constraint_violation(
      "camera_archive_settings_retention_secret_fkey",
      "DELETE FROM platform.network_credential_secrets WHERE id = $1",
      [Ecto.UUID.dump!(retention.id)]
    )

    # Verify every SQL CHECK constraint rejects invalid mode+value, watermark, and confirmation states.
    for {constraint_name, set_sql} <- [
          {"camera_archive_settings_local_watermarks",
           "local_high_water_percent = 85, local_low_water_percent = 81"},
          {"camera_archive_settings_max_local_age",
           "max_local_age_mode = 'unlimited', max_local_age_seconds = 86400"},
          {"camera_archive_settings_max_local_age",
           "max_local_age_mode = 'limited', max_local_age_seconds = NULL"},
          {"camera_archive_settings_local_window_alert",
           "local_window_alert_mode = 'enabled', local_window_alert_seconds = NULL"},
          {"camera_archive_settings_local_only_full_policy",
           "local_only_full_policy = 'overwrite_oldest', local_only_full_policy_confirmed_by_id = NULL"},
          {"camera_archive_settings_local_only_full_policy",
           "local_only_full_policy = NULL, local_only_full_policy_confirmed_by_id = 'dangling-actor'"},
          {"camera_archive_settings_local_only_target",
           "local_only_target_mode = 'target', local_only_retention_target_seconds = NULL"},
          {"camera_archive_settings_local_only_max_age",
           "local_only_max_age_mode = 'unlimited', local_only_max_age_seconds = 3600"},
          {"camera_archive_settings_local_only_max_age",
           "local_only_max_age_mode = 'limited', local_only_max_age_seconds = NULL"},
          {"camera_archive_settings_archive_retention",
           "archive_retention_mode = 'unlimited', archive_retention_days = 30"},
          {"camera_archive_settings_archive_retention",
           "archive_retention_mode = 'limited', archive_retention_days = NULL"},
          {"camera_archive_settings_object_budget",
           "object_budget_mode = 'limited', object_budget_bytes = 1024"},
          {"camera_archive_settings_object_watermarks",
           "object_high_water_percent = 96, object_low_water_percent = 80"},
          {"camera_archive_settings_object_capacity_policy",
           "object_budget_mode = 'limited', object_capacity_policy = NULL, object_capacity_policy_confirmed_by_id = NULL, object_capacity_policy_confirmed_at = NULL"}
        ] do
      assert_constraint_violation(
        constraint_name,
        "UPDATE platform.camera_recording_archive_settings SET #{set_sql} WHERE id = 'deployment'",
        []
      )
    end

    # Insert real NVRArchiveReceipt and RecordingBlock rows and verify usage_summary/1 end-to-end.
    _ctx = create_camera_with_blocks(6)
    now_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)

    for {idx, len_a, len_b, age_ms} <- [
          {1, 1_048_576, 4_194_304, 3_600_000},
          {2, 524_288, 2_097_152, 172_800_000}
        ] do
      bkey =
        :sha256
        |> :crypto.hash("ret-summary-#{slug}-#{idx}")
        |> Base.encode16(case: :lower)

      bytes =
        Jason.encode!(%{
          "version" => 2,
          "storage_id" => @storage_id_primary,
          "block_key" => bkey,
          "destination_sha256" => binding.destination_sha256,
          "verified_at_ms" => now_ms - age_ms,
          "objects" => [
            %{
              "name" => "init.mp4",
              "key" => "recordings/v1/#{@storage_id_primary}/#{bkey}/init.mp4",
              "length" => len_a,
              "sha256" => String.duplicate("a", 64),
              "etag" => "\"etag-a-#{idx}\""
            },
            %{
              "name" => "media.m4s",
              "key" => "recordings/v1/#{@storage_id_primary}/#{bkey}/media.m4s",
              "length" => len_b,
              "sha256" => String.duplicate("b", 64),
              "etag" => "\"etag-b-#{idx}\""
            }
          ]
        })

      assert {:ok, _} = NVRArchiveReceipt.record(binding.id, bytes, actor: system)
    end

    assert {:ok, summary} = RetentionCalculator.usage_summary(actor: recording_only)
    assert summary.archive.archive_used_bytes == 7_864_320
    assert summary.archive.archived_block_count == 2
    assert summary.archive.archived_object_count == 4
    assert summary.archive.trailing_24h_bytes == 5_242_880
    assert summary.archive.trailing_7d_bytes == 7_864_320
    assert summary.archive.rate_basis == :measured
    assert summary.local_blocks.total_reserved_blocks >= 6
    assert summary.object_retention_enforced? == true
    assert summary.shorter_archive_than_local? == true
    assert summary.object_projection.object_budget_mode == :limited

    # Clearing local_only_full_policy clears confirmation actor and timestamp cleanly.
    assert {:ok, cleared} =
             RecordingArchiveSettings.save_settings(
               %{local_only_full_policy: nil},
               actor: admin
             )

    assert is_nil(cleared.local_only_full_policy)
    assert is_nil(cleared.local_only_full_policy_confirmed_by_id)
    assert is_nil(cleared.local_only_full_policy_confirmed_at)
  end

  defp assert_constraint_violation(expected_constraint, sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{constraint: ^expected_constraint}}} =
             Repo.query(sql, params, mode: :savepoint)
  end

  defp create_camera_with_blocks(total) do
    ctx = Fixtures.context()
    {:ok, session} = Fixtures.open(ctx)
    {:ok, session} = Fixtures.activate(ctx, session, "media-nvr-page")
    owner = Fixtures.owner(ctx)

    claim =
      RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, ctx.opts)
      |> Ash.create!(ctx.opts)

    for index <- 0..(total - 4) do
      insert_block(ctx, owner, session, claim.id, 1, @storage_id_primary, index)
    end

    for index <- 0..2 do
      insert_block(ctx, owner, session, claim.id, 2, @storage_id_secondary, index)
    end

    ctx
  end

  defp insert_block(ctx, owner, session, claim_id, recorder_epoch, storage_id, sequence) do
    block_key =
      :sha256
      |> :crypto.hash("#{claim_id}:#{recorder_epoch}:#{sequence}")
      |> Base.encode16(case: :lower)

    base_ts =
      DateTime.shift(~U[2026-11-15 10:00:00.000000Z],
        second: recorder_epoch * 100 + sequence
      )

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_recording_blocks (
        id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
        recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
        storage_id, clock, state, upload_epoch, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6,
        $7, $8, $9, $10, $11,
        $12, $13::jsonb, 'open_local', 0, $14, $14
      )
      """,
      [
        Ecto.UUID.dump!(Ash.UUIDv7.generate()),
        block_key,
        Ecto.UUID.dump!(ctx.source.id),
        Ecto.UUID.dump!(ctx.profile.id),
        Ecto.UUID.dump!(owner.id),
        owner.epoch,
        Ecto.UUID.dump!(claim_id),
        recorder_epoch,
        sequence,
        Ecto.UUID.dump!(session.id),
        session.media_ingest_id,
        Ecto.UUID.dump!(storage_id),
        %{"timescale" => 90_000},
        base_ts
      ]
    )
  end

  defp create_s3_secret(label) do
    {:ok, built} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICACCESSKEY01",
          "secret_access_key" => "invented-synthetic-secret-material"
        },
        %{name: "#{label}-#{System.unique_integer([:positive])}"}
      )

    NetworkCredentialSecret.create_secret!(
      built,
      actor: SystemActor.system(:nvr_operator_settings_test)
    )
  end

  defp create_non_s3_secret(label) do
    NetworkCredentialSecret.create_secret!(
      %{
        name: "#{label}-#{System.unique_integer([:positive])}",
        provider: "synthetic-api",
        credential_kind: :api_token,
        secret_payload: "invented-token-payload"
      },
      actor: SystemActor.system(:nvr_operator_settings_test)
    )
  end
end
