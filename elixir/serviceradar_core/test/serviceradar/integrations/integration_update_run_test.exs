defmodule ServiceRadar.Integrations.IntegrationUpdateRunTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", email: "system@serviceradar", role: :admin}
    {:ok, actor: actor}
  end

  test "creates a running update record for a source", %{actor: actor} do
    source = create_source!(actor, unique_name("run-source"))

    {:ok, run} =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(
        :start_run,
        %{
          integration_source_id: source.id,
          run_type: :armis_northbound,
          oban_job_id: 123,
          metadata: %{trigger: "schedule"}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert run.integration_source_id == source.id
    assert run.run_type == :armis_northbound
    assert run.status == :running
    assert run.oban_job_id == 123
    assert run.started_at
    assert run.finished_at == nil
    assert run.metadata == %{"trigger" => "schedule"}
  end

  test "finishes a run successfully and persists counts", %{actor: actor} do
    source = create_source!(actor, unique_name("run-finish-source"))
    run = start_run!(source.id, actor, %{metadata: %{trigger: "manual"}})

    {:ok, finished} =
      run
      |> Ash.Changeset.for_update(
        :finish_success,
        %{
          device_count: 25,
          updated_count: 20,
          skipped_count: 5,
          error_count: 0,
          metadata: %{trigger: "manual", outcome: "ok"}
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert finished.status == :success
    assert finished.device_count == 25
    assert finished.updated_count == 20
    assert finished.skipped_count == 5
    assert finished.error_count == 0
    assert finished.error_message == nil
    assert finished.finished_at
    assert finished.metadata == %{"outcome" => "ok", "trigger" => "manual"}
  end

  test "finishes a run with failure details and prevents re-finalizing", %{actor: actor} do
    source = create_source!(actor, unique_name("run-failure-source"))
    run = start_run!(source.id, actor, %{metadata: %{trigger: "schedule"}, oban_job_id: 456})

    {:ok, failed} =
      run
      |> Ash.Changeset.for_update(
        :finish_failed,
        %{
          device_count: 12,
          updated_count: 6,
          skipped_count: 3,
          error_count: 3,
          error_message: "armis bulk API rejected batch",
          metadata: %{trigger: "schedule", batch: 2}
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert failed.status == :failed
    assert failed.device_count == 12
    assert failed.updated_count == 6
    assert failed.skipped_count == 3
    assert failed.error_count == 3
    assert failed.error_message == "armis bulk API rejected batch"
    assert failed.finished_at

    {:error, invalid_transition} =
      failed
      |> Ash.Changeset.for_update(
        :finish_success,
        %{device_count: 12, updated_count: 12, skipped_count: 0, error_count: 0},
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert invalid_transition.errors != []

    by_job =
      IntegrationUpdateRun
      |> Ash.Query.for_read(:by_oban_job_id, %{oban_job_id: 456}, actor: actor)
      |> Ash.read_one!(actor: actor)

    assert by_job.id == failed.id
  end

  test "reads recent runs by source in descending order", %{actor: actor} do
    source = create_source!(actor, unique_name("run-read-source"))
    older = start_run!(source.id, actor, %{metadata: %{sequence: 1}})
    :timer.sleep(5)
    newer = start_run!(source.id, actor, %{metadata: %{sequence: 2}})

    {:ok, runs} =
      IntegrationUpdateRun
      |> Ash.Query.for_read(:recent_by_source, %{integration_source_id: source.id}, actor: actor)
      |> Ash.read(actor: actor)

    assert Enum.take(Enum.map(runs, & &1.id), 2) == [newer.id, older.id]
  end

  test "reads latest run by source", %{actor: actor} do
    source = create_source!(actor, unique_name("run-latest-source"))
    _older = start_run!(source.id, actor, %{metadata: %{sequence: 1}})
    :timer.sleep(5)
    newer = start_run!(source.id, actor, %{metadata: %{sequence: 2}})

    latest =
      IntegrationUpdateRun
      |> Ash.Query.for_read(:latest_by_source, %{integration_source_id: source.id}, actor: actor)
      |> Ash.read_one!(actor: actor)

    assert latest.id == newer.id
  end

  defp create_source!(actor, name) do
    endpoint = "https://example.invalid/#{System.unique_integer([:positive])}"

    IntegrationSource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:credentials, %{token: "secret"})
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, source_type: :armis, endpoint: endpoint},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp start_run!(integration_source_id, actor, attrs) do
    defaults = %{
      integration_source_id: integration_source_id,
      run_type: :armis_northbound,
      metadata: %{}
    }

    IntegrationUpdateRun
    |> Ash.Changeset.for_create(:start_run, Map.merge(defaults, attrs), actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
