defmodule ServiceRadarWebNGWeb.ControlPlaneInitAuthoritiesDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveUploadDispatch
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarWebNG.ArchiveStorageHTTP
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @media_token "synthetic-media-admin-token-for-init-http-test"
  @account_token "synthetic-account-purpose-token-for-init-http-test"

  setup %{tmp_dir: directory} do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    storage = ArchiveStorageHTTP.installation(directory)
    installation = %{deployment_ref: storage.document["deployment_ref"], generation: 1}

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @media_token, deployment_ref: installation.deployment_ref, generation: "1"]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)
    end)

    actor = SystemActor.system(:init_authority_http_test)

    destination = %{
      "schema_version" => 1,
      "provisioning_ref" => "synthetic-http-init-#{System.unique_integer([:positive])}",
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.com",
      "region" => "example-region",
      "bucket" => "synthetic-init-recordings",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    {:ok, binding} = ArchiveBinding.register(destination, actor: actor)
    {block, lease} = frozen_upload(actor, binding)
    now = System.system_time(:millisecond)

    report = %{
      "schema_version" => 1,
      "binding_id" => binding.id,
      "destination" => destination,
      "provider_resource_id" => "synthetic-init-resource",
      "endpoint_type" => "synthetic-s3",
      "credential" => %{
        "reference" => storage.document["credential_reference"],
        "generation" => 1,
        "storage_service_id" => storage.document["storage_service_id"]
      },
      "policy_revision" => "synthetic-policy-one",
      "operation_mode" => "mediated_immutable_archive_v1",
      "issued_at_ms" => now - 1000,
      "expires_at_ms" => now + 60_000,
      "result_ref" => "synthetic-init-evidence",
      "checks" =>
        Map.new(
          ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery),
          &{&1, "passed"}
        )
    }

    desired = %{
      "schema_version" => 1,
      "revision" => "1",
      "binding_id" => binding.id,
      "local_storage_id" => block.storage_id,
      "qualification_report" => report,
      "operation" => "init_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{"max_init_bytes" => 4096, "max_operation_ms" => 5000, "max_in_flight" => 1}
    }

    %{
      installation: installation,
      storage: ArchiveStorageHTTP.start!(storage),
      desired: desired,
      block: block,
      lease: lease,
      binding: binding,
      actor: actor
    }
  end

  test "storage challenge and media administration persist one correlated window without declaring archive readiness",
       context do
    %{installation: installation, storage: storage, desired: desired, binding: binding, actor: actor} = context
    {:ok, parsed} = ArchiveAuthorityConfig.parse(:init, installation, desired)

    challenge = %{
      "schema_version" => 1,
      "revision" => "1",
      "binding_id" => binding.id,
      "desired_sha256" => parsed.desired_sha256,
      "storage_boot_id" => Ecto.UUID.generate(),
      "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    assert {:ok, %{status: 200, body: pending}} =
             ArchiveStorageHTTP.request(storage, "/v1/init-authorities/challenge", Jason.encode!(challenge))

    assert %{"state" => "pending", "revision" => "1", "applied_revision" => nil} = pending
    assert pending["nonce"] == challenge["nonce"]
    assert pending["desired_sha256"] == parsed.desired_sha256

    application = %{"schema_version" => 1, "desired" => desired, "nonce" => challenge["nonce"]}
    assert admin(:put, installation, binding.id, application, @account_token).status == 401
    assert %{"state" => "pending"} = admin_body(:get, installation, binding.id)

    wrong_path = admin(:put, installation, Ecto.UUID.generate(), application)
    assert wrong_path.status == 400
    assert %{"state" => "pending"} = admin_body(:get, installation, binding.id)

    applied_response = admin(:put, installation, binding.id, application)
    assert applied_response.status == 200
    applied = Jason.decode!(applied_response.resp_body)

    assert %{
             "state" => "applied",
             "applied_revision" => "1",
             "recording_readiness" => "unavailable",
             "archive_readiness" => "unavailable",
             "reason" => "init_authority_only"
           } = applied

    assert applied["expires_at_ms"] == pending["expires_at_ms"]
    assert applied["desired_sha256"] == parsed.desired_sha256
    assert applied["storage_boot_id"] == challenge["storage_boot_id"]
    assert get_resp_header(applied_response, "cache-control") == ["no-store"]
    refute applied_response.resp_body =~ @media_token
    refute applied_response.resp_body =~ storage.token
    refute Map.has_key?(applied, "qualification_report")

    retry = admin_body(:put, installation, binding.id, application)
    assert retry["expires_at_ms"] == applied["expires_at_ms"]
    assert retry["remaining_ms"] <= applied["remaining_ms"]
    assert %{"state" => "applied", "applied_revision" => "1"} = admin_body(:get, installation, binding.id)

    lease_wire = %{
      "id" => context.lease.id,
      "upload_token" => context.lease.upload_token,
      "upload_epoch" => Integer.to_string(context.lease.upload_epoch),
      "descriptor_sha256" => context.lease.descriptor_sha256
    }

    assert {:ok, %{status: 200, body: prepared}} =
             storage_request(storage, "prepare", %{"schema_version" => 1, "lease" => lease_wire})

    assert %{"dispatch_id" => dispatch_id} = prepared
    assert prepared == %{"schema_version" => 1, "dispatch_id" => dispatch_id}

    grant_request = %{
      "schema_version" => 1,
      "lease" => lease_wire,
      "dispatch_id" => dispatch_id,
      "storage_boot_id" => challenge["storage_boot_id"],
      "desired_sha256" => parsed.desired_sha256,
      "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    assert {:ok, %{status: 200, body: grant}} = storage_request(storage, "grant", grant_request)
    assert %{"status" => "granted", "dispatch_id" => ^dispatch_id, "revision" => "1", "byte_length" => 1} = grant
    assert grant["object_sha256"] == digest("i")
    assert grant["descriptor_sha256"] == context.block.descriptor_sha256
    assert grant["nonce"] == grant_request["nonce"]
    assert grant["remaining_ms"] in 1..5000
    assert {:ok, retained} = Ash.get(ArchiveUploadDispatch, dispatch_id, actor: actor)
    assert retained.dispatcher_actor_id == SystemActor.system(:camera_archive_storage).id
    assert retained.marked_at

    assert {:ok, %{status: 409, body: %{"status" => "init_dispatch_already_marked"}}} =
             storage_request(storage, "grant", grant_request)

    revoke = %{"schema_version" => 1, "binding_id" => binding.id, "revision" => "2"}
    revoked = admin_body(:post, installation, binding.id <> "/revoke", revoke)

    assert %{"state" => "revoked", "revision" => "2", "applied_revision" => nil, "archive_readiness" => "unavailable"} =
             revoked

    assert admin(:put, installation, binding.id, application).status == 409
    assert %{"state" => "revoked", "revision" => "2"} = admin_body(:get, installation, binding.id)
    # Revocation stops admission; the original authenticated sender can still
    # retain its already-dispatched outcome and exact verification evidence.
    observation = %{
      "schema_version" => 1,
      "lease" => lease_wire,
      "dispatch_id" => dispatch_id,
      "outcome" => "response",
      "response" => %{"status" => 200, "etag" => "\"synthetic-init-etag\""}
    }

    assert {:ok, %{status: 200, body: %{"schema_version" => 1, "status" => "recorded"}}} =
             storage_request(storage, "observe", observation)

    verification = %{
      "schema_version" => 1,
      "put_request_sha256" => digest("synthetic-conditional-put-wire"),
      "etag" => "\"synthetic-init-etag\"",
      "version_id" => nil,
      "byte_length" => 1,
      "object_sha256" => digest("i"),
      "encryption" => "AES256"
    }

    verification_request = Map.put(grant_request, "verification", verification)
    assert {:ok, %{status: 200, body: verified}} = storage_request(storage, "verify", verification_request)
    assert verified == %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => dispatch_id}
    assert {:ok, retained} = Ash.get(ArchiveUploadDispatch, dispatch_id, actor: actor)
    assert retained.init_verification == verification
    assert retained.init_verified_at
    assert {:ok, %{state: :uploading}} = Ash.get(RecordingBlock, context.block.id, actor: actor)
    assert {:ok, %{capability_state: :unqualified}} = Ash.get(ArchiveBinding, binding.id, actor: actor)
  end

  defp storage_request(storage, operation, document),
    do: ArchiveStorageHTTP.request(storage, "/v1/init-uploads/" <> operation, Jason.encode!(document))

  # Boxed fixtures use the real allocation/freeze owners. Relay transport is
  # synthetic; this test owns the HTTP seam, not camera media or provider proof.
  defp frozen_upload(actor, binding) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:init-http-example-#{key}",
          vendor: "acme",
          vendor_camera_id: key,
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} = StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"}, opts)
    context = %{source: source, profile: profile, actor: actor, opts: opts}
    {:ok, relay} = Fixtures.open(context)
    {:ok, relay} = Fixtures.activate(context, relay)
    owner = Fixtures.owner(context)

    {:ok, claim} =
      RecorderOwnership.acquire(owner, Ecto.UUID.generate(), relay.media_ingest_id, Ecto.UUID.generate(), 30_000, opts)

    clock = %{
      "clock_epoch" => "synthetic-http-clock",
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, clock, opts)

    descriptor = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 1, "sha256" => digest("i")},
      "media" => %{"length" => 3, "sha256" => digest("abc")},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 3,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "sha256" => digest("abc"),
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }

    {:ok, block} = RecordingBlocks.freeze(owner, claim, block, descriptor, opts)
    {:ok, lease} = RecordingBlocks.acquire_upload(block.id, Ecto.UUID.generate(), 30_000, opts)
    {:ok, block} = RecordingBlocks.bind_archive(lease, binding.id, binding.destination_sha256, opts)
    {block, lease}
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp admin(method, installation, binding_id, body, token \\ @media_token) do
    method
    |> conn("/v1/media/init-authorities/" <> binding_id, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-serviceradar-control-plane-authorization", "Bearer " <> token)
    |> put_req_header("x-serviceradar-deployment-ref", installation.deployment_ref)
    |> put_req_header("x-serviceradar-media-generation", Integer.to_string(installation.generation))
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp admin_body(method, installation, id, body \\ %{}) do
    conn = admin(method, installation, id, body)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end
end
