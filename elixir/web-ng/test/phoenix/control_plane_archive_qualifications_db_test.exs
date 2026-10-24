defmodule ServiceRadarWebNGWeb.ControlPlaneArchiveQualificationsDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveQualifications
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  @token "synthetic-qualification-control-token-for-http-test"
  @header "x-serviceradar-control-plane-authorization"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    Application.put_env(:serviceradar_web_ng, :control_plane_runtime, token: @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)
    end)

    actor = SystemActor.system(:qualification_http_test)

    destination = %{
      "schema_version" => 1,
      "provisioning_ref" => "qualification-http-#{System.unique_integer([:positive])}",
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.com",
      "region" => "example-region",
      "bucket" => "synthetic-recordings",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    {:ok, binding} = ArchiveBinding.register(destination, actor: actor)
    binding_id = Ecto.UUID.dump!(binding.id)

    on_exit(fn ->
      ServiceRadar.Repo.query!(
        "DELETE FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
        [
          binding_id
        ]
      )

      ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [binding_id])

      assert %{rows: [[0]]} =
               ServiceRadar.Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_qualification_receipts WHERE archive_binding_id = $1",
                 [binding_id]
               )

      assert %{rows: [[0]]} =
               ServiceRadar.Repo.query!("SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $1", [
                 binding_id
               ])
    end)

    %{binding: binding, actor: actor, report: report(binding.id, destination)}
  end

  test "private HTTP authentication precedes durable receipt and reports no applied authority", context do
    %{binding: binding, actor: actor, report: report} = context
    document = submission(1, report)

    for headers <- [[], [{@header, "Bearer wrong-synthetic-token"}], [{"authorization", "Bearer #{@token}"}]] do
      conn = request(:put, binding.id, Jason.encode!(document), headers)
      assert conn.status == 401
      assert {:ok, nil} = ArchiveQualifications.status(binding.id, actor: actor)
    end

    conn = request(:put, binding.id, Jason.encode!(document))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert %{
             "status" => "recorded",
             "binding_id" => binding_id,
             "revision" => 1,
             "state" => "submitted",
             "applied_revision" => nil,
             "readiness" => "unavailable",
             "reason" => "qualification_receipt_only"
           } = body

    assert binding_id == binding.id
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute Map.has_key?(body, "report")
    refute Map.has_key?(body, "credential")
    assert {:ok, receipt} = ArchiveQualifications.status(binding.id, actor: actor)
    assert receipt.report == report
    assert receipt.receipt_sha256 == body["receipt_sha256"]
    assert {:ok, %{capability_state: :unqualified}} = Ash.get(ArchiveBinding, binding.id, actor: actor)

    status = request(:get, binding.id)
    assert status.status == 200
    assert Jason.decode!(status.resp_body) == body

    retry = request(:put, binding.id, Jason.encode!(document))
    assert retry.status == 200
    assert Jason.decode!(retry.resp_body) == body

    conflict = request(:put, binding.id, Jason.encode!(put_in(document, ["report", "policy_revision"], "policy-two")))
    assert conflict.status == 409
    assert Jason.decode!(conflict.resp_body) == %{"status" => "qualification_revision_conflict"}

    withdrawal = %{"schema_version" => 1, "revision" => 2, "state" => "withdrawn", "report" => nil}
    withdrawn = request(:put, binding.id, Jason.encode!(withdrawal))
    assert withdrawn.status == 200

    assert %{"revision" => 2, "state" => "withdrawn", "report_sha256" => nil, "readiness" => "unavailable"} =
             Jason.decode!(withdrawn.resp_body)

    stale = request(:put, binding.id, Jason.encode!(document))
    assert stale.status == 409
    assert Jason.decode!(stale.resp_body) == %{"status" => "qualification_revision_stale"}
    assert {:ok, %{revision: 2, state: :withdrawn, report: nil}} = ArchiveQualifications.status(binding.id, actor: actor)
  end

  test "wire and binding rejections leave no receipt", context do
    %{binding: binding, actor: actor, report: report} = context
    missing = request(:get, binding.id)
    assert missing.status == 200

    assert Jason.decode!(missing.resp_body) == %{
             "status" => "not_submitted",
             "applied_revision" => nil,
             "readiness" => "unavailable"
           }

    for invalid_report <- [
          %{report | "binding_id" => Ecto.UUID.generate()},
          put_in(report, ["destination", "bucket"], "different-synthetic-recordings")
        ] do
      conn = request(:put, binding.id, Jason.encode!(submission(1, invalid_report)))
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"status" => "qualification_binding_mismatch"}
      assert {:ok, nil} = ArchiveQualifications.status(binding.id, actor: actor)
    end

    body = Jason.encode!(submission(1, report))
    duplicate = String.replace(body, ~s("schema_version":1), ~s("schema_version":1,"schema_version":1), global: false)
    conn = request(:put, binding.id, duplicate)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"status" => "invalid_request"}
    assert {:ok, nil} = ArchiveQualifications.status(binding.id, actor: actor)

    conn = request(:put, binding.id, String.duplicate(" ", 16_385) <> body)
    assert conn.status == 413
    assert {:ok, nil} = ArchiveQualifications.status(binding.id, actor: actor)
  end

  defp request(method, binding_id, body \\ "", headers \\ [{@header, "Bearer " <> @token}]) do
    conn = conn(method, "/v1/archive-bindings/#{binding_id}/qualification", body)
    conn = Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    conn
    |> put_req_header("content-type", "application/json")
    |> ControlPlaneRuntimeRouter.call(ControlPlaneRuntimeRouter.init([]))
  end

  defp submission(revision, report) do
    %{"schema_version" => 1, "revision" => revision, "state" => "submitted", "report" => report}
  end

  defp report(binding_id, destination) do
    %{
      "schema_version" => 1,
      "binding_id" => binding_id,
      "destination" => destination,
      "provider_resource_id" => "synthetic-resource-one",
      "endpoint_type" => "synthetic-s3",
      "credential" => %{
        "reference" => "infrastructure/media/example",
        "generation" => 1,
        "storage_service_id" => "spiffe://example.org/storage/recordings"
      },
      "policy_revision" => "policy-one",
      "operation_mode" => "mediated_immutable_archive_v1",
      "issued_at_ms" => 1_800_000_000_000,
      "expires_at_ms" => 1_800_000_060_000,
      "result_ref" => "synthetic-evidence-one",
      "checks" =>
        Map.new(
          ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery),
          &{&1, "passed"}
        )
    }
  end
end
