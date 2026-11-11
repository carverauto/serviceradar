defmodule ServiceRadar.Camera.LocalStorageQualificationReportIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageQualification
  alias ServiceRadar.Camera.LocalStorageQualificationReport
  alias ServiceRadar.Test.LocalStorageFixtures, as: Fixtures

  @moduletag :integration

  setup do
    Fixtures.context()
  end

  test "assessment uses scoped retained evidence, trusted policy and Core time without activation",
       ctx do
    now = System.system_time(:millisecond)

    document =
      ctx.document
      |> Map.put("issued_at_ms", now - 1000)
      |> Map.put("expires_at_ms", now + 60_000)

    assert {:ok, report} = LocalStorageQualificationReport.submit(document, ctx.opts)

    health = %{
      "binding_id" => ctx.binding.id,
      "report_sha256" => report.report_sha256,
      "evidence_sha256" => String.duplicate("c", 64),
      "observed_at_ms" => now,
      "status" => "healthy"
    }

    policy = %{
      revision: document["policy_revision"],
      profile_sha256: ctx.binding.profile_sha256,
      max_report_validity_ms: 61_000,
      max_health_age_ms: 60_000
    }

    actor = Map.put(ctx.qualifier, :nvr_storage_policy, policy)

    assert {:ok, %{evidence_status: :current, valid_until_ms: deadline}} =
             LocalStorageQualificationReport.assess(report.id, health, actor: actor)

    assert deadline == now + 60_000

    assert {:ok, %{evidence_status: :ineligible, reason: :invalid_policy}} =
             LocalStorageQualificationReport.assess(report.id, health, ctx.opts)

    assert {:ok, %{reason: :health_from_future}} =
             LocalStorageQualificationReport.assess(
               report.id,
               Map.put(health, "observed_at_ms", now + 120_000),
               actor: actor
             )

    for denied <- [
          nil,
          ctx.provisioner,
          SystemActor.system(:nvr_recorder),
          Map.put(actor, :nvr_storage_id, Ecto.UUID.generate())
        ] do
      assert {:error, _} =
               LocalStorageQualificationReport.assess(report.id, health, actor: denied)
    end

    assert {:ok, unchanged} = Ash.get(LocalStorageQualificationReport, report.id, ctx.opts)
    assert unchanged.report == document
    assert unchanged.inserted_at == report.inserted_at
  end

  test "activation retains its receipt, policy changes fail closed and withdrawal fences stale decisions",
       ctx do
    {report, health, actor} = Fixtures.current_evidence(ctx)
    opts = [actor: actor]
    assert {:ok, %{qualification_status: :unknown}} = LocalStorageQualification.status(opts)
    assert {:ok, first} = LocalStorageQualification.activate(1, report.id, health, opts)
    assert first.storage_id == ctx.binding.storage_id
    assert first.state == :active
    assert first.qualification_report_id == report.id

    assert {:ok, %{qualification_status: :qualified, revision: 1}} =
             LocalStorageQualification.status(opts)

    rotated = Map.put(actor, :id, "system:synthetic_rotated_qualifier")
    assert {:ok, retry} = LocalStorageQualification.activate(1, report.id, health, actor: rotated)
    assert retry.decided_by == first.decided_by
    assert retry.decided_at == first.decided_at
    assert retry.decision_sha256 == first.decision_sha256

    changed_policy = put_in(actor.nvr_storage_policy.max_health_age_ms, 300_000)

    assert {:ok, %{qualification_status: :ineligible, reason: :policy_changed}} =
             LocalStorageQualification.status(actor: changed_policy)

    assert {:error, conflict} =
             LocalStorageQualification.activate(1, report.id, health, actor: changed_policy)

    assert Exception.message(conflict) =~ "decision_conflict"

    assert {:ok, withdrawn} =
             LocalStorageQualification.withdraw(2, "operator-withdrawal", ctx.opts)

    assert withdrawn.state == :withdrawn
    assert is_nil(withdrawn.qualification_report_id)

    assert {:ok, retry} =
             LocalStorageQualification.withdraw(2, "operator-withdrawal", actor: rotated)

    assert retry.decided_at == withdrawn.decided_at
    assert retry.decided_by == withdrawn.decided_by
    assert {:error, _} = LocalStorageQualification.activate(1, report.id, health, opts)
    assert {:error, _} = LocalStorageQualification.activate(2, report.id, health, opts)
    assert {:error, _} = LocalStorageQualification.withdraw(2, "changed-reason", ctx.opts)

    assert {:ok, %{qualification_status: :withdrawn, revision: 2}} =
             LocalStorageQualification.status(ctx.opts)

    assert {:ok, historical} = Ash.get(LocalStorageQualificationReport, report.id, ctx.opts)
    assert historical.report == report.report
    assert {:ok, _} = LocalStorageQualification.activate(3, report.id, health, opts)
  end

  test "withdrawal before first activation and binding generation changes share one revision order",
       ctx do
    {report, health, actor} = Fixtures.current_evidence(ctx)
    assert {:ok, _} = LocalStorageQualification.withdraw(5, "storage-offline", ctx.opts)
    assert {:error, _} = LocalStorageQualification.activate(4, report.id, health, actor: actor)

    assert {:ok, binding} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "generation", 2),
               actor: ctx.provisioner
             )

    document =
      Map.merge(report.report, %{
        "binding_id" => binding.id,
        "binding_sha256" => binding.binding_sha256
      })

    assert {:ok, next_report} = LocalStorageQualificationReport.submit(document, ctx.opts)

    next_health =
      Map.merge(health, %{
        "binding_id" => binding.id,
        "report_sha256" => next_report.report_sha256
      })

    assert {:ok, current} =
             LocalStorageQualification.activate(6, next_report.id, next_health, actor: actor)

    assert current.qualification_report_id == next_report.id
    assert {:error, _} = LocalStorageQualification.activate(5, report.id, health, actor: actor)
    assert {:ok, [only]} = Ash.read(LocalStorageQualification, ctx.opts)
    assert only.revision == 6
    assert {:ok, historical} = Ash.get(LocalStorageQualificationReport, report.id, ctx.opts)
    assert historical.id == report.id
  end

  test "rejected evidence rolls back a newer decision and preserves withdrawal", ctx do
    {report, health, actor} = Fixtures.current_evidence(ctx)
    assert {:ok, _} = LocalStorageQualification.withdraw(1, "maintenance", ctx.opts)

    # Freshness is evaluated after the conditional write acquires the storage row lock.
    stale_health = Map.put(health, "observed_at_ms", 1)

    assert {:error, error} =
             LocalStorageQualification.activate(2, report.id, stale_health, actor: actor)

    assert Exception.message(error) =~ "health_expired"

    assert {:ok, %{qualification_status: :withdrawn, revision: 1}} =
             LocalStorageQualification.status(ctx.opts)

    for invalid <- [
          Map.put(health, "status", "degraded"),
          Map.put(health, "report_sha256", String.duplicate("d", 64))
        ] do
      assert {:error, _} = LocalStorageQualification.activate(2, report.id, invalid, actor: actor)
    end

    assert {:error, _} = LocalStorageQualification.activate(2, report.id, health, ctx.opts)
    assert {:ok, _} = LocalStorageQualification.activate(2, report.id, health, actor: actor)
  end

  test "only storage-scoped qualification principals may decide or inspect current state", ctx do
    {report, health, actor} = Fixtures.current_evidence(ctx)
    assert {:ok, first} = LocalStorageQualification.activate(1, report.id, health, actor: actor)

    for denied <- [
          nil,
          ctx.provisioner,
          SystemActor.system(:nvr_recorder),
          Map.put(actor, :role, :admin),
          Map.put(actor, :id, "invalid\nprincipal")
        ] do
      assert {:error, _} = LocalStorageQualification.activate(2, report.id, health, actor: denied)
      assert {:error, _} = LocalStorageQualification.withdraw(2, "denied", actor: denied)
    end

    other = Map.put(actor, :nvr_storage_id, Ecto.UUID.generate())
    assert {:error, _} = LocalStorageQualification.activate(2, report.id, health, actor: other)
    assert {:ok, []} = Ash.read(LocalStorageQualification, actor: other)

    assert {:ok, %{qualification_status: :unknown}} =
             LocalStorageQualification.status(actor: other)

    for denied <- [nil, ctx.provisioner, SystemActor.system(:nvr_recorder)] do
      assert {:error, _} = LocalStorageQualification.status(actor: denied)
    end

    assert {:ok, retained} = Ash.get(LocalStorageQualification, first.storage_id, actor: actor)
    assert retained.revision == 1
  end

  test "expired current evidence stays ineligible when its historical receipt is retried", ctx do
    {report, health, actor} = Fixtures.current_evidence(ctx)
    actor = put_in(actor.nvr_storage_policy.max_health_age_ms, 10_000)
    health = Map.put(health, "observed_at_ms", System.system_time(:millisecond))
    assert {:ok, receipt} = LocalStorageQualification.activate(1, report.id, health, actor: actor)

    assert {:ok, %{qualification_status: :qualified}} =
             LocalStorageQualification.status(actor: actor)

    deadline = health["observed_at_ms"] + actor.nvr_storage_policy.max_health_age_ms
    Process.sleep(max(0, deadline - System.system_time(:millisecond) + 1))

    assert {:ok, %{qualification_status: :ineligible, reason: :health_expired}} =
             LocalStorageQualification.status(actor: actor)

    assert {:ok, retry} = LocalStorageQualification.activate(1, report.id, health, actor: actor)
    assert retry.decided_at == receipt.decided_at
    assert retry.decided_by == receipt.decided_by

    assert {:error, error} =
             LocalStorageQualification.activate(2, report.id, health, actor: actor)

    assert Exception.message(error) =~ "health_expired"

    assert {:ok, %{qualification_status: :ineligible, revision: 1}} =
             LocalStorageQualification.status(actor: actor)
  end

  test "identical retries preserve the original report UUID, issuer and insertion time", ctx do
    assert {:ok, first} = LocalStorageQualificationReport.submit(ctx.document, ctx.opts)
    rotated = Map.put(ctx.qualifier, :id, "system:synthetic_replacement_qualifier")
    assert {:ok, retry} = LocalStorageQualificationReport.submit(ctx.document, actor: rotated)
    assert retry.id == first.id
    assert retry.issued_by == ctx.qualifier.id
    assert retry.inserted_at == first.inserted_at
    assert retry.report_sha256 == first.report_sha256
    assert retry.report == ctx.document
    assert {:ok, [retained]} = Ash.read(LocalStorageQualificationReport, ctx.opts)
    assert retained.id == first.id
  end

  test "changed evidence conflicts at the same revision and a later revision retains history",
       ctx do
    assert {:ok, first} = LocalStorageQualificationReport.submit(ctx.document, ctx.opts)

    changed =
      ctx.document
      |> Map.put("evidence_sha256", String.duplicate("c", 64))
      |> put_in(["checks", "restore_preserves_history"], "failed")

    assert {:error, error} = LocalStorageQualificationReport.submit(changed, ctx.opts)
    assert Exception.message(error) =~ "local storage qualification report conflicts"

    assert {:ok, next} =
             LocalStorageQualificationReport.submit(Map.put(changed, "revision", 2), ctx.opts)

    assert next.id != first.id
    assert next.report_sha256 != first.report_sha256
    assert next.report["checks"]["restore_preserves_history"] == "failed"
    assert {:ok, historical} = Ash.get(LocalStorageQualificationReport, first.id, ctx.opts)
    assert historical.report == ctx.document
  end

  test "rejects missing or mismatched binding, storage and profile identities", ctx do
    for {key, value} <- [
          {"binding_id", Ecto.UUID.generate()},
          {"storage_id", Ecto.UUID.generate()},
          {"binding_sha256", String.duplicate("c", 64)},
          {"profile_sha256", String.duplicate("c", 64)}
        ] do
      assert {:error, _} =
               LocalStorageQualificationReport.submit(Map.put(ctx.document, key, value), ctx.opts)
    end

    assert {:ok, []} = Ash.read(LocalStorageQualificationReport, ctx.opts)

    assert {:ok, newer_binding} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "generation", 2),
               actor: ctx.provisioner
             )

    assert {:error, _} =
             LocalStorageQualificationReport.submit(
               Map.put(ctx.document, "binding_id", newer_binding.id),
               ctx.opts
             )

    assert {:ok, _} = LocalStorageQualificationReport.submit(ctx.document, ctx.opts)
  end

  test "only the scoped qualification principal may submit or retry", ctx do
    assert {:ok, first} = LocalStorageQualificationReport.submit(ctx.document, ctx.opts)

    for actor <- [
          nil,
          SystemActor.system(:nvr_recorder),
          ctx.provisioner,
          Map.put(ctx.qualifier, :role, :admin),
          Map.put(ctx.qualifier, :nvr_storage_id, Ecto.UUID.generate()),
          Map.put(ctx.qualifier, :id, "invalid\nprincipal")
        ],
        revision <- [1, 2] do
      assert {:error, _} =
               LocalStorageQualificationReport.submit(
                 Map.put(ctx.document, "revision", revision),
                 actor: actor
               )
    end

    assert {:ok, [retained]} = Ash.read(LocalStorageQualificationReport, ctx.opts)
    assert retained.id == first.id
    assert {:error, _} = LocalStorageBinding.register(ctx.configuration, ctx.opts)
  end

  test "qualification reads and submissions cannot cross storage lifetimes", ctx do
    assert {:ok, first} = LocalStorageQualificationReport.submit(ctx.document, ctx.opts)
    other_storage = Ecto.UUID.generate()
    other_provisioner = Map.put(ctx.provisioner, :nvr_storage_id, other_storage)
    other_qualifier = Map.put(ctx.qualifier, :nvr_storage_id, other_storage)

    assert {:ok, other_binding} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "storage_id", other_storage),
               actor: other_provisioner
             )

    other_document =
      Map.merge(ctx.document, %{
        "binding_id" => other_binding.id,
        "storage_id" => other_storage,
        "binding_sha256" => other_binding.binding_sha256
      })

    assert {:ok, other} =
             LocalStorageQualificationReport.submit(other_document, actor: other_qualifier)

    # A correctly scoped envelope must not authorize a foreign binding hidden inside it.
    assert {:error, _} =
             LocalStorageQualificationReport.submit(
               Map.put(other_document, "storage_id", ctx.binding.storage_id),
               ctx.opts
             )

    assert {:ok, [visible]} = Ash.read(LocalStorageQualificationReport, ctx.opts)
    assert visible.id == first.id
    assert {:ok, [visible]} = Ash.read(LocalStorageQualificationReport, actor: other_qualifier)
    assert visible.id == other.id
    assert {:ok, [visible_binding]} = Ash.read(LocalStorageBinding, ctx.opts)
    assert visible_binding.id == ctx.binding.id
    assert {:ok, [visible_binding]} = Ash.read(LocalStorageBinding, actor: other_qualifier)
    assert visible_binding.id == other_binding.id

    assert {:ok, []} =
             Ash.read(LocalStorageQualificationReport, actor: SystemActor.system(:nvr_recorder))

    assert {:ok, []} = Ash.read(LocalStorageQualificationReport, actor: ctx.provisioner)
  end
end
