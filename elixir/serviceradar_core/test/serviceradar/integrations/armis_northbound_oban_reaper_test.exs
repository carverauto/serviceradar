defmodule ServiceRadar.Integrations.ArmisNorthboundObanReaperTest.SupportStub do
  @moduledoc false

  def prefix, do: "platform"
end

defmodule ServiceRadar.Integrations.ArmisNorthboundObanReaperTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Integrations.ArmisNorthboundObanReaper
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "reaps stale executing jobs for the requested Armis source" do
    now = ~U[2026-04-14 03:30:00.000000Z]
    worker = inspect(ArmisNorthboundRunWorker)

    stale_job =
      insert_oban_job(worker,
        args: %{"integration_source_id" => "source-1", "manual" => false},
        attempted_at: ~U[2026-04-14 03:20:00.000000Z]
      )

    fresh_job =
      insert_oban_job(worker,
        args: %{"integration_source_id" => "source-1", "manual" => false},
        attempted_at: ~U[2026-04-14 03:29:30.000000Z]
      )

    other_source_job =
      insert_oban_job(worker,
        args: %{"integration_source_id" => "source-2", "manual" => false},
        attempted_at: ~U[2026-04-14 03:20:00.000000Z]
      )

    assert {1, nil} =
             ArmisNorthboundObanReaper.reap_stale_source_jobs(
               ArmisNorthboundRunWorker,
               "source-1",
               now,
               120,
               support_module: ServiceRadar.Integrations.ArmisNorthboundObanReaperTest.SupportStub
             )

    assert %{state: "discarded", discarded_at: ^now} = fetch_job(stale_job.id)
    assert %{state: "executing", discarded_at: nil} = fetch_job(fresh_job.id)
    assert %{state: "executing", discarded_at: nil} = fetch_job(other_source_job.id)
  end

  defp insert_oban_job(worker, attrs) do
    %Oban.Job{}
    |> Ecto.Changeset.change(
      state: "executing",
      queue: "integrations",
      worker: worker,
      args: Keyword.fetch!(attrs, :args),
      attempt: 1,
      max_attempts: 3,
      inserted_at: ~U[2026-04-14 03:00:00.000000Z],
      scheduled_at: ~U[2026-04-14 03:00:00.000000Z],
      attempted_at: Keyword.fetch!(attrs, :attempted_at)
    )
    |> Repo.insert!(prefix: "platform")
  end

  defp fetch_job(id), do: Repo.get!(Oban.Job, id, prefix: "platform")
end
