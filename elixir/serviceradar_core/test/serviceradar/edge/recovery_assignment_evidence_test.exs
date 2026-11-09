defmodule ServiceRadar.Edge.RecoveryAssignmentEvidenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.RecoveryAssignmentEvidence, as: Evidence
  alias ServiceRadar.RecoveryAssignmentFixtures

  test "sweep issuance binds original execution and plan independently of its lease run and production scope" do
    ctx = RecoveryAssignmentFixtures.fixture()
    assert {:ok, [entry]} = Evidence.sweep(ctx.capability, ctx.slot, ctx.key.public_key)
    assert entry.value["execution_id"] == Base.encode16(ctx.slot.execution_id, case: :lower)
    refute entry.value["execution_id"] == Base.encode16(ctx.production.run_id, case: :lower)
    assert entry.value["range"]["sha256"] == String.duplicate("36", 32)
    assert entry.value["plan"]["sha256"] == String.duplicate("37", 32)
    assert Enum.at(entry.key["span_identity"], 5) == String.duplicate("32", 32)
    assert :ok = Evidence.validate(entry.key, entry.value, entry.proof)

    for changed <- [
          %{ctx.slot | execution_id: ctx.production.run_id},
          %{
            ctx.slot
            | plan_header: %{
                ctx.slot.plan_header
                | execution_plan_sha256: :binary.copy(<<0x38>>, 32)
              }
          },
          %{
            ctx.slot
            | source_authorizations: [%{ctx.source | scope_id: ctx.production.scope_id}]
          },
          %{
            ctx.slot
            | source_authorizations: [
                %{ctx.source | capability: %{ctx.source.capability | signature: <<0::512>>}}
              ]
          }
        ] do
      assert {:error, :invalid_issuance} =
               Evidence.sweep(ctx.capability, changed, ctx.key.public_key)
    end
  end

  test "retained signatures cannot authorize a substituted key, tagged value or damaged original proof" do
    ctx = RecoveryAssignmentFixtures.fixture(:standing)
    assert {:ok, entry} = Evidence.standing(ctx.capability, ctx.key.public_key)
    assert entry.value["kind"] == "explicit_negative"
    assert entry.value["reason"] == "standing_output_grant"
    assert :ok = Evidence.validate(entry.key, entry.value, entry.proof)

    changed_key =
      Map.put(entry.key, "trust_namespace", [
        Base.encode16(ctx.scope, case: :lower),
        "other.example.com"
      ])

    assert {:error, :invalid_issuance} = Evidence.validate(changed_key, entry.value, entry.proof)

    assert {:error, :invalid_issuance} =
             Evidence.validate(
               entry.key,
               Map.put(entry.value, "reason", "recovery_control"),
               entry.proof
             )

    for proof <- [
          nil,
          %{},
          Map.put(entry.proof, "public_key", nil),
          Map.put(entry.proof, "production", "!!!"),
          Map.put(entry.proof, "source", 12),
          Map.put(entry.proof, "extra", true)
        ] do
      assert {:error, :invalid_issuance} = Evidence.validate(entry.key, entry.value, proof)
    end
  end
end
