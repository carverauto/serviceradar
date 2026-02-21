defmodule ServiceRadar.NetworkDiscovery.MapperUnifiControllerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkDiscovery.{MapperJob, MapperUnifiController}

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "normalizes host-only controller URL to integration endpoint" do
    actor = SystemActor.system(:mapper_unifi_controller_test)
    {:ok, job} = create_job(actor)

    {:ok, controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(:create, %{
        mapper_job_id: job.id,
        name: "tonka01",
        base_url: "https://192.168.10.1",
        api_key: "abc123"
      })
      |> Ash.create(actor: actor)

    assert controller.base_url == "https://192.168.10.1/proxy/network/integration/v1"
  end

  @tag :integration
  test "rejects non-integration paths for controller URL" do
    actor = SystemActor.system(:mapper_unifi_controller_test)
    {:ok, job} = create_job(actor)

    {:error, %Ash.Error.Invalid{errors: errors}} =
      MapperUnifiController
      |> Ash.Changeset.for_create(:create, %{
        mapper_job_id: job.id,
        name: "tonka01",
        base_url: "https://192.168.10.1/api",
        api_key: "abc123"
      })
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, fn error ->
             error.field == :base_url and
               String.contains?(error.message, "/proxy/network/integration/v1")
           end)
  end

  defp create_job(actor) do
    MapperJob
    |> Ash.Changeset.for_create(:create, %{name: "job-#{System.unique_integer([:positive])}"},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end
end
