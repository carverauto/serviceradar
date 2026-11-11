defmodule ServiceRadar.Camera.LocalStorageQualificationDocumentTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.LocalStorageQualificationDocument

  @document %{
    "schema_version" => 1,
    "binding_id" => "00000000-0000-4000-8000-000000000031",
    "storage_id" => "00000000-0000-4000-8000-000000000032",
    "binding_sha256" => String.duplicate("a", 64),
    "profile_sha256" => String.duplicate("b", 64),
    "revision" => 1,
    "evidence_sha256" => String.duplicate("c", 64),
    "policy_revision" => "synthetic-policy-v1",
    "issued_at_ms" => 1000,
    "expires_at_ms" => 2000,
    "checks" => %{
      "acknowledged_writes_survive_worker_disk_loss" => "passed",
      "replica_placement_and_health" => "passed",
      "provider_attachment_fencing" => "passed",
      "application_writer_ownership" => "passed",
      "reattachment_preserves_identity_and_bytes" => "passed",
      "retained_volume_lifecycle" => "passed",
      "restore_preserves_history" => "passed"
    }
  }

  test "hashes the complete versioned canonical report with an independent wire vector" do
    assert {:ok, attrs} = LocalStorageQualificationDocument.attributes(@document)
    assert attrs.report == @document
    assert attrs.local_storage_binding_id == @document["binding_id"]
    assert attrs.revision == 1

    # Independently computed from sorted-key compact JSON including the domain separator.
    assert attrs.report_sha256 ==
             "f7e8e3fe5c052c882c1050de6c1d7802aaceeee220c83de13c5c0c8207f71dbe"
  end

  test "rejects unknown or missing fields, malformed identities, bounds and incomplete checks" do
    invalid_values = [
      {"schema_version", 2},
      {"binding_id", "00000000-0000-4000-8000-00000000003A"},
      {"storage_id", "not-a-uuid"},
      {"binding_sha256", String.duplicate("A", 64)},
      {"profile_sha256", String.duplicate("a", 63)},
      {"evidence_sha256", %{}},
      {"revision", 0},
      {"revision", 9_223_372_036_854_775_808},
      {"revision", "1"},
      {"policy_revision", ""},
      {"policy_revision", "synthetic\npolicy"},
      {"policy_revision", String.duplicate("p", 129)},
      {"issued_at_ms", 0},
      {"issued_at_ms", 2000},
      {"expires_at_ms", 999},
      {"expires_at_ms", 9_223_372_036_854_775_808},
      {"checks", []},
      {"checks", Map.delete(@document["checks"], "provider_attachment_fencing")},
      {"checks", Map.put(@document["checks"], "unknown", "passed")},
      {"checks", Map.put(@document["checks"], "provider_attachment_fencing", true)}
    ]

    invalid_documents =
      [nil, [], %{}, Map.put(@document, "issued_by", "self-declared-principal")] ++
        Enum.map(Map.keys(@document), &Map.delete(@document, &1)) ++
        Enum.map(invalid_values, fn {key, value} -> Map.put(@document, key, value) end)

    for document <- invalid_documents do
      assert {:error, :invalid_local_storage_qualification_report} =
               LocalStorageQualificationDocument.attributes(document)
    end
  end

  test "retains unsuccessful observations and maximum bounds without evaluating freshness" do
    for status <- ~w(failed not_tested not_confirmed unsupported) do
      document = put_in(@document, ["checks", "restore_preserves_history"], status)
      assert {:ok, attrs} = LocalStorageQualificationDocument.attributes(document)
      assert attrs.report == document
    end

    document =
      @document
      |> Map.put("revision", 9_223_372_036_854_775_807)
      |> Map.put("policy_revision", String.duplicate("p", 128))
      |> Map.put("issued_at_ms", 9_223_372_036_854_775_806)
      |> Map.put("expires_at_ms", 9_223_372_036_854_775_807)

    assert {:ok, attrs} = LocalStorageQualificationDocument.attributes(document)
    assert attrs.report == document
  end
end
