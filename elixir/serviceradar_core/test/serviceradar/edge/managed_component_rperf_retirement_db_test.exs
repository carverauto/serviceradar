defmodule ServiceRadar.Edge.ManagedComponentRperfRetirementDbTest do
  @moduledoc """
  Verifies that new `"rperf-client"` enrollments and infrastructure adoptions
  are rejected while historical `"rperf-client"` rows remain readable.
  """

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.InfrastructureCertificateAdoption
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Repo

  @moduletag :requires_app

  defp system_actor, do: SystemActor.system(:managed_component_rperf_retirement_test)

  test "rejects new rperf-client enrollments and infrastructure adoptions" do
    actor = system_actor()
    suffix = System.unique_integer([:positive])

    refute ManagedComponent.infrastructure_type?("rperf-client")

    assert {:error, %Invalid{}} =
             ManagedComponent
             |> Ash.Changeset.for_create(
               :enroll,
               %{
                 component_id: "rperf-client-enroll-#{suffix}",
                 component_type: "rperf-client",
                 partition_id: "default"
               },
               actor: actor
             )
             |> Ash.create()

    assert {:error, %Invalid{}} =
             ManagedComponent
             |> Ash.Changeset.for_create(
               :adopt_infrastructure,
               %{
                 component_id: "rperf-client-adopt-#{suffix}",
                 component_type: "rperf-client",
                 partition_id: "default",
                 permissions: %{"publish" => ["metrics.rperf.>"]}
               },
               actor: actor
             )
             |> Ash.create()

    assert {:error, :not_infrastructure} =
             InfrastructureCertificateAdoption.prepare(%{
               component_id: "rperf-client-cert-#{suffix}",
               component_type: "rperf-client",
               partition_id: "default",
               certificate_pem: self_signed_pem(),
               permissions: %{
                 publish: %{allow: ["metrics.rperf.>"], deny: []},
                 subscribe: %{allow: [], deny: ["$SYS.>"]}
               }
             })
  end

  defp self_signed_pem do
    %{cert: der} =
      :public_key.pkix_test_root_cert(~c"example-rperf-client",
        validity: {{2026, 1, 1}, {2027, 6, 1}}
      )

    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  test "keeps historical rperf-client rows readable" do
    actor = system_actor()
    suffix = System.unique_integer([:positive])
    component_id = "legacy-rperf-client-#{suffix}"
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        {"managed_components", ManagedComponent},
        [
          %{
            component_id: component_id,
            component_type: "rperf-client",
            partition_id: "default",
            generation_started_by: "legacy-installer",
            server_hosts: [],
            generation: 1,
            blocked: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "platform"
      )

    assert {:ok, %ManagedComponent{} = row} =
             Ash.get(ManagedComponent, component_id, actor: actor)

    assert row.component_id == component_id
    assert row.component_type == "rperf-client"
  end
end
