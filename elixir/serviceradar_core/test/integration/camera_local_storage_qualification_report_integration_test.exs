defmodule ServiceRadar.Camera.LocalStorageQualificationReportIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageQualificationReport

  @moduletag :integration

  setup do
    storage_id = Ecto.UUID.generate()

    provisioner =
      :synthetic_storage_provisioner
      |> SystemActor.system()
      |> Map.merge(%{nvr_storage_purpose: :provision, nvr_storage_id: storage_id})

    qualifier =
      :synthetic_storage_qualifier
      |> SystemActor.system()
      |> Map.merge(%{nvr_storage_purpose: :qualify, nvr_storage_id: storage_id})

    configuration = %{
      "schema_version" => 1,
      "storage_id" => storage_id,
      "generation" => 1,
      "provider_resource_ref" => "invented-qualification-volume",
      "profile_sha256" => String.duplicate("a", 64)
    }

    assert {:ok, binding} = LocalStorageBinding.register(configuration, actor: provisioner)

    document = %{
      "schema_version" => 1,
      "binding_id" => binding.id,
      "storage_id" => storage_id,
      "binding_sha256" => binding.binding_sha256,
      "profile_sha256" => binding.profile_sha256,
      "revision" => 1,
      "evidence_sha256" => String.duplicate("b", 64),
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

    %{
      binding: binding,
      document: document,
      configuration: configuration,
      provisioner: provisioner,
      qualifier: qualifier,
      opts: [actor: qualifier]
    }
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
