defmodule ServiceRadar.Camera.LocalStorageQualificationDocumentTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.LocalStorageEvidence
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

  describe "evidence eligibility" do
    setup do
      {:ok, retained} = LocalStorageQualificationDocument.attributes(@document)

      policy = %{
        revision: "synthetic-policy-v1",
        profile_sha256: String.duplicate("b", 64),
        max_report_validity_ms: 1000,
        max_health_age_ms: 500
      }

      health = %{
        "binding_id" => @document["binding_id"],
        "report_sha256" => retained.report_sha256,
        "evidence_sha256" => String.duplicate("d", 64),
        "observed_at_ms" => 1000,
        "status" => "healthy"
      }

      %{retained: retained, policy: policy, health: health}
    end

    test "current evidence ends at the earlier health or report deadline", ctx do
      assert %{evidence_status: :current, valid_until_ms: 1500} = evaluate(ctx, 1000)
      assert %{evidence_status: :current, valid_until_ms: 1500} = evaluate(ctx, 1499)
      assert %{reason: :health_expired} = evaluate(ctx, 1500)

      ctx = put_in(ctx.health["observed_at_ms"], 1800)
      assert %{evidence_status: :current, valid_until_ms: 2000} = evaluate(ctx, 1999)
      assert %{reason: :report_expired} = evaluate(ctx, 2000)
      assert %{reason: :report_from_future} = evaluate(ctx, 999)
      assert %{reason: :health_from_future} = evaluate(ctx, 1799)

      for invalid_time <- [nil, "1000", 0, 9_223_372_036_854_775_808] do
        assert %{evidence_status: :ineligible, reason: :invalid_trusted_time} =
                 evaluate(ctx, invalid_time)
      end
    end

    test "policy has no implicit limits and must match both revision and profile", ctx do
      invalid =
        [
          nil,
          %{},
          Map.put(ctx.policy, :max_health_age_ms, 0),
          Map.put(ctx.policy, :max_report_validity_ms, "1000"),
          Map.put(ctx.policy, :max_report_validity_ms, 9_223_372_036_854_775_808),
          Map.put(ctx.policy, :default, true)
        ] ++
          Enum.map(Map.keys(ctx.policy), &Map.delete(ctx.policy, &1))

      for policy <- invalid do
        assert %{evidence_status: :ineligible, reason: :invalid_policy} =
                 evaluate(%{ctx | policy: policy}, 1000)
      end

      for {key, value} <- [revision: "other-policy", profile_sha256: String.duplicate("e", 64)] do
        assert %{reason: :policy_mismatch} = evaluate(put_in(ctx.policy[key], value), 1000)
      end

      assert %{reason: :report_validity_exceeded} =
               evaluate(put_in(ctx.policy.max_report_validity_ms, 999), 1000)
    end

    test "every required outcome must pass, and retained content must match its digest", ctx do
      for check <- Map.keys(@document["checks"]),
          status <- ~w(failed not_tested not_confirmed unsupported) do
        document = put_in(@document, ["checks", check], status)
        {:ok, retained} = LocalStorageQualificationDocument.attributes(document)
        health = Map.put(ctx.health, "report_sha256", retained.report_sha256)

        assert %{evidence_status: :ineligible, reason: :required_outcome_not_passed} =
                 evaluate(%{ctx | retained: retained, health: health}, 1000)
      end

      assert %{reason: :invalid_report} =
               evaluate(put_in(ctx.retained.report["revision"], 2), 1000)

      assert %{reason: :invalid_report} = evaluate(%{ctx | retained: nil}, 1000)
    end

    test "health evidence is mandatory, bounded and correlated with the exact report", ctx do
      for {health, reason} <- [
            {nil, :health_unknown},
            {%{}, :invalid_health},
            {Map.put(ctx.health, "status", "degraded"), :health_degraded},
            {Map.put(ctx.health, "status", "unknown"), :health_unknown},
            {Map.put(ctx.health, "status", "passed"), :invalid_health},
            {Map.put(ctx.health, "evidence_sha256", ""), :invalid_health},
            {Map.put(ctx.health, "observed_at_ms", "1000"), :invalid_health},
            {Map.put(ctx.health, "extra", true), :invalid_health},
            {Map.put(ctx.health, "binding_id", "00000000-0000-4000-8000-000000000099"),
             :health_mismatch},
            {Map.put(ctx.health, "report_sha256", String.duplicate("f", 64)), :health_mismatch}
          ] do
        assert %{evidence_status: :ineligible, reason: ^reason} =
                 evaluate(%{ctx | health: health}, 1000)
      end

      for key <- Map.keys(ctx.health) do
        assert %{reason: :invalid_health} =
                 evaluate(%{ctx | health: Map.delete(ctx.health, key)}, 1000)
      end
    end
  end

  defp evaluate(ctx, now_ms),
    do: LocalStorageEvidence.evaluate(ctx.retained, ctx.policy, ctx.health, now_ms)
end
