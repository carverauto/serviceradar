defmodule ServiceRadarWebNGWeb.ControlPlaneMediaWorkerGrantsDBTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicy
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
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarRecordingMetadata.Descriptor
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @account_token "synthetic-worker-grants-account-token-more-than-32b"
  @media_token "synthetic-worker-grants-media-token-more-than-32bytes"
  @entitlement_token "synthetic-worker-grants-entitlement-token-more-32b"
  @media_worker_token "synthetic-worker-grants-media-worker-token-more-32"
  @vantage_worker_token "synthetic-worker-grants-vantage-worker-token-more-32b"
  @auth_header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @worker_gen_header "x-serviceradar-media-worker-generation"
  @vantage_gen_header "x-serviceradar-vantage-worker-generation"
  @storage_id "00000000-0000-4000-8000-000000000601"
  @base_dt ~U[2026-11-17 10:00:00.000000Z]

  setup %{tmp_dir: directory} do
    Fixtures.recording_recovery_gate(directory)
    previous_runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    previous_issuer = Application.get_env(:serviceradar_web_ng, :control_plane_media_worker_grants_issuer)
    deployment_ref = Ecto.UUID.generate()

    Application.delete_env(:serviceradar_web_ng, :control_plane_media_worker_grants_issuer)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @media_token, deployment_ref: deployment_ref, generation: "1"],
      entitlements: [token: @entitlement_token, deployment_ref: deployment_ref, generation: "1"],
      media_worker: [token: @media_worker_token, deployment_ref: deployment_ref, generation: "1"],
      vantage_worker: [token: @vantage_worker_token, deployment_ref: deployment_ref, generation: "1"]
    )

    on_exit(fn ->
      if previous_runtime,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous_runtime),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)

      if previous_issuer,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_media_worker_grants_issuer, previous_issuer),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_media_worker_grants_issuer)
    end)

    actor = system_actor()
    insert_local_storage_binding(@storage_id)

    %{actor: actor, deployment_ref: deployment_ref}
  end

  test "issues reader-only archive and analysis_read local grants without leaking secrets, and returns 410 recording_gone on deleted/quarantined blocks",
       %{actor: actor, deployment_ref: deployment_ref} do
    ctx = seed_grant_fixtures(actor)

    # 1. Cross-domain tokens rejected with 401
    for wrong <- [@account_token, @media_token, @entitlement_token] do
      denied =
        post_grant(
          deployment_ref,
          %{
            "schema_version" => 1,
            "job_id" => ctx.archive_job.id,
            "catalog_entry_id" => ctx.archive_entry.id,
            "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
          },
          wrong
        )

      assert denied.status == 401
    end

    # 2. Archive-backed verified block -> 200 OK with reader-only grant and redacted credentials
    archive_conn =
      post_grant(deployment_ref, %{
        "schema_version" => 1,
        "job_id" => ctx.archive_job.id,
        "catalog_entry_id" => ctx.archive_entry.id,
        "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
      })

    assert archive_conn.status == 200
    assert get_resp_header(archive_conn, "cache-control") == ["no-store"]
    refute archive_conn.resp_body =~ ctx.secret_access_key
    refute archive_conn.resp_body =~ @media_worker_token

    archive_body = Jason.decode!(archive_conn.resp_body)
    assert archive_body["backing"] == "archive"
    assert archive_body["source"] == "archive"
    assert archive_body["init_sha256"] == ctx.init_sha
    assert archive_body["grant"]["role"] == "reader"
    assert Enum.sort(archive_body["grant"]["allowed_methods"]) == ["GET", "HEAD"]
    refute Map.has_key?(archive_body["credential"], "access_key_id")
    refute Map.has_key?(archive_body["credential"], "secret_access_key")
    refute Map.has_key?(archive_body["credential"], "session_token")

    init_presigned = archive_body["archive"]["init_presigned_url"]
    media_presigned = archive_body["archive"]["media_presigned_url"]
    assert is_binary(init_presigned)
    assert is_binary(media_presigned)
    assert archive_body["init"]["presigned_url"] == init_presigned
    assert archive_body["media"]["presigned_url"] == media_presigned

    init_q = init_presigned |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert init_q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert init_q["X-Amz-SignedHeaders"] == "host"
    assert init_q["X-Amz-Expires"] == "300"
    assert init_q["versionId"] == "synth-init-v1"
    assert init_q["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/

    media_q = media_presigned |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert media_q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert media_q["X-Amz-SignedHeaders"] == "host"
    assert media_q["X-Amz-Expires"] == "300"
    assert media_q["versionId"] == "synth-media-v1"
    assert media_q["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/

    assert [%{"sha256" => frag_sha}] = archive_body["fragments"]
    assert frag_sha == ctx.frag_sha
    assert is_list(archive_body["coalesced_ranges"])

    # 3. Local-only block -> 200 OK routed to analysis_read pool
    local_conn =
      post_grant(deployment_ref, %{
        "schema_version" => 1,
        "job_id" => ctx.local_job.id,
        "catalog_entry_id" => ctx.local_entry.id,
        "descriptor_sha256" => ctx.local_entry.descriptor_sha256
      })

    assert local_conn.status == 200
    local_body = Jason.decode!(local_conn.resp_body)
    assert local_body["source"] == "local"
    assert local_body["read_pool"] == "analysis_read"
    assert local_body["local"]["pool"] == "analysis_read"

    # 4. Terminally reclaimed/deleted block -> 410 Gone and job cancelled
    now = DateTime.utc_now()

    ctx.local_entry
    |> Ash.Changeset.for_update(
      :transition_archive_state,
      %{archive_state: :not_required, archive_state_at: now},
      actor: actor
    )
    |> Ash.update!(actor: actor)
    |> Ash.Changeset.for_update(
      :transition_local_state,
      %{local_state: :reclaimed, local_state_at: now},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    gone_conn =
      post_grant(deployment_ref, %{
        "schema_version" => 1,
        "job_id" => ctx.local_job.id,
        "catalog_entry_id" => ctx.local_entry.id,
        "descriptor_sha256" => ctx.local_entry.descriptor_sha256
      })

    assert gone_conn.status == 410
    assert Jason.decode!(gone_conn.resp_body) == %{"status" => "recording_gone"}

    {:ok, refreshed_job} = VisualIndexJob.get_by_id(ctx.local_job.id, actor: actor)
    assert refreshed_job.state == :cancelled
  end

  test "issues read grant for VantageJob via :vantage_worker auth and cancels VantageJob on 410 recording_gone", %{
    actor: actor,
    deployment_ref: deployment_ref
  } do
    ctx = seed_grant_fixtures(actor)

    {:ok, vantage_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.0",
          catalog_entry_id: ctx.archive_entry.id,
          camera_source_id: ctx.archive_entry.camera_source_id,
          stream_profile_id: ctx.archive_entry.stream_profile_id,
          target_key: "track:vantage-db-1",
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          descriptor_sha256: ctx.archive_entry.descriptor_sha256,
          sampled_targets: [%{"target_key" => "track:vantage-db-1", "fragment_sequence" => 0}]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    ok_conn =
      post_vantage_grant(deployment_ref, %{
        "schema_version" => 1,
        "job_id" => vantage_job.id,
        "catalog_entry_id" => ctx.archive_entry.id,
        "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
      })

    assert ok_conn.status == 200
    body = Jason.decode!(ok_conn.resp_body)
    assert body["backing"] == "archive"
    assert Enum.map(body["fragments"], & &1["sequence"]) == [0]
    refute ok_conn.resp_body =~ ctx.secret_access_key

    {:ok, local_vantage_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.0",
          catalog_entry_id: ctx.local_entry.id,
          camera_source_id: ctx.local_entry.camera_source_id,
          stream_profile_id: ctx.local_entry.stream_profile_id,
          target_key: "track:vantage-db-gone",
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          descriptor_sha256: ctx.local_entry.descriptor_sha256,
          sampled_targets: [%{"target_key" => "track:vantage-db-gone", "fragment_sequence" => 0}]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    now = DateTime.utc_now()

    ctx.local_entry
    |> Ash.Changeset.for_update(:transition_local_state, %{local_state: :reclaimed, local_state_at: now}, actor: actor)
    |> Ash.update!(actor: actor)

    gone_conn =
      post_vantage_grant(deployment_ref, %{
        "schema_version" => 1,
        "job_id" => local_vantage_job.id,
        "catalog_entry_id" => ctx.local_entry.id,
        "descriptor_sha256" => ctx.local_entry.descriptor_sha256
      })

    assert gone_conn.status == 410
    assert Jason.decode!(gone_conn.resp_body) == %{"status" => "recording_gone"}
    assert %{state: :cancelled} = VantageJob.get_by_id!(local_vantage_job.id, actor: actor)
  end

  test "isolates :vantage_worker from VisualIndexJob while supporting SDK header carrier and Ramp 1 :media_worker VantageJob",
       %{
         actor: actor,
         deployment_ref: deployment_ref
       } do
    ctx = seed_grant_fixtures(actor)

    {:ok, vantage_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.0",
          catalog_entry_id: ctx.archive_entry.id,
          camera_source_id: ctx.archive_entry.camera_source_id,
          stream_profile_id: ctx.archive_entry.stream_profile_id,
          target_key: "track:vantage-sdk-header",
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          descriptor_sha256: ctx.archive_entry.descriptor_sha256,
          sampled_targets: [%{"target_key" => "track:vantage-sdk-header", "fragment_sequence" => 0}]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    # SDK wire format: @vantage_worker_token + x-serviceradar-media-worker-generation -> 200 on VantageJob
    sdk_ok_conn =
      post_grant(
        deployment_ref,
        %{
          "schema_version" => 1,
          "job_id" => vantage_job.id,
          "catalog_entry_id" => ctx.archive_entry.id,
          "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
        },
        @vantage_worker_token
      )

    assert sdk_ok_conn.status == 200
    assert Jason.decode!(sdk_ok_conn.resp_body)["backing"] == "archive"

    # Ramp 1 media-worker retains access to VantageJob
    ramp1_ok_conn =
      post_grant(
        deployment_ref,
        %{
          "schema_version" => 1,
          "job_id" => vantage_job.id,
          "catalog_entry_id" => ctx.archive_entry.id,
          "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
        },
        @media_worker_token
      )

    assert ramp1_ok_conn.status == 200

    # :vantage_worker cannot read VisualIndexJob via either generation header
    for conn <- [
          post_vantage_grant(
            deployment_ref,
            %{
              "schema_version" => 1,
              "job_id" => ctx.archive_job.id,
              "catalog_entry_id" => ctx.archive_entry.id,
              "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
            },
            @vantage_worker_token
          ),
          post_grant(
            deployment_ref,
            %{
              "schema_version" => 1,
              "job_id" => ctx.archive_job.id,
              "catalog_entry_id" => ctx.archive_entry.id,
              "descriptor_sha256" => ctx.archive_entry.descriptor_sha256
            },
            @vantage_worker_token
          )
        ] do
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"status" => "job_not_found"}
    end

    # :vantage_worker cannot cancel a reclaimed VisualIndexJob
    now = DateTime.utc_now()

    ctx.local_entry
    |> Ash.Changeset.for_update(:transition_local_state, %{local_state: :reclaimed, local_state_at: now}, actor: actor)
    |> Ash.update!(actor: actor)

    blocked_cancel_conn =
      post_vantage_grant(
        deployment_ref,
        %{
          "schema_version" => 1,
          "job_id" => ctx.local_job.id,
          "catalog_entry_id" => ctx.local_entry.id,
          "descriptor_sha256" => ctx.local_entry.descriptor_sha256
        },
        @vantage_worker_token
      )

    assert blocked_cancel_conn.status == 409
    assert Jason.decode!(blocked_cancel_conn.resp_body) == %{"status" => "job_not_found"}
    assert %{state: :pending} = VisualIndexJob.get_by_id!(ctx.local_job.id, actor: actor)
  end

  defp post_vantage_grant(deployment_ref, payload, token \\ @vantage_worker_token) do
    :post
    |> conn("/v1/media/workers/read-grants", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@auth_header, "Bearer " <> token)
    |> put_req_header(@deployment_header, deployment_ref)
    |> put_req_header(@vantage_gen_header, "1")
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp post_grant(deployment_ref, payload, token \\ @media_worker_token) do
    :post
    |> conn("/v1/media/workers/read-grants", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@auth_header, "Bearer " <> token)
    |> put_req_header(@deployment_header, deployment_ref)
    |> put_req_header(@worker_gen_header, "1")
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp seed_grant_fixtures(actor) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()
    secret_access_key = String.duplicate("m", 32)

    {:ok, built_secret} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICWORKERKEY",
          "secret_access_key" => secret_access_key
        },
        %{name: "Synthetic Worker Reader #{System.unique_integer([:positive])}"}
      )

    reader_secret = NetworkCredentialSecret.create_secret!(built_secret, opts)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "worker-dest-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-worker-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, _settings} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding.id,
          archive_enabled: true,
          writer_credential_secret_id: reader_secret.id,
          reader_credential_secret_id: reader_secret.id
        },
        opts
      )

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-wg-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Worker Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-worker",
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
          nvr_member: "serviceradar-nvr-0",
          storage: :local_only,
          visual_index_mode: :keyframes
        },
        opts
      )
      |> Ash.create(opts)

    live_ctx = open_claim(source, profile, @storage_id, key, opts)
    init_bytes = :binary.copy("init-box", 16)
    init_sha = sha256_hex(init_bytes)
    frag_bytes = :binary.copy("synthetic-fmp4-frag!", 20)
    frag_sha = sha256_hex(frag_bytes)

    block_0 = reserve_block(live_ctx, 0, "epoch-wg-1", opts)
    desc_0 = single_frag_descriptor(block_0, init_bytes, init_sha, frag_bytes, frag_sha, 0)

    {:ok, archive_entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_0,
        desc_0,
        %{first_unit_pts: 0, first_unit_received_at: @base_dt, reanchored: false},
        opts
      )

    receipt_0 =
      record_receipt(binding, block_0, @storage_id, init_bytes, init_sha, frag_bytes, frag_sha, actor)

    now = DateTime.utc_now()

    archive_entry =
      archive_entry
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: receipt_0.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)

    archive_job = ensure_job_for_entry(archive_entry, opts)

    block_1 = reserve_block(live_ctx, 1, "epoch-wg-1", opts)
    desc_1 = single_frag_descriptor(block_1, init_bytes, init_sha, frag_bytes, frag_sha, 2_000_000_000)

    {:ok, local_entry} =
      RecordingBlocks.freeze_and_catalog(
        live_ctx.owner,
        live_ctx.claim,
        block_1,
        desc_1,
        %{
          first_unit_pts: 180_000,
          first_unit_received_at: DateTime.shift(@base_dt, second: 2),
          reanchored: false
        },
        opts
      )

    local_job = ensure_job_for_entry(local_entry, opts)

    %{
      archive_entry: archive_entry,
      archive_job: archive_job,
      local_entry: local_entry,
      local_job: local_job,
      init_sha: init_sha,
      frag_sha: frag_sha,
      secret_access_key: secret_access_key
    }
  end

  defp ensure_job_for_entry(entry, opts) do
    case VisualIndexJob
         |> Ash.Query.filter(catalog_entry_id == ^entry.id)
         |> Ash.read_one!(opts) do
      nil ->
        VisualIndexJob
        |> Ash.Changeset.for_create(
          :enqueue,
          %{
            catalog_entry_id: entry.id,
            camera_source_id: entry.camera_source_id,
            stream_profile_id: entry.stream_profile_id,
            descriptor_sha256: entry.descriptor_sha256
          },
          opts
        )
        |> Ash.create!(opts)

      existing ->
        existing
    end
  end

  defp open_claim(source, profile, storage_id, tag, opts) do
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
      RelaySessionLifecycle.activate_session(session.id, "synth-wg-#{tag}", assignment, opts)

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
          next_block_sequence: 4,
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

  defp reserve_block(live_ctx, sequence, clock_epoch, opts) do
    clock = %{
      "clock_epoch" => clock_epoch,
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

  defp single_frag_descriptor(block, init_bytes, init_sha, frag_bytes, frag_sha, start_ns) do
    %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{
        "length" => byte_size(init_bytes),
        "sha256" => init_sha
      },
      "media" => %{
        "length" => byte_size(frag_bytes),
        "sha256" => frag_sha
      },
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => byte_size(frag_bytes),
          "start_ns" => start_ns,
          "duration_ns" => 2_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }
  end

  defp record_receipt(binding, block, storage_id, init_bytes, init_sha, frag_bytes, frag_sha, actor) do
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
            "length" => byte_size(init_bytes),
            "sha256" => init_sha,
            "etag" => "\"etag-init-#{block.id}\"",
            "version_id" => "synth-init-v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{storage_id}/#{block.block_key}/media.m4s",
            "length" => byte_size(frag_bytes),
            "sha256" => frag_sha,
            "etag" => "\"etag-media-#{block.id}\"",
            "version_id" => "synth-media-v1"
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
        "pvc://synthetic-nvr-0",
        sha256_hex("synth-profile-#{storage_id}"),
        sha256_hex("synth-binding-#{storage_id}"),
        now
      ]
    )
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
