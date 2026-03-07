defmodule ServiceRadar.NetworkDiscovery.MapperMikrotikControllerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkDiscovery.{MapperJob, MapperMikrotikController}

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "normalizes host-only controller URL to RouterOS REST endpoint" do
    actor = SystemActor.system(:mapper_mikrotik_controller_test)
    {:ok, job} = create_job(actor)

    {:ok, controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(:create, %{
        mapper_job_id: job.id,
        name: "chr-demo",
        base_url: "https://192.168.88.1",
        username: "admin",
        password: "secret"
      })
      |> Ash.create(actor: actor)

    assert controller.base_url == "https://192.168.88.1/rest"
  end

  @tag :integration
  test "rejects non-rest paths for controller URL" do
    actor = SystemActor.system(:mapper_mikrotik_controller_test)
    {:ok, job} = create_job(actor)

    {:error, %Ash.Error.Invalid{errors: errors}} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(:create, %{
        mapper_job_id: job.id,
        name: "chr-demo",
        base_url: "https://192.168.88.1/api",
        username: "admin",
        password: "secret"
      })
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, fn error ->
             error.field == :base_url and
               String.contains?(error.message, "/rest")
           end)
  end

  defp create_job(actor) do
    MapperJob
    |> Ash.Changeset.for_create(:create, %{name: "job-#{Ash.UUID.generate()}"}, actor: actor)
    |> Ash.create(actor: actor)
  end
end
