defmodule ServiceRadar.Camera.ArchiveQualificationReportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.ArchiveQualificationReport
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures

  test "canonical report identity matches the independently encoded protocol vector" do
    input = report()
    assert {:ok, parsed} = ArchiveQualificationReport.parse(input)
    assert parsed.document == input

    assert parsed.destination_sha256 ==
             "154ecbe5d6d232275123a7cf847e491d627197980ea8c4a050593d2e0f474020"

    assert parsed.report_sha256 ==
             "5b4fede25e7a08387c8a2844f7964c65d8241368350f9510f5dda7d3c369eb67"

    assert Jason.decode!(parsed.canonical_json) == input
  end

  test "credential rotation and changed observations change the report without retargeting the destination" do
    input = report()
    assert {:ok, original} = ArchiveQualificationReport.parse(input)

    for changed <- [
          put_in(input, ["credential", "generation"], 2),
          put_in(input, ["credential", "reference"], "storage-key-next"),
          put_in(input, ["credential", "storage_service_id"], "storage-worker-next"),
          put_in(
            input,
            ["credential", "storage_service_id"],
            "spiffe://example.com/service/archive-storage"
          ),
          put_in(input, ["credential", "reference"], "secret://namespace-example/archive-writer"),
          Map.put(input, "policy_revision", "policy-next"),
          Map.put(input, "provider_resource_id", "region-example/bucket-other"),
          Map.put(input, "endpoint_type", "endpoint-class-other"),
          Map.put(input, "binding_id", "22222222-2222-4222-8222-222222222222"),
          Map.put(input, "result_ref", "report-next"),
          Map.put(input, "issued_at_ms", 1_700_000_000_001),
          Map.put(input, "expires_at_ms", 1_700_000_300_001),
          put_in(input, ["checks", "put_missing_aes256_denied"], "passed")
        ] do
      assert {:ok, parsed} = ArchiveQualificationReport.parse(changed)
      assert parsed.destination_sha256 == original.destination_sha256
      refute parsed.report_sha256 == original.report_sha256
    end

    assert {:ok, retargeted} =
             input
             |> put_in(["destination", "generation"], 2)
             |> ArchiveQualificationReport.parse()

    refute retargeted.destination_sha256 == original.destination_sha256
    refute retargeted.report_sha256 == original.report_sha256
  end

  test "canonical JSON escapes quotes and backslashes without optional slash or HTML escapes" do
    input = Map.put(report(), "provider_resource_id", ~S(example/"\<>&))
    assert {:ok, parsed} = ArchiveQualificationReport.parse(input)
    assert parsed.canonical_json =~ ~S("provider_resource_id":"example/\"\\<>&")
    assert Jason.decode!(parsed.canonical_json)["provider_resource_id"] == ~S(example/"\<>&)
  end

  test "attestation, policy denial and unknown observations remain separate reported facts" do
    input = report()

    for status <- ~w(passed failed not_tested not_confirmed unsupported) do
      changed = put_in(input, ["checks", "put_missing_aes256_denied"], status)
      assert {:ok, %{document: %{"checks" => checks}}} = ArchiveQualificationReport.parse(changed)
      assert checks["put_aes256_attestation"] == "passed"
      assert checks["put_missing_aes256_denied"] == status
      assert checks["put_noncompliant_aes256_denied"] == "not_confirmed"
      assert checks["multipart_aes256_attestation"] == "passed"
      assert checks["multipart_missing_aes256_denied"] == "not_tested"
      assert checks["multipart_noncompliant_aes256_denied"] == "unsupported"
    end

    # Old observations are representable; parsing must not silently refresh them.
    assert {:ok, %{document: %{"issued_at_ms" => 1, "expires_at_ms" => 2}}} =
             input
             |> Map.merge(%{"issued_at_ms" => 1, "expires_at_ms" => 2})
             |> ArchiveQualificationReport.parse()
  end

  test "exact schema rejects omissions, secrets, unsupported modes and incomplete observation inventories" do
    input = report()

    for key <- Map.keys(input) do
      assert {:error, :invalid_archive_qualification_report} =
               ArchiveQualificationReport.parse(Map.delete(input, key))
    end

    for path <- ["destination", "credential", "checks"], key <- Map.keys(input[path]) do
      assert {:error, :invalid_archive_qualification_report} =
               input
               |> update_in([path], &Map.delete(&1, key))
               |> ArchiveQualificationReport.parse()
    end

    for invalid <- [
          Map.put(input, "ready", true),
          Map.put(input, "secret_access_key", "invented-secret"),
          Map.put(input, "schema_version", 2),
          Map.put(input, "operation_mode", "direct_provider"),
          put_in(input, ["destination", "purpose"], "evidence"),
          put_in(input, ["destination", "endpoint"], "https://objects.example.com/path"),
          put_in(input, ["credential", "secret"], "invented-secret"),
          put_in(input, ["checks", "default_encryption"], "passed"),
          update_in(
            input,
            ["checks"],
            &(&1
              |> Map.delete("put_missing_aes256_denied")
              |> Map.put("default_encryption", "passed"))
          ),
          put_in(input, ["checks", "put_missing_aes256_denied"], true),
          put_in(input, ["checks", "put_missing_aes256_denied"], "access_denied"),
          put_in(input, ["checks", "put_missing_aes256_denied"], %{"status" => "passed"}),
          Map.put(input, :schema_version, 1),
          nil,
          [],
          "{}"
        ] do
      assert {:error, :invalid_archive_qualification_report} =
               ArchiveQualificationReport.parse(invalid)
    end
  end

  test "metadata and time bounds reject malformed values before canonical encoding" do
    input = report()

    for {field, values} <- [
          {"binding_id", ["not-a-uuid", "11111111-1111-4111-8111-11111111111A", nil]},
          {"provider_resource_id",
           ["", "bucket\nother", "non-ascii-\u00e9", String.duplicate("a", 257)]},
          {"endpoint_type", ["", "https://objects.example.com", String.duplicate("a", 129)]},
          {"policy_revision", ["", 1, "policy/other"]},
          {"result_ref", ["", "report?secret=value", <<255>>]},
          {"issued_at_ms", [0, -1, 1.0, "1", 9_223_372_036_854_775_808, 1_700_000_300_000]},
          {"expires_at_ms", [0, -1, 1.0, "2", 9_223_372_036_854_775_808, 1_700_000_000_000]},
          {"credential", [nil, [], "key"]},
          {"checks", [nil, [], "passed"]}
        ],
        value <- values do
      assert {:error, :invalid_archive_qualification_report} =
               ArchiveQualificationReport.parse(Map.put(input, field, value))
    end

    for {field, value} <- [
          {"reference", ""},
          {"reference", String.duplicate("a", 257)},
          {"generation", 0},
          {"generation", 9_223_372_036_854_775_808},
          {"generation", 1.0},
          {"storage_service_id", "storage\nworker"}
        ] do
      assert {:error, :invalid_archive_qualification_report} =
               input |> put_in(["credential", field], value) |> ArchiveQualificationReport.parse()
    end
  end

  defp report do
    %{
      "schema_version" => 1,
      "binding_id" => "11111111-1111-4111-8111-111111111111",
      "destination" => Fixtures.archive_destination("allocation-example"),
      "provider_resource_id" => "region-example/bucket-example",
      "endpoint_type" => "endpoint-class-example",
      "credential" => %{
        "reference" => "storage-key-example",
        "generation" => 1,
        "storage_service_id" => "storage-worker-example"
      },
      "policy_revision" => "policy-example",
      "operation_mode" => "mediated_immutable_archive_v1",
      "issued_at_ms" => 1_700_000_000_000,
      "expires_at_ms" => 1_700_000_300_000,
      "result_ref" => "report-example",
      "checks" => %{
        "intended_operations" => "passed",
        "anonymous_access_denied" => "passed",
        "foreign_environment_access_denied" => "not_tested",
        "recorder_privilege_boundary" => "unsupported",
        "reader_privilege_boundary" => "passed",
        "private_acl_policy" => "not_tested",
        "endpoint_tls_redirect_boundary" => "not_tested",
        "browser_cors" => "not_tested",
        "put_aes256_attestation" => "passed",
        "multipart_aes256_attestation" => "passed",
        "put_missing_aes256_denied" => "failed",
        "put_noncompliant_aes256_denied" => "not_confirmed",
        "multipart_missing_aes256_denied" => "not_tested",
        "multipart_noncompliant_aes256_denied" => "unsupported",
        "atomic_put_no_overwrite" => "passed",
        "atomic_completion_no_overwrite" => "passed",
        "integrity_object_identity" => "passed",
        "conditional_ranges" => "passed",
        "multipart_recovery" => "passed"
      }
    }
  end
end
