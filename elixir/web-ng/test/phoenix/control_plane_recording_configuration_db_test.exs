defmodule ServiceRadarWebNGWeb.ControlPlaneRecordingConfigurationDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :web_ng_shared_fixture_db

  @token "synthetic-recording-control-token-for-http-test"
  @account_token "synthetic-recording-account-token-for-http-test"
  @entitlement_token "synthetic-entitlement-purpose-token-for-http-test"
  @header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @generation_header "x-serviceradar-media-generation"
  @entitlement_generation_header "x-serviceradar-entitlement-generation"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    previous_hosted = Application.get_env(:serviceradar_core, :hosted_runtime_contract_version)
    installation = %{deployment_ref: Ecto.UUID.generate(), generation: "1"}
    install(installation)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)

      if previous_hosted,
        do:
          Application.put_env(
            :serviceradar_core,
            :hosted_runtime_contract_version,
            previous_hosted
          ),
        else: Application.delete_env(:serviceradar_core, :hosted_runtime_contract_version)
    end)

    %{installation: installation}
  end

  test "private HTTP persists an origin-bound stop without advertising readiness", %{installation: installation} do
    document = %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"}
    body = Jason.encode!(document)
    baseline = request(:get, installation)
    assert baseline.status == 200
    assert %{"stop_enforced" => false, "desired_revision" => nil} = decode(baseline)

    rejected = request(:put, installation, body, @account_token)
    assert rejected.status == 401
    assert decode(request(:get, installation)) == decode(baseline)

    stopped = request(:put, installation, body)
    assert stopped.status == 200
    projection = decode(stopped)

    assert %{
             "contract_version" => 1,
             "stop_enforced" => true,
             "desired_revision" => "1",
             "desired_digest" => digest,
             "received_at" => received_at,
             "applied_revision" => nil,
             "readiness" => "unavailable",
             "reason" => "recording_stop_only",
             "drain_status" => "not_attested"
           } = projection

    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert {:ok, _, 0} = DateTime.from_iso8601(received_at)
    assert get_resp_header(stopped, "cache-control") == ["no-store"]
    assert get_resp_header(stopped, "x-content-type-options") == ["nosniff"]
    refute stopped.resp_body =~ @token
    refute stopped.resp_body =~ installation.deployment_ref

    retry = request(:put, installation, body)
    assert retry.status == 200
    assert decode(retry) == projection
    assert decode(request(:get, installation)) == projection

    resume = request(:put, installation, Jason.encode!(%{document | "revision" => "2", "admission" => "enabled"}))
    assert resume.status == 400
    assert decode(resume) == %{"status" => "invalid_recording_configuration"}
    assert decode(request(:get, installation)) == projection

    replacement = %{installation | generation: "2"}
    install(replacement)
    assert request(:get, installation).status == 401

    conflict = request(:put, replacement, body)
    assert conflict.status == 409
    assert decode(conflict) == %{"status" => "recording_revision_conflict"}
    assert decode(request(:get, replacement)) == projection

    newer = request(:put, replacement, Jason.encode!(%{document | "revision" => "2"}))
    assert newer.status == 200
    assert %{"stop_enforced" => true, "desired_revision" => "2"} = decode(newer)
    refute decode(newer)["desired_digest"] == digest

    stale = request(:put, replacement, body)
    assert stale.status == 409
    assert decode(stale) == %{"status" => "recording_revision_stale"}

    # An old process can authenticate its own installation but cannot overwrite
    # the durable stop that a newer installation has acknowledged.
    install(installation)
    old_process = request(:put, installation, Jason.encode!(%{document | "revision" => "3"}))
    assert old_process.status == 409
    assert decode(old_process) == %{"status" => "recording_generation_stale"}

    install(replacement)
    assert decode(request(:get, replacement)) == decode(newer)
  end

  test "storage entitlement HTTP enforces hosted runtime contract, revision ordering, replay, and origin bounds",
       %{installation: installation} do
    document = valid_entitlement_document(installation.deployment_ref, 7)
    body = Jason.encode!(document)

    # Self-hosted deployment (no hosted runtime contract) refuses PUT /v1/storage/entitlement with 409
    Application.delete_env(:serviceradar_core, :hosted_runtime_contract_version)
    self_hosted_put = storage_request(:put, "/v1/storage/entitlement", installation, body)
    assert self_hosted_put.status == 409
    assert decode(self_hosted_put) == %{"status" => "self_hosted_install"}

    # Enable hosted runtime contract
    Application.put_env(:serviceradar_core, :hosted_runtime_contract_version, "1")

    # Before first push, GET reports unconfigured & waiting_for_entitlement
    before_push = storage_request(:get, "/v1/storage/entitlement", installation)
    assert before_push.status == 200

    assert %{
             "status" => "unconfigured",
             "applied_revision" => nil,
             "hosted" => true,
             "waiting_for_entitlement" => true,
             "archive_jobs_held" => true
           } = decode(before_push)

    # Media token is rejected on /v1/storage/entitlement
    assert storage_request(:put, "/v1/storage/entitlement", installation, body, @token).status ==
             401

    # Push revision 7 succeeds
    applied = storage_request(:put, "/v1/storage/entitlement", installation, body)
    assert applied.status == 200
    applied_body = decode(applied)

    assert %{
             "schema_version" => 1,
             "status" => "applied",
             "applied_revision" => 7,
             "document_sha256" => digest,
             "waiting_for_entitlement" => false,
             "consumers" => %{
               "recordings" => %{
                 "enabled" => true,
                 "allocation_bytes" => 107_374_182_400,
                 "capacity_policy" => "reap_oldest",
                 "retention" => %{"max_days" => 365, "default_days" => 30},
                 "limits" => %{"max_recording_cameras" => 4}
               }
             }
           } = applied_body

    assert digest =~ ~r/\A[0-9a-f]{64}\z/

    # Idempotent replay of identical revision 7 succeeds without change
    replay = storage_request(:put, "/v1/storage/entitlement", installation, body)
    assert replay.status == 200
    assert decode(replay)["document_sha256"] == digest
    assert decode(storage_request(:get, "/v1/storage/entitlement", installation))["applied_revision"] == 7

    # Stale revision 6 refused with 409
    stale_doc = valid_entitlement_document(installation.deployment_ref, 6)
    stale = storage_request(:put, "/v1/storage/entitlement", installation, Jason.encode!(stale_doc))
    assert stale.status == 409
    assert decode(stale) == %{"status" => "entitlement_revision_stale"}

    # Different document under revision 7 refused with 409
    conflict_doc =
      put_in(document, ["consumers", "recordings", "allocation_bytes"], 214_748_364_800)

    conflict =
      storage_request(:put, "/v1/storage/entitlement", installation, Jason.encode!(conflict_doc))

    assert conflict.status == 409
    assert decode(conflict) == %{"status" => "entitlement_revision_conflict"}

    # Unknown field refused with 400
    unknown_field =
      storage_request(
        :put,
        "/v1/storage/entitlement",
        installation,
        Jason.encode!(Map.put(document, "tenant_id", "forbidden"))
      )

    assert unknown_field.status == 400
    assert decode(unknown_field) == %{"status" => "invalid_storage_entitlement"}

    # Wrong deployment_ref in document refused with 409
    wrong_ref_doc = %{document | "deployment_ref" => Ecto.UUID.generate(), "revision" => 8}

    wrong_ref =
      storage_request(:put, "/v1/storage/entitlement", installation, Jason.encode!(wrong_ref_doc))

    assert wrong_ref.status == 409
    assert decode(wrong_ref) == %{"status" => "entitlement_deployment_mismatch"}

    # Advance entitlement installation generation to "2", push revision 8, then verify generation "1" is stale
    gen2 = %{installation | generation: "2"}
    install(gen2)
    rev8_doc = valid_entitlement_document(installation.deployment_ref, 8)
    assert storage_request(:put, "/v1/storage/entitlement", gen2, Jason.encode!(rev8_doc)).status == 200

    install(installation)
    rev9_doc = valid_entitlement_document(installation.deployment_ref, 9)
    stale_gen = storage_request(:put, "/v1/storage/entitlement", installation, Jason.encode!(rev9_doc))
    assert stale_gen.status == 409
    assert decode(stale_gen) == %{"status" => "entitlement_generation_stale"}
  end

  test "closed-day storage usage HTTP replays identical report_revision and omits camera names",
       %{installation: installation} do
    Application.put_env(:serviceradar_core, :hosted_runtime_contract_version, "1")
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    first = storage_request(:get, "/v1/storage/usage?from=#{yesterday}", installation)
    assert first.status == 200
    first_body = decode(first)

    assert %{
             "schema_version" => 1,
             "from" => ^yesterday,
             "days" => [%{"date" => ^yesterday, "report_revision" => rev} = day_one]
           } = first_body

    assert is_integer(rev) and rev >= 1

    second = storage_request(:get, "/v1/storage/usage?from=#{yesterday}", installation)
    assert second.status == 200
    second_body = decode(second)

    assert [%{"date" => ^yesterday, "report_revision" => ^rev} = day_two] = second_body["days"]
    assert day_two["consumers"] == day_one["consumers"]
  end

  test "cloud archive credentials HTTP stores managed row, binds slot, drains rotated generations, and never echoes secrets",
       %{installation: installation} do
    sys_actor = SystemActor.system(:cp_archive_creds_http_test)
    secret_marker_v3 = String.duplicate("synthetic-writer-v3-", 2)
    access_marker_v3 = String.duplicate("SYNTHACCESSV3", 2)

    put_v3 =
      archive_cred_request(
        :put,
        "writer",
        installation,
        Jason.encode!(%{
          "schema_version" => 1,
          "deployment_ref" => installation.deployment_ref,
          "credential_generation" => 3,
          "access_key_id" => access_marker_v3,
          "secret_access_key" => secret_marker_v3
        })
      )

    assert put_v3.status == 200
    refute put_v3.resp_body =~ secret_marker_v3
    refute put_v3.resp_body =~ access_marker_v3

    v3_body = decode(put_v3)

    assert %{
             "schema_version" => 1,
             "role" => "writer",
             "status" => "active",
             "managed_by" => "control_plane",
             "credential_generation" => 3,
             "secret_id" => secret_id_v3,
             "slot_bound" => true,
             "draining_generations" => []
           } = v3_body

    {:ok, stored_v3} = Ash.get(NetworkCredentialSecret, secret_id_v3, actor: sys_actor)
    assert stored_v3.managed_by == :control_plane
    assert stored_v3.credential_generation == 3

    {:ok, arch_settings} = RecordingArchiveSettings.get_settings(actor: sys_actor)
    assert to_string(arch_settings.writer_credential_secret_id) == secret_id_v3

    # Hold an active CredentialBrokerGrant against generation 3 while rotating to generation 4
    future_exp = DateTime.shift(DateTime.utc_now(), minute: 10)

    _grant =
      CredentialBrokerGrant
      |> Ash.Changeset.for_create(
        :issue,
        %{
          secret_id: secret_id_v3,
          secret_ref: "secretref:network_credential:#{secret_id_v3}",
          grant_type: "http_request",
          consumer_kind: :test,
          consumer_id: "nvr-0",
          purpose: "camera_archive_write",
          target_kind: "archive_bucket",
          target_id: "synthetic-bucket",
          resolution_location: :control_plane,
          allowed_schemes: ["https"],
          allowed_methods: ["PUT"],
          allowed_paths: ["/recordings/v1/*"],
          allowed_hosts: ["objects.example.com"],
          allowed_ports: [443],
          ttl_seconds: 600,
          expires_at: future_exp,
          issued_by_actor_id: "system:test"
        },
        actor: sys_actor
      )
      |> Ash.create!(actor: sys_actor)

    secret_marker_v4 = String.duplicate("synthetic-writer-v4-", 2)

    put_v4 =
      archive_cred_request(
        :put,
        "writer",
        installation,
        Jason.encode!(%{
          "schema_version" => 1,
          "deployment_ref" => installation.deployment_ref,
          "credential_generation" => 4,
          "access_key_id" => String.duplicate("SYNTHACCESSV4", 2),
          "secret_access_key" => secret_marker_v4
        })
      )

    assert put_v4.status == 200
    refute put_v4.resp_body =~ secret_marker_v4

    status_conn = archive_cred_request(:get, "writer", installation)
    assert status_conn.status == 200
    status_body = decode(status_conn)
    assert status_body["credential_generation"] == 4
    assert status_body["draining_generations"] == [3]
    refute status_conn.resp_body =~ secret_marker_v4
  end

  @tag :tmp_dir
  test "held-object manifest HTTP pages held archive objects deterministically",
       %{installation: installation, tmp_dir: directory} do
    Fixtures.recording_recovery_gate(directory)
    sys_actor = SystemActor.system(:cp_holds_manifest_test)
    storage_id = Ecto.UUID.generate()

    {:ok, binding} =
      ServiceRadar.Camera.ArchiveDestinations.register_operator(
        %{
          name: "manifest-test-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-manifest-bucket",
          namespace: "recordings/v1"
        },
        actor: sys_actor
      )

    {:ok, source} =
      ServiceRadar.Camera.Source.create_source(
        %{
          device_uid: "sr:manifest-dev-#{Ecto.UUID.generate()}",
          vendor: "synthetic",
          vendor_camera_id: "cam-m1",
          display_name: "Synthetic Manifest Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        actor: sys_actor
      )

    {:ok, profile} =
      ServiceRadar.Camera.StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main",
          codec_hint: "h264",
          relay_eligible: true
        },
        actor: sys_actor
      )

    cam_id = source.id
    prof_id = profile.id

    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      """
      INSERT INTO platform.camera_local_storage_bindings (
        id, schema_version, storage_id, generation, provider_resource_ref,
        profile_sha256, binding_sha256, provisioned_by, inserted_at
      ) VALUES ($1, 1, $2, 1, 'pvc://synth-manifest', $3, $4, 'synthetic', NOW())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(storage_id),
        String.duplicate("c", 64),
        String.duplicate("d", 64)
      ]
    )

    {:ok, session} =
      ServiceRadar.Camera.RelaySessionManager.request_open(cam_id, prof_id,
        actor: sys_actor,
        control_gateway_resolver: fn _agent, gw -> {:ok, gw} end,
        dispatch_open: fn _agent, _payload, open_opts, _req -> {:ok, open_opts[:command_id]} end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      ServiceRadar.Camera.RelaySessionLifecycle.activate_session(
        session.id,
        "synth-manifest-sess",
        assignment,
        actor: sys_actor
      )

    {:ok, owner} = IngestOwnership.for_relay(session.id, actor: sys_actor)
    claim_token = Ecto.UUID.generate()

    {:ok, consumer} =
      IngestOwnership.acquire_consumer(
        owner,
        :recorder,
        claim_token,
        60_000,
        actor: sys_actor
      )

    initial_claim =
      ServiceRadar.Camera.RecorderClaim
      |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, actor: sys_actor)
      |> Ash.create!(actor: sys_actor)

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
        actor: sys_actor
      )
      |> Ash.update!(actor: sys_actor)

    for idx <- [1, 2] do
      received_at = DateTime.shift(~U[2026-11-16 12:00:00Z], minute: idx)

      block_attrs = %{
        camera_source_id: cam_id,
        stream_profile_id: prof_id,
        ingest_owner_id: owner.id,
        ingest_epoch: owner.epoch,
        recorder_claim_id: claim.id,
        recorder_epoch: claim.recorder_epoch,
        block_sequence: idx,
        relay_session_id: claim.relay_session_id,
        media_ingest_id: claim.media_ingest_id,
        storage_id: storage_id,
        clock: %{
          "clock_epoch" => "epoch-manifest-1",
          "timebase" => 90_000,
          "dts_source" => "pts_no_reordering",
          "utc_mapping" => "unknown"
        }
      }

      identity = RecordingBlock.identity(block_attrs)
      bkey = ServiceRadarRecordingMetadata.Descriptor.block_key(identity)

      block =
        RecordingBlock
        |> Ash.Changeset.for_create(:reserve, Map.put(block_attrs, :block_key, bkey), actor: sys_actor)
        |> Ash.create!(actor: sys_actor)

      init_sha = :sha256 |> :crypto.hash("manifest-init-#{idx}") |> Base.encode16(case: :lower)
      obj_sha = :sha256 |> :crypto.hash("manifest-obj-#{idx}") |> Base.encode16(case: :lower)

      desc = %{
        "version" => 1,
        "identity" => RecordingBlock.identity(block),
        "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
        "init" => %{"length" => 256, "sha256" => init_sha},
        "media" => %{"length" => 8_192, "sha256" => obj_sha},
        "fragments" => [
          %{
            "sequence" => 0,
            "offset" => 0,
            "length" => 8_192,
            "start_ns" => idx * 10_000_000_000,
            "duration_ns" => 10_000_000_000,
            "sha256" => obj_sha,
            "tail_duration_source" => nil,
            "motion" => "unknown"
          }
        ]
      }

      {:ok, entry} =
        ServiceRadar.Camera.RecordingBlocks.freeze_and_catalog(
          owner,
          claim,
          block,
          desc,
          %{
            first_unit_pts: idx * 900_000,
            first_unit_received_at: received_at,
            reanchored: false,
            contiguous_with_previous: idx > 1
          },
          actor: sys_actor
        )

      receipt_json =
        Jason.encode!(%{
          "version" => 2,
          "storage_id" => storage_id,
          "block_key" => bkey,
          "destination_sha256" => binding.destination_sha256,
          "verified_at_ms" => 1_790_000_000_000,
          "objects" => [
            %{
              "name" => "init.mp4",
              "key" => "recordings/v1/#{storage_id}/#{bkey}/init.mp4",
              "length" => 256,
              "sha256" => init_sha,
              "etag" => "\"etag-i-#{idx}\""
            },
            %{
              "name" => "media.m4s",
              "key" => "recordings/v1/#{storage_id}/#{bkey}/media.m4s",
              "length" => 8_192,
              "sha256" => obj_sha,
              "etag" => "\"etag-m-#{idx}\""
            }
          ]
        })

      {:ok, receipt} =
        NVRArchiveReceipt.record(binding.id, receipt_json, %{recording_block_id: block.id}, actor: sys_actor)

      entry =
        entry
        |> Ash.Changeset.for_update(
          :transition_archive_state,
          %{
            archive_state: :verified,
            archive_state_at: received_at,
            archived_at: received_at,
            nvr_archive_receipt_id: receipt.id,
            archive_binding_id: binding.id
          },
          actor: sys_actor
        )
        |> Ash.update!(actor: sys_actor)

      {:ok, _hold} =
        ServiceRadar.Camera.RecordingHolds.place_hold(
          %{
            camera_source_id: cam_id,
            stream_profile_id: prof_id,
            kind: :investigation,
            start_us: entry.timeline_start_us,
            end_us: entry.timeline_end_us,
            reason: "Synthetic manifest test #{idx}"
          },
          actor: sys_actor
        )
    end

    page1 = storage_request(:get, "/v1/storage/holds?limit=1", installation)
    assert page1.status == 200
    body1 = decode(page1)
    assert length(body1["holds"]) == 1
    assert is_binary(body1["next_cursor"])
    [first_hold] = body1["holds"]
    assert [%{"objects" => objects}] = first_hold["blocks"]

    assert Enum.any?(objects, fn obj ->
             obj["key"] =~ "recordings/v1/" and obj["length"] == 8_192 and
               obj["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
           end)

    page2 =
      storage_request(
        :get,
        "/v1/storage/holds?limit=1&cursor=#{URI.encode_www_form(body1["next_cursor"])}",
        installation
      )

    assert page2.status == 200
    body2 = decode(page2)
    assert length(body2["holds"]) == 1
    refute hd(body2["holds"])["hold_id"] == first_hold["hold_id"]
  end

  defp valid_entitlement_document(deployment_ref, revision) do
    %{
      "schema_version" => 1,
      "deployment_ref" => deployment_ref,
      "revision" => revision,
      "issued_at" => "2026-11-17T12:00:00Z",
      "consumers" => %{
        "recordings" => %{
          "enabled" => true,
          "allocation_bytes" => 107_374_182_400,
          "overage" => %{"mode" => "off"},
          "capacity_policy" => "reap_oldest",
          "retention" => %{"max_days" => 365, "default_days" => 30},
          "limits" => %{"max_recording_cameras" => 4}
        }
      }
    }
  end

  defp storage_request(method, path, installation, body \\ "", token \\ @entitlement_token) do
    method
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@header, "Bearer " <> token)
    |> put_req_header(@deployment_header, installation.deployment_ref)
    |> put_req_header(@entitlement_generation_header, installation.generation)
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp archive_cred_request(method, role, installation, body \\ "", token \\ @token) do
    method
    |> conn("/v1/media/archive-credentials/#{role}", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@header, "Bearer " <> token)
    |> put_req_header(@deployment_header, installation.deployment_ref)
    |> put_req_header(@generation_header, installation.generation)
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp request(method, installation, body \\ "", token \\ @token) do
    method
    |> conn("/v1/media/configuration", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@header, "Bearer " <> token)
    |> put_req_header(@deployment_header, installation.deployment_ref)
    |> put_req_header(@generation_header, installation.generation)
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp install(installation) do
    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [
        token: @token,
        deployment_ref: installation.deployment_ref,
        generation: installation.generation
      ],
      entitlements: [
        token: @entitlement_token,
        deployment_ref: installation.deployment_ref,
        generation: installation.generation
      ]
    )
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
