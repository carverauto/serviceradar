defmodule ServiceRadar.Camera.CameraRecordingVantageHooksIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VisualWorkerReadGrants
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadar.TestSupport
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  @clock %{
    "clock_epoch" => "synthetic-clock-epoch",
    "timebase" => 90_000,
    "dts_source" => "pts_no_reordering",
    "utc_mapping" => "unknown"
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "CameraRecordingPolicy persists visual_index_* fields with PaperTrail versions and SQL CHECK constraints (1.1)" do
    actor = SystemActor.system(:semantic_policy_test)
    {cam, prof} = create_camera_and_profile(actor, "Gate North Camera")

    admin = %{
      id: "admin-vi-policy",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    assert {:ok, policy} =
             CameraRecordingPolicies.upsert_policy(
               %{
                 camera_source_id: cam.id,
                 stream_profile_id: prof.id,
                 mode: :continuous,
                 nvr_member: "nvr-0",
                 storage: :local_only,
                 visual_index_mode: :keyframes,
                 visual_index_min_interval_ms: 3_000,
                 visual_index_max_frames_per_block: 32
               },
               actor: admin
             )

    assert policy.visual_index_mode == :keyframes
    assert policy.visual_index_min_interval_ms == 3_000
    assert policy.visual_index_max_frames_per_block == 32

    assert %{rows: [[version_count]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM platform.camera_recording_policies_versions WHERE version_source_id = $1",
               [Ecto.UUID.dump!(policy.id)]
             )

    assert version_count >= 1

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE platform.camera_recording_policies SET visual_index_min_interval_ms = 100 WHERE id = $1",
               [Ecto.UUID.dump!(policy.id)]
             )
  end

  test "freeze_and_catalog and freeze_historical write no visual index jobs whatever the policy's visual_index_mode",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_outbox_test)
    {cam_on, prof_on} = create_camera_and_profile(actor, "Loading Bay Camera")
    {cam_off, prof_off} = create_camera_and_profile(actor, "Lobby Off Camera")

    admin = %{
      id: "admin-outbox",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    {:ok, _pol_on} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam_on.id,
          stream_profile_id: prof_on.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_only,
          visual_index_mode: :keyframes,
          visual_index_min_interval_ms: 2_000,
          visual_index_max_frames_per_block: 16
        },
        actor: admin
      )

    {:ok, _pol_off} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam_off.id,
          stream_profile_id: prof_off.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_only,
          visual_index_mode: :off
        },
        actor: admin
      )

    {owner_on, claim_on, block_on} = reserve_synthetic_block(cam_on, prof_on, actor)
    assert {:ok, :released} = RecorderOwnership.release(owner_on, claim_on, actor: actor)

    assert {:ok, entry_on} =
             RecordingBlocks.freeze_historical(
               block_on,
               multi_keyframe_descriptor(block_on),
               %{
                 timeline_start_us: 1_750_000_000_000_000,
                 timeline_end_us: 1_750_000_006_000_000,
                 time_basis: :received,
                 local_state: :present,
                 archive_state: :not_required
               },
               actor: actor,
               reconciler_ready?: true
             )

    {owner_off, claim_off, block_off} = reserve_synthetic_block(cam_off, prof_off, actor)

    assert {:ok, entry_off} =
             RecordingBlocks.freeze_and_catalog(
               owner_off,
               claim_off,
               block_off,
               multi_keyframe_descriptor(block_off),
               %{
                 first_unit_pts: 0,
                 first_unit_received_at: ~U[2026-11-17 12:00:00.000000Z],
                 reanchored: false
               },
               actor: actor
             )

    for entry <- [entry_on, entry_off] do
      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM platform.camera_visual_index_jobs WHERE catalog_entry_id = $1",
                 [Ecto.UUID.dump!(entry.id)]
               )
    end
  end

  test "VisualWorkerReadGrants issues CNPG SecretBroker reader-only archive grants with zero leaked secrets and 410s quarantined blocks (1.6)",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_grants_test)
    {cam, prof} = create_camera_and_profile(actor, "Archive Grant Camera")

    admin = %{
      id: "admin-grants",
      role: :admin,
      permissions:
        MapSet.new([
          "settings.recording.view",
          "settings.recording.manage",
          "settings.credentials.manage"
        ])
    }

    synthetic_secret = String.duplicate("s", 32)
    slug = "vi-grant-#{System.unique_integer([:positive])}"

    {:ok, built_secret} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "AKIA_SYNTHETIC_READER",
          "secret_access_key" => synthetic_secret
        },
        %{name: "s3-reader-#{slug}"}
      )

    secret = NetworkCredentialSecret.create_secret!(built_secret, actor: actor)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: slug,
          endpoint: "https://objects.example.com",
          region: "us-east-1",
          bucket: "synthetic-archive",
          namespace: "nvr/archive-v2"
        },
        actor: admin
      )

    {:ok, _settings} =
      RecordingArchiveSettings.save_settings(
        %{
          archive_enabled: true,
          active_archive_binding_id: binding.id,
          writer_credential_secret_id: secret.id,
          reader_credential_secret_id: secret.id
        },
        actor: admin
      )

    {:ok, _pol} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_and_archive,
          visual_index_mode: :keyframes
        },
        actor: admin
      )

    {owner, claim, block} = reserve_synthetic_block(cam, prof, actor)
    desc = multi_keyframe_descriptor(block)

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        owner,
        claim,
        block,
        desc,
        %{
          first_unit_pts: 0,
          first_unit_received_at: ~U[2026-11-17 12:05:00.000000Z],
          reanchored: false
        },
        actor: actor
      )

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => entry.storage_id,
        "block_key" => entry.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond),
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "#{binding.namespace}/#{entry.storage_id}/#{entry.block_key}/init.mp4",
            "length" => desc["init"]["length"],
            "sha256" => desc["init"]["sha256"],
            "etag" => "\"init-etag\"",
            "version_id" => "v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{entry.storage_id}/#{entry.block_key}/media.m4s",
            "length" => desc["media"]["length"],
            "sha256" => desc["media"]["sha256"],
            "etag" => "\"media-etag\"",
            "version_id" => "v1"
          }
        ]
      })

    {:ok, receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: entry.recording_block_id},
        actor: actor
      )

    now = DateTime.utc_now()

    {:ok, verified_entry} =
      entry
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: receipt.id,
          archive_binding_id: binding.id
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    installation = %{purpose: :media_worker}

    req = %{
      "schema_version" => 1,
      "job_id" => "caller-job-1",
      "catalog_entry_id" => to_string(verified_entry.id),
      "descriptor_sha256" => verified_entry.descriptor_sha256
    }

    assert {:ok, plan} = VisualWorkerReadGrants.issue_read_grant(installation, req)
    assert plan.backing == :archive
    assert Enum.sort(plan.grant["allowed_methods"]) == ["GET", "HEAD"]
    assert is_binary(plan.init["presigned_url"])
    assert is_binary(plan.media["presigned_url"])
    assert plan.archive["init_presigned_url"] == plan.init["presigned_url"]
    assert plan.archive["media_presigned_url"] == plan.media["presigned_url"]
    assert plan.init["presigned_url"] =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    assert plan.init["presigned_url"] =~ "X-Amz-SignedHeaders=host"
    assert plan.init["presigned_url"] =~ "versionId=v1"
    refute inspect(plan) =~ synthetic_secret
    refute Jason.encode!(plan) =~ synthetic_secret
    assert plan.credential.secret_access_key == synthetic_secret
    assert plan.job_id == "caller-job-1"

    assert Enum.map(plan.fragments, & &1["sequence"]) ==
             Enum.map(desc["fragments"], & &1["sequence"])

    # A quarantined block is gone, and the digest is still checked first
    {:ok, _quarantined} =
      verified_entry
      |> Ash.Changeset.for_update(
        :quarantine_in_place,
        %{
          quarantine_reason: :binding_compromised,
          quarantine_receipt: %{"reason" => "synthetic_compromise"},
          quarantined_bytes: 3_072,
          local_state_at: now,
          archive_state: :not_required,
          archive_state_at: now
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert {:error, :descriptor_sha256_mismatch} =
             VisualWorkerReadGrants.issue_read_grant(
               installation,
               Map.put(req, "descriptor_sha256", String.duplicate("fe", 32))
             )

    assert {:error, :recording_gone} = VisualWorkerReadGrants.issue_read_grant(installation, req)
  end

  defp create_camera_and_profile(actor, display_name) do
    uid = Ecto.UUID.generate()

    {:ok, cam} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-cam-#{uid}",
          vendor: "synthetic",
          vendor_camera_id: uid,
          display_name: display_name,
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        },
        actor: actor
      )

    {:ok, prof} =
      StreamProfile.create_profile(
        %{
          camera_source_id: cam.id,
          profile_name: "main",
          relay_eligible: true
        },
        actor: actor
      )

    {cam, prof}
  end

  defp reserve_synthetic_block(cam, prof, actor) do
    opts = [actor: actor]

    {:ok, session} =
      RelaySessionManager.request_open(cam.id, prof.id,
        actor: actor,
        control_gateway_resolver: fn _a, g -> {:ok, g} end,
        dispatch_open: fn _a, _p, o, _r -> {:ok, o[:command_id]} end
      )

    active =
      if session.status == :active and is_binary(session.media_ingest_id) do
        session
      else
        ingest_id = session.media_ingest_id || Ecto.UUID.generate()

        assignment =
          Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

        {:ok, activated} =
          RelaySessionLifecycle.activate_session(
            session.id,
            ingest_id,
            assignment,
            opts
          )

        activated
      end

    owner =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^cam.id and stream_profile_id == ^prof.id)
      |> Ash.read_one!(opts)

    {:ok, claim} =
      case ServiceRadar.Camera.RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id and state == :active)
           |> Ash.read_one!(opts) do
        nil ->
          RecorderOwnership.acquire(
            owner,
            Ecto.UUID.generate(),
            active.media_ingest_id,
            Ecto.UUID.generate(),
            30_000,
            opts
          )

        existing_claim ->
          {:ok, existing_claim}
      end

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, @clock, opts)
    {owner, claim, block}
  end

  defp multi_keyframe_descriptor(block) do
    init_sha = sha256("synthetic-init-#{block.id}")
    f0_sha = sha256("synthetic-f0-#{block.id}")
    f1_sha = sha256("synthetic-f1-#{block.id}")
    f2_sha = sha256("synthetic-f2-#{block.id}")
    media_sha = sha256("synthetic-media-#{block.id}")

    desc = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 256, "sha256" => init_sha},
      "media" => %{"length" => 3_072, "sha256" => media_sha},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 1_024,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "sha256" => f0_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 1,
          "offset" => 1_024,
          "length" => 1_024,
          "start_ns" => 1_000_000_000,
          "duration_ns" => 1_500_000_000,
          "sha256" => f1_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 2,
          "offset" => 2_048,
          "length" => 1_024,
          "start_ns" => 2_500_000_000,
          "duration_ns" => 2_000_000_000,
          "sha256" => f2_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }

    {:ok, _} = Descriptor.encode(desc)
    desc
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
