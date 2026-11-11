defmodule ServiceRadar.Test.LocalStorageFixtures do
  @moduledoc false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageQualificationReport

  def context(storage_id \\ Ecto.UUID.generate()) do
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

    {:ok, binding} = LocalStorageBinding.register(configuration, actor: provisioner)

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

  def current_evidence(ctx) do
    now = System.system_time(:millisecond)

    document =
      Map.merge(ctx.document, %{"issued_at_ms" => now - 1000, "expires_at_ms" => now + 120_000})

    {:ok, report} = LocalStorageQualificationReport.submit(document, ctx.opts)

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
      max_report_validity_ms: 121_000,
      max_health_age_ms: 120_000
    }

    {report, health, Map.put(ctx.qualifier, :nvr_storage_policy, policy)}
  end
end
