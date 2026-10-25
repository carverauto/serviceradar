defmodule ServiceRadar.Camera.ArchiveQualificationReportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.ArchiveInitAuthorities
  alias ServiceRadar.Camera.ArchiveInitConfig
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

  test "init configuration binds the complete document and installed origin to an independent digest" do
    origin = %{
      deployment_ref: "33333333-3333-4333-8333-333333333333",
      generation: 9_007_199_254_740_993
    }

    document = init_configuration()
    assert {:ok, parsed} = ArchiveInitConfig.parse(origin, document)

    assert parsed.desired_sha256 ==
             "640efa2bc7fa06e27032c7a3ca6bd90c13de0dcea404fc0db3ab100a833d3a26"

    assert parsed.revision == 9_007_199_254_740_993

    assert parsed.report_sha256 ==
             "5b4fede25e7a08387c8a2844f7964c65d8241368350f9510f5dda7d3c369eb67"

    assert parsed.document == document

    for {installed, changed} <- [
          {%{origin | generation: origin.generation + 1}, document},
          {%{origin | deployment_ref: "44444444-4444-4444-8444-444444444444"}, document},
          {origin, Map.put(document, "revision", "9007199254740994")},
          {origin, Map.put(document, "local_storage_id", "55555555-5555-4555-8555-555555555555")},
          {origin, put_in(document, ["limits", "max_operation_ms"], 4999)},
          {origin, put_in(document, ["qualification_report", "credential", "generation"], 2)}
        ] do
      assert {:ok, different} = ArchiveInitConfig.parse(installed, changed)
      refute different.desired_sha256 == parsed.desired_sha256
    end

    # Format identity is not eligibility: this intentionally expired diagnostic
    # report still contains failed/unsupported claims, retained unchanged.
    assert parsed.report["checks"]["put_missing_aes256_denied"] == "failed"
  end

  test "init configuration rejects ambiguous revisions and unsupported operation limits" do
    origin = %{deployment_ref: "33333333-3333-4333-8333-333333333333", generation: 1}
    document = init_configuration()

    for invalid <-
          [
            Map.delete(document, "local_storage_id"),
            Map.put(document, "extra", true),
            Map.put(document, "schema_version", 1.0),
            Map.put(document, "operation", "media_put"),
            Map.put(document, "protection_mode", "none"),
            Map.put(document, "binding_id", "22222222-2222-4222-8222-222222222222"),
            Map.put(document, "local_storage_id", "not-a-uuid"),
            put_in(document, ["limits", "max_init_bytes"], 1_048_577),
            put_in(document, ["limits", "max_operation_ms"], 5001),
            put_in(document, ["limits", "max_operation_ms"], 1.0),
            put_in(document, ["limits", "max_in_flight"], 2),
            put_in(document, ["limits", "max_in_flight"], 1.0),
            update_in(document, ["limits"], &Map.put(&1, "extra", 1))
          ] ++
            Enum.map(
              [1, "0", "01", "+1", "1.0", "9223372036854775808"],
              &Map.put(document, "revision", &1)
            ) do
      assert {:error, :invalid_init_configuration} = ArchiveInitConfig.parse(origin, invalid)
    end

    for invalid <- [
          %{},
          %{origin | generation: 0},
          %{origin | generation: 1.0},
          %{origin | deployment_ref: "invalid"}
        ] do
      assert {:error, :invalid_init_configuration} = ArchiveInitConfig.parse(invalid, document)
    end
  end

  test "a deadline admits a write only when a whole millisecond remains" do
    now = DateTime.from_unix!(1_700_000_000_000_000, :microsecond)

    for offset <- [-1, 0, 1, 500, 999] do
      assert :expired =
               ArchiveInitAuthorities.operation_budget(
                 DateTime.add(now, offset, :microsecond),
                 now
               )
    end

    assert {:ok, 1} =
             ArchiveInitAuthorities.operation_budget(DateTime.add(now, 1_000, :microsecond), now)

    assert {:ok, 1} =
             ArchiveInitAuthorities.operation_budget(DateTime.add(now, 1_500, :microsecond), now)

    assert {:ok, 2} =
             ArchiveInitAuthorities.operation_budget(DateTime.add(now, 2_000, :microsecond), now)
  end

  defp init_configuration do
    %{
      "schema_version" => 1,
      "revision" => "9007199254740993",
      "binding_id" => "11111111-1111-4111-8111-111111111111",
      "local_storage_id" => "22222222-2222-4222-8222-222222222222",
      "qualification_report" => report(),
      "operation" => "init_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{
        "max_init_bytes" => 1_048_576,
        "max_operation_ms" => 5000,
        "max_in_flight" => 1
      }
    }
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
