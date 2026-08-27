defmodule ServiceRadar.SweepJobs.ObanSupportDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "recovers a stale executing conflict through the platform enum schema" do
    now = ~U[2026-07-18 16:00:00.000000Z]

    job =
      %Oban.Job{}
      |> Ecto.Changeset.change(
        state: "executing",
        queue: "maintenance",
        worker: "ServiceRadar.TestStaleWorker",
        args: %{},
        attempt: 1,
        max_attempts: 3,
        inserted_at: ~U[2026-07-18 10:00:00.000000Z],
        scheduled_at: ~U[2026-07-18 10:00:00.000000Z],
        attempted_at: ~U[2026-07-18 10:01:00.000000Z]
      )
      |> Repo.insert!(prefix: "platform")

    assert {1, nil} = ObanSupport.recover_stale_executing_conflict(job, now, 14_400)

    assert %{state: "discarded", discarded_at: ^now} =
             Repo.get!(Oban.Job, job.id, prefix: "platform")
  end
end
